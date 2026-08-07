import Darwin
import Foundation

/// A candidate file paired with the tail bytes already read from it, so
/// callers that need the content (`recipientFinding`) don't re-open and
/// re-read the file a second time after `encryptedFiles(under:)` already
/// paid that cost once.
public struct SniffedFile: Sendable {
    public let url: URL
    let tail: String
}

/// What one walk of a project tree found.
public struct ScannedTree: Sendable {
    /// Files carrying a YAML `sops:` metadata block — the shape this
    /// build can read recipients out of.
    public var encrypted: [SniffedFile] = []
    /// Files carrying sops metadata in some other serialization
    /// (dotenv, JSON, INI). Recorded, not ignored: they are reported as
    /// unverifiable rather than quietly left out of the count.
    public var encryptedInOtherFormats: [URL] = []
    /// Files whose *names* conventionally hold plaintext secrets and
    /// which carry no sops metadata at all.
    public var plaintextCandidates: [URL] = []
    /// `true` once the walk stopped early because it reached
    /// `maxScannedFiles`. A scan that stops early has only looked at part
    /// of the tree, so nothing downstream may treat its result as
    /// covering the whole project — see `ProjectHealthCheck.recipientFinding`.
    public var wasTruncated = false
    /// Names of directories this walk declined to enter (deduplicated,
    /// not in walk order). Disclosed to the user rather than left as a
    /// silent constant — see `ProjectScanner.skippedDirectoryNames`.
    public var skippedDirectoryNames: [String] = []
}

/// Walks a project tree once, classifying every regular file as
/// sops-encrypted (YAML or otherwise) or a plaintext secret-file
/// candidate. Extracted out of `ProjectHealthCheck` so the file list and
/// the throughput work that follow it in M2 can reuse the same walk rather
/// than each growing a second, divergent copy of "which files are
/// encrypted" — see the M2 task brief for why that would be the worst
/// available outcome.
public struct ProjectScanner {

    /// The number of bytes read from the *end* of every candidate file, via
    /// a `pread` at a computed offset (see `tailBytes(of:maxBytes:)`) —
    /// never more, regardless of the file's total size.
    ///
    /// This works because sops always appends its `sops:` metadata block as
    /// the file's *last* top-level key. Verified directly against the pinned
    /// getsops/sops v3.13.3 source this app embeds: `SerializeMetadata` in
    /// `stores/metadata.go` builds the metadata `TreeItem`s (`md`) and then,
    /// for every branch, appends the branch's *existing* items first and
    /// `md` after —
    /// ```go
    /// for _, item := range branch { newBranch = append(newBranch, item) }
    /// for _, item := range md     { newBranch = append(newBranch, item) }
    /// ```
    /// — so `sops:` is unconditionally last. A bounded tail read therefore
    /// finds it regardless of how large the file's own plaintext-derived
    /// `ENC[...]` values are before it, at a *constant* cost per file.
    ///
    /// 64 KiB, not the 8 MiB an earlier version of this check used: a real
    /// sops metadata block is a handful of small per-key entries (~200-400
    /// bytes each for age/pgp/kms), so even a file with a few hundred
    /// recipients stays well under 64 KiB. 8 MiB was measured to cost
    /// ~0.5s per matching file — fine for one file, ~7.7s across 15 files
    /// and ~10.3s across 20 in a real-sized repository, i.e. the exact
    /// "large tree is slow" regression this cap exists to prevent, just
    /// re-introduced at the per-file, per-tree-size level instead of the
    /// per-single-large-file level the original version fixed. 64 KiB
    /// removes that scaling: see the fix report for before/after timing
    /// across 15- and 20-file trees. The residual edge case — a `sops:`
    /// block itself exceeding 64 KiB, needing on the order of a hundred-plus
    /// recipients on a single file — falls back to being invisible to this
    /// check, the same direction of limitation as before, at a threshold
    /// closer to what real files actually look like.
    static let maxSniffedFileBytes = 64 * 1024

    /// Directories that hold dependencies, build output, or a tool's own
    /// storage rather than the user's own files. Walking them is what turned
    /// a project scan into 170 seconds on a real repository — 272,802 files
    /// where 13,899 were the user's, driven by `node_modules/.bun` and
    /// `.worktrees` — and it is disclosed as `wasTruncated`/
    /// `skippedDirectoryNames` rather than left as a silent constant: every
    /// entry here is a place this app promises not to look, and the promise
    /// is only honest if the finding says so.
    ///
    /// Justification for the list actually shipped (starting point per the
    /// task brief, measured and adjusted, not taken on faith):
    /// - `.git`, `.hg`, `.svn` — VCS internals, never a place a loose secret
    ///   file lives.
    /// - `node_modules`, `.build`, `.swiftpm`, `target`, `vendor`, `Pods`,
    ///   `Carthage`, `DerivedData`, `.venv`, `venv`, `__pycache__`, `.tox`,
    ///   `.next`, `.nuxt`, `.gradle`, `.terraform` — dependency or toolchain
    ///   output for JS/Swift/Rust/Go/Ruby/PHP/Python/Terraform ecosystems.
    ///   All of these are either vendored *other people's* code or
    ///   regenerable build artifacts, never a place a user hand-places a
    ///   secret.
    /// - `.worktrees` — this repository's own convention
    ///   (`CLAUDE.md`) for nested git worktrees, i.e. a full second copy of
    ///   the tree (including its own `node_modules`) living inside the first.
    ///   Without this entry, this app is slow scanning *itself*.
    ///
    /// `dist` and `build` were on the brief's starting list and are
    /// deliberately dropped: `dist` is still excluded as unambiguous build
    /// output, but a bare `build` is also plausible as a user's own directory
    /// name (a Swift package target literally named `build/`, a Java module,
    /// a docs folder) in a way `dist` rarely is. Excluding a directory the
    /// user might have hand-authored risks hiding a real secret file inside
    /// it, which is exactly the failure class this list exists to avoid
    /// creating. `DerivedData` was not on the brief's list but is added: it
    /// is Xcode's own build cache (this repo's own `App/` target produces
    /// one), unambiguous machine output, and the same order of magnitude as
    /// `node_modules` when it accumulates.
    static let skippedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn",
        "node_modules", ".build", ".swiftpm", ".worktrees",
        "target", "vendor", "Pods", "Carthage", "DerivedData",
        ".venv", "venv", "__pycache__", ".tox",
        ".next", ".nuxt", ".gradle", ".terraform", "dist",
    ]

    /// A ceiling so an unknown huge directory this app doesn't recognize as
    /// dependency/build output cannot stall the UI. When it is hit the scan
    /// says so — `ScannedTree.wasTruncated` — rather than silently reporting
    /// on a project it only partly read. A budget that is silently exceeded
    /// is the same failure class as the vacuous "every file's key list
    /// matches" this check was rewritten to stop producing (see
    /// `ProjectHealthCheck`'s type-level doc comment).
    static let maxScannedFiles = 20_000

    /// How many per-file tail-read-and-classify units run at once. The walk
    /// itself (~1.0–1.3s across 20,000 files, measured) was never the
    /// bottleneck — the remaining 85–88% of a real scan's wall clock was the
    /// per-file open+seek+read+close, one after another. That work is
    /// I/O-bound and mutually independent, so it parallelises; the width has
    /// to be *bounded* because firing 20,000 opens at once would exhaust
    /// this process's file descriptor table.
    ///
    /// 64, chosen as a fraction of the default macOS per-process soft limit
    /// (256 — `RLIMIT_NOFILE`; raised well past that on this development
    /// machine, but a shipped GUI app cannot assume that) with headroom for
    /// whatever else the process already has open (stdio, the embedded Go
    /// engine's own descriptors, AppKit/Cocoa's usual handful of sockets and
    /// caches) and for a user with more than one project window scanning at
    /// once. Measured, not just assumed safe: on the 272,802-file repository
    /// this app was slow against, widths from 16 through 256 all landed
    /// within the same ~1.9–2.4s band for the read+classify phase (see the
    /// task-1b report) — this workload's remaining cost is not
    /// concurrency-width-limited at any of these widths, so 64 buys the
    /// file-descriptor safety margin above without giving up throughput a
    /// narrower or wider choice would have captured.
    /// `ProjectScanPerformanceTests.tailReadConcurrencyIsBounded` proves —
    /// not assumes — that the implementation never exceeds whatever width it
    /// is given, by instrumenting the exact code path `scan` uses with a
    /// concurrent-in-flight counter under deliberately-scrambled completion
    /// order.
    static let tailReadConcurrencyWidth = 64

    /// Walks the project tree once, classifying every regular file.
    ///
    /// Hidden files are **not** skipped, which is the change that closes one
    /// of the three reproduced false-OK paths. The previous
    /// `.skipsHiddenFiles` meant a genuinely sops-encrypted `.hidden-secrets.yaml`
    /// or `.config/secrets.yaml` was permanently invisible — including one
    /// encrypted to a key the config no longer declared, i.e. a real
    /// `.problem` the report rendered as "every file's key list matches". A
    /// sops-encrypted `.env` is a completely ordinary thing for a user to
    /// have, and so is a `secrets/` directory under a dotfile path. An
    /// exclusion the user cannot see and the copy does not admit is the same
    /// failure class as the vacuous OK itself, so the exclusion is gone rather
    /// than documented.
    ///
    /// Every file's *tail* is read (see `maxSniffedFileBytes`), never its full
    /// contents, so this scales with file count, not file size. Nothing is
    /// read from a plaintext candidate beyond that tail, and nothing read from
    /// any file ever reaches a finding.
    ///
    /// `async`: the directory walk below stays synchronous (it is already
    /// fast, and `FileManager`'s enumerator is not itself concurrency-safe to
    /// share across tasks), but the tail reads it feeds run concurrently —
    /// see `tailReadConcurrencyWidth`. The walk decides, in a single pass and
    /// in a fixed order, exactly which files are visited and where the
    /// budget cuts off; only *how* each visited file's tail is read moves off
    /// this thread. `concurrentMap` returns results indexed to that same
    /// order, so classification below iterates in the original walk order
    /// regardless of which read happened to finish first — the result never
    /// depends on completion order.
    public static func scan(root: URL) async -> ScannedTree {
        // The walk itself is a plain synchronous call (no `await` on it) —
        // `FileManager`'s `NSEnumerator`-backed iteration is unavailable
        // directly inside an `async` function body, and it does not need to
        // run concurrently anyway: it is already the fast ~15% of the
        // budget. Only the per-file work it hands off below is parallelised.
        var (tree, candidates) = Self.walk(root: root)

        // Both the tail read *and* classifying what it found run inside the
        // same concurrent unit of work per file. An earlier version of this
        // function read tails concurrently but classified them afterwards in
        // one big serial loop — measured to cost nearly as much wall clock
        // as the reads themselves, because `String.contains` over a tail up
        // to `maxSniffedFileBytes` (64 KiB) is not free at 20,000 files, and
        // that loop paid it single-threaded. Classifying one file's own tail
        // has no dependency on any other file's, so it parallelises exactly
        // as well as the read that produces it — see
        // `ProjectScanPerformanceTests` for the before/after this reordering
        // was measured against.
        let classifications = await Self.concurrentMap(candidates, width: Self.tailReadConcurrencyWidth) { url in
            Self.classify(url: url, maxBytes: Self.maxSniffedFileBytes)
        }

        // Assembling the tree from already-classified results is index work
        // only — no per-file I/O or string scanning happens in this loop, so
        // it stays cheap regardless of file count. Iterating in the walk's
        // own fixed order (not completion order) is what keeps the result
        // deterministic.
        for classification in classifications {
            switch classification {
            case .encrypted(let sniffed): tree.encrypted.append(sniffed)
            case .otherFormat(let url): tree.encryptedInOtherFormats.append(url)
            case .plaintextCandidate(let url): tree.plaintextCandidates.append(url)
            case .none: break
            }
        }
        return tree
    }

    /// One candidate file's classification, computed by `classify(url:maxBytes:)`.
    /// Kept internal — it is only ever produced and consumed inside this
    /// file's own concurrent pipeline.
    private enum Classification: Sendable {
        case encrypted(SniffedFile)
        case otherFormat(URL)
        case plaintextCandidate(URL)
        case none
    }

    /// Reads `url`'s tail and classifies it — the full per-file unit of work
    /// `scan` fans out over `concurrentMap`. Mirrors the classification order
    /// the pre-parallelisation implementation used: a matching `sops:` block
    /// wins over the other-format check, which wins over the filename-only
    /// plaintext-candidate check.
    ///
    /// Pattern matching happens on the raw `Data` tail, not a decoded
    /// `String` — `Data.range(of:)` is a byte-level search, materially
    /// cheaper than `String.contains`'s Unicode-aware (grapheme-cluster,
    /// canonical-equivalence) comparison, and at up to `maxSniffedFileBytes`
    /// (64 KiB) per file across 20,000 files, that difference was measured
    /// to matter: see the task-1b report. `String(data:encoding:.utf8)` is
    /// only ever called for a file that actually matched the `sops:` marker
    /// — the near-totality of files in a real project that do not — so the
    /// UTF-8 decode this needs (only for `SniffedFile.tail`, consumed later
    /// as text by `EncryptedFileMetadata`) is paid on a handful of files,
    /// not all of them.
    private static func classify(url: URL, maxBytes: Int) -> Classification {
        guard let tail = Self.tailBytes(of: url, maxBytes: maxBytes) else {
            return Self.isPlaintextSecretCandidate(url.lastPathComponent)
                ? .plaintextCandidate(url) : .none
        }
        if tail.range(of: Self.sopsBlockMarker) != nil || tail.starts(with: Self.sopsBlockPrefix),
           let text = Self.decodeTailText(tail) {
            // The byte-level marker matched *and* the tail decoded as valid
            // UTF-8 (true for every real sops output — YAML is text). A
            // decode failure here falls through to the same checks a read
            // failure would, rather than returning early, matching the
            // pre-parallelisation behaviour where a String that failed to
            // decode was indistinguishable from a tail that failed to read.
            return .encrypted(SniffedFile(url: url, tail: text))
        } else if Self.looksSopsEncryptedInAnotherFormat(tail) {
            return .otherFormat(url)
        } else if Self.isPlaintextSecretCandidate(url.lastPathComponent) {
            return .plaintextCandidate(url)
        }
        return .none
    }

    /// The synchronous directory walk: decides which directories are
    /// skipped, which regular files are visited, and where the
    /// `maxScannedFiles` budget cuts the walk off — all of it in one fixed
    /// pass whose order `scan` preserves for classification. Returns the
    /// tree pre-populated with `skippedDirectoryNames`/`wasTruncated` and the
    /// list of regular-file URLs still needing a tail read.
    private static func walk(root: URL) -> (tree: ScannedTree, candidates: [URL]) {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return (ScannedTree(), []) }

        var tree = ScannedTree()
        var seenSkippedNames: Set<String> = []
        var visitedFileCount = 0
        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                let name = url.lastPathComponent
                if Self.skippedDirectoryNames.contains(name) {
                    enumerator.skipDescendants()
                    if seenSkippedNames.insert(name).inserted {
                        tree.skippedDirectoryNames.append(name)
                    }
                }
                continue
            }
            guard values?.isRegularFile == true else { continue }

            // The budget bounds how many files this walk *visits*, not just
            // how many it classifies — checked before any work is done on
            // this file, so the count reflects files actually looked at.
            guard visitedFileCount < Self.maxScannedFiles else {
                tree.wasTruncated = true
                break
            }
            visitedFileCount += 1
            candidates.append(url)
        }
        return (tree, candidates)
    }

    /// Runs `transform` over `items` with at most `width` running
    /// concurrently, returning results **in `items`' original order**
    /// regardless of which finished first.
    ///
    /// Bounded by construction, not by a semaphore that could be gotten
    /// wrong: at most `width` child tasks are ever alive in the group at
    /// once, because a replacement task is only added when a running one
    /// finishes (`group.next()` yields exactly one completion, and exactly
    /// one new task is added in response). Seeding starts at
    /// `min(width, items.count)` tasks, so a short `items` never
    /// over-allocates. See `ProjectScanPerformanceTests.tailReadConcurrencyIsBounded`
    /// for a test that instruments this exact function and proves the
    /// in-flight count never exceeds `width`, under artificially scrambled
    /// completion order — not merely a test that it produces the right
    /// answer, which a correct-but-unbounded implementation would also pass.
    ///
    /// Determinism: each task carries its own index and writes into a
    /// pre-sized results array at that index, never appends — so the output
    /// order is the input order, not the completion order. Internal (no
    /// access modifier is needed by any caller outside this file) — it is
    /// general-purpose only in shape, not in intended use.
    static func concurrentMap<Item: Sendable, Output: Sendable>(
        _ items: [Item], width: Int, _ transform: @escaping @Sendable (Item) async -> Output
    ) async -> [Output] {
        guard !items.isEmpty else { return [] }
        let width = max(1, width)

        var results = [Output?](repeating: nil, count: items.count)
        await withTaskGroup(of: (Int, Output).self) { group in
            var nextIndex = 0
            let seedCount = min(width, items.count)
            for _ in 0..<seedCount {
                let i = nextIndex
                group.addTask { (i, await transform(items[i])) }
                nextIndex += 1
            }
            while let (i, value) = await group.next() {
                results[i] = value
                if nextIndex < items.count {
                    let j = nextIndex
                    group.addTask { (j, await transform(items[j])) }
                    nextIndex += 1
                }
            }
        }
        // Every index from 0..<items.count was seeded exactly once above
        // (seed loop + exactly one replacement per completion, until
        // nextIndex reaches items.count), so every slot was written before
        // the group finished. Force-unwrap documents that invariant rather
        // than silently coalescing a would-be bug into a dropped result.
        return results.map { $0! }
    }

    /// sops metadata as written by its non-YAML stores. Only used to keep an
    /// encrypted file from being mistaken for a plaintext one — an encrypted
    /// `.env` reported as a leaking secret is a false alarm, and false alarms
    /// are how a user learns to skip this finding.
    ///
    /// Operates on raw bytes, not a decoded `String` — see `classify`'s doc
    /// comment for why.
    private static func looksSopsEncryptedInAnotherFormat(_ tail: Data) -> Bool {
        tail.range(of: Self.dotenvMacMarker) != nil || tail.range(of: Self.dotenvVersionMarker) != nil
            || tail.range(of: Self.jsonMarker) != nil
            || tail.range(of: Self.iniMarker) != nil
    }

    private static let sopsBlockMarker = Data("\nsops:".utf8)
    private static let sopsBlockPrefix = Data("sops:".utf8)
    private static let dotenvMacMarker = Data("sops_mac=".utf8)
    private static let dotenvVersionMarker = Data("sops_version=".utf8)
    private static let jsonMarker = Data("\"sops\":".utf8)
    private static let iniMarker = Data("\n[sops]".utf8)

    /// Whether a *filename* is one that conventionally holds plaintext
    /// secrets. Names only — nothing here reads a file.
    ///
    /// The old list was three hardcoded strings (`.env`, `.env.local`,
    /// `.env.production`), so `.env.staging`, `.env.development` and
    /// `production.env` all went unreported. This covers the whole `.env`
    /// family in both spellings instead.
    ///
    /// Deliberately still narrow. Widening it to things like `credentials`,
    /// `id_rsa` or `.npmrc` would produce false alarms on files that are
    /// routinely committed on purpose, and a finding that cries wolf is one
    /// the user stops reading — which costs more than the names it would
    /// catch. The `.env` family is the case PROPOSAL.md §6 D names and the one
    /// with an unambiguous convention behind it.
    static func isPlaintextSecretCandidate(_ name: String) -> Bool {
        let lower = name.lowercased()
        // Placeholders documenting which variables exist. Committing one is
        // the point of it, so flagging it is pure noise.
        let placeholderSuffixes = [".example", ".sample", ".template", ".dist", ".defaults"]
        if placeholderSuffixes.contains(where: { lower.hasSuffix($0) }) { return false }
        if lower == ".env" || lower.hasPrefix(".env.") { return true }
        // "production.env", "local.env" — the same convention written the
        // other way round. Excludes ".env" itself, already matched above.
        return lower.hasSuffix(".env") && lower != ".env"
    }

    /// Reads at most the last `maxBytes` bytes of `url` via a direct
    /// `open`/`fstat`/`pread`/`close` sequence, as raw bytes — see
    /// `maxSniffedFileBytes` for why the tail is always where the `sops:`
    /// block lives, regardless of the file's total size, and `classify`'s
    /// doc comment for why the result stays `Data` instead of being decoded
    /// to `String` here.
    ///
    /// Replaces an earlier `FileHandle`-based version
    /// (`open` + `seekToEnd` + `seek` + `read` + `close`, each a separate
    /// Objective-C-bridged call — five round-trips per file). `pread` folds
    /// the seek into the read itself (one syscall reads at an explicit
    /// offset instead of `lseek` then `read`), and `fstat` replaces
    /// `seekToEnd()`'s round-trip-to-find-the-size with the size sourced
    /// directly, so this is four raw syscalls (`open`, `fstat`, `pread`,
    /// `close`) with no Foundation/ObjC bridging layer between this
    /// function and the kernel.
    private static func tailBytes(of url: URL, maxBytes: Int) -> Data? {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY)
        }
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }
        let size = Int(info.st_size)

        let readSize = min(maxBytes, size)
        let offset = off_t(size - readSize)

        var buffer = [UInt8](repeating: 0, count: readSize)
        let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
            pread(fd, raw.baseAddress, readSize, offset)
        }
        guard bytesRead > 0 else { return nil }
        return Data(bytes: buffer, count: bytesRead)
    }

    /// Decodes a tail already known to match the `sops:` marker into the
    /// `String` `SniffedFile.tail` needs — called only for that handful of
    /// matching files, never for the thousands that don't (see `classify`).
    private static func decodeTailText(_ tail: Data) -> String? {
        var bytes = tail
        // A byte-offset tail slice can start mid-UTF-8-codepoint. Drop
        // leading continuation bytes (0b10xxxxxx) rather than fail the
        // whole decode over a boundary nowhere near the sops: block this
        // exists to find, which sits well inside the tail, not at its very
        // first byte.
        while let first = bytes.first, first & 0b1100_0000 == 0b1000_0000 {
            bytes.removeFirst()
        }
        return String(data: bytes, encoding: .utf8)
    }
}
