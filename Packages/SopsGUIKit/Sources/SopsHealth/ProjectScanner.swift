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
    /// `true` when `root` itself could not be found as a directory —
    /// deleted, unmounted, or renamed after the project was added to the
    /// store.
    ///
    /// This exists because a walk that never ran and a walk that ran and
    /// genuinely found nothing produce the *same* empty `ScannedTree`
    /// otherwise: `encrypted == []`, `plaintextCandidates == []`,
    /// `wasTruncated == false`. `FileManager.enumerator(at:)` returns `nil`
    /// for a missing root exactly as it would for other reasons, with no way
    /// for a caller to tell "there was nothing to walk" from "I looked and
    /// there was nothing here" — and `ProjectHealthCheck` used to report the
    /// second, confident answer in both cases: `.ok`, "Looked through
    /// <path> ... and found none" about a directory that no longer exists,
    /// and a matching "No .sops.yaml in <path>" warning right below it, as
    /// if both checks had actually run. Neither had anything to look at.
    /// `ProjectHealthCheck.findings(for:)` checks this flag before treating
    /// an empty tree as a real answer about anything.
    public var rootMissing = false
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

    /// Process-wide gate on how many files this scanner has open at once,
    /// sized to `tailReadConcurrencyWidth`.
    ///
    /// `concurrentMap`'s own batching bounds concurrency *per call*, which
    /// is not the same guarantee as bounding the process's actual file
    /// descriptor usage: `tailReadConcurrencyWidth`'s own doc comment names
    /// "a user with more than one project window scanning at once" as part
    /// of the width's justification, and two concurrent `scan(root:)` calls
    /// each independently allowed up to `width` in flight can together open
    /// up to `2 * width` files at once — the FD-table concern the width
    /// exists to bound, quietly reopened one layer up. This `static let`
    /// `DispatchSemaphore` is shared by every call, in-process, so the
    /// combined total across every concurrent scan is capped at `width`,
    /// which is the guarantee actually wanted.
    ///
    /// This also matters for a reason specific to how this code is tested:
    /// Swift Testing runs multiple `@Test` functions concurrently by
    /// default, and several of this package's own tests build and scan
    /// tens-of-thousands-of-files fixtures. Without a process-wide gate,
    /// those tests' scans could collectively demand several times `width`
    /// of simultaneous blocking I/O, which is real contention no amount of
    /// picking the "right" queue or thread type can hide — see the task-1b
    /// report's account of Finding 3 for the diagnostic numbers this was
    /// measured against.
    private static let ioGate = DispatchSemaphore(value: tailReadConcurrencyWidth)

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
        // The walk is synchronous, blocking work — `FileManager` directory
        // enumeration plus a `resourceValues` call per entry — and, like the
        // tail-read-and-classify phase below, it must not run directly on
        // Swift's cooperative thread pool. An earlier version called
        // `Self.walk(root: root)` inline here, reasoning that the walk was
        // "already the fast ~15% of the budget" so it didn't need
        // parallelising — true, but beside the point: the problem was never
        // the walk's own duration, it was that a synchronous ~1s of blocking
        // syscalls sitting directly in an `async` function's body pins a
        // cooperative-pool thread idle for that whole second. On a real
        // project the walk visits at most `maxScannedFiles` (20,000) entries
        // and is genuinely fast, so this rarely matters in isolation — but
        // under Swift Testing's parallel test execution, several such scans
        // running at once (one per test, this suite's own heavy fixtures
        // included) can pin several cooperative-pool threads simultaneously,
        // starving unrelated tiny tasks queued behind them. See
        // `runOffCooperativePool` and the task-1b report's account of
        // Finding 3, which first fixed the classify phase alone and then
        // found the walk phase was still doing this.
        var (tree, candidates) = await Self.runOffCooperativePool { Self.walk(root: root) }

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
            // Gated by the process-wide `ioGate`, not just `concurrentMap`'s
            // own per-call batching — see `ioGate`'s doc comment for why a
            // per-call-only bound does not actually bound the process's
            // aggregate open-file-descriptor count when more than one
            // `scan(root:)` runs at once.
            Self.ioGate.wait()
            defer { Self.ioGate.signal() }
            return Self.classify(url: url, maxBytes: Self.maxSniffedFileBytes)
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
    ///
    /// A leading UTF-8 BOM (`EF BB BF`) is stripped from `tail` before any
    /// pattern match runs — see `stripLeadingUTF8BOM(_:)`. This is not
    /// optional: `String(data:encoding:.utf8)` silently strips a leading BOM
    /// as part of decoding, so the pre-parallelisation implementation's
    /// `tail.hasPrefix("sops:")` (a `String` operation, decoded via that same
    /// call) was always matching an already-debommed string. `sops -e` on an
    /// empty document produces a file whose *entire* content is the `sops:`
    /// block starting at byte 0 — no `\nsops:` substring exists anywhere in
    /// it, which is exactly why the prefix check exists alongside the
    /// substring one. A BOM-prefixed copy of such a file (an editor
    /// round-trip is enough to add one) still decrypts under the real `sops`
    /// binary, but without this strip its raw bytes start with the BOM, not
    /// `sops:`, and `tail.starts(with: sopsBlockPrefix)` — a byte comparison
    /// with no BOM-awareness of its own — would silently stop matching it.
    /// Regression test: `ProjectScanBOMTests`.
    private static func classify(url: URL, maxBytes: Int) -> Classification {
        guard let rawTail = Self.tailBytes(of: url, maxBytes: maxBytes) else {
            return Self.isPlaintextSecretCandidate(url.lastPathComponent)
                ? .plaintextCandidate(url) : .none
        }
        let tail = Self.stripLeadingUTF8BOM(rawTail)
        // Two stages on purpose. The byte-level marker searches below are the
        // cheap filter that runs on every file in the tree; the structural
        // confirmation behind them (`SopsMetadataShape`) runs only for the
        // handful that matched one, so the per-file cost of the walk is
        // unchanged. See `SopsMetadataShape` for why a substring alone is not
        // an answer.
        // Decoded at most once per file, and only for a file that already
        // matched a byte-level marker — the near-totality of a real project's
        // files match none and never reach this. Memoized by hand rather than
        // called in both branches: the structural confirmation costs on the
        // order of a millisecond per marker-matching file (measured across
        // this repository's eleven of them: a whole-repo scan went from
        // ~0.018s to ~0.025s), and there is no reason to pay the UTF-8 decode
        // twice on top of that.
        var decoded: String??
        func text() -> String? {
            if let decoded { return decoded }
            let value = Self.decodeTailText(tail)
            decoded = .some(value)
            return value
        }

        if tail.range(of: Self.sopsBlockMarker) != nil || tail.starts(with: Self.sopsBlockPrefix),
           let text = text(),
           SopsMetadataShape.isYAMLMetadata(text) {
            // The byte-level marker matched, the tail decoded as valid UTF-8
            // (true for every real sops output — YAML is text), *and* what it
            // decoded to has the shape sops's own serializer writes. A decode
            // failure here falls through to the same checks a read failure
            // would, rather than returning early, matching the
            // pre-parallelisation behaviour where a String that failed to
            // decode was indistinguishable from a tail that failed to read —
            // and so, now, does a structural mismatch: a file that merely
            // *mentions* a sops block is not one.
            return .encrypted(SniffedFile(url: url, tail: text))
        }
        if Self.looksSopsEncryptedInAnotherFormat(tail),
           let text = text(),
           SopsMetadataShape.isNonYAMLMetadata(text) {
            return .otherFormat(url)
        }
        if Self.isPlaintextSecretCandidate(url.lastPathComponent) {
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
        // Checked explicitly, before ever asking for an enumerator, so the
        // resulting `ScannedTree` can say *why* it's empty rather than just
        // being empty — see `ScannedTree.rootMissing`'s doc comment. A path
        // that exists but isn't a directory (the project's root replaced by
        // a plain file after being added, however unlikely) is the same
        // "nothing to walk" situation as a path that doesn't exist at all.
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            var tree = ScannedTree()
            tree.rootMissing = true
            return (tree, [])
        }

        // `root` does exist as a directory at this point, so a `nil`
        // enumerator here is some other failure (most likely a permissions
        // problem) rather than a missing directory. That is a narrower,
        // pre-existing gap this fix does not close: the walk still falls
        // back to an empty-but-not-`rootMissing` tree in that case, which
        // `ProjectHealthCheck` still cannot distinguish from "genuinely
        // empty". Worth another pass, but it is not the deleted-directory
        // case this fix addresses, and conflating the two would mislabel a
        // permissions problem as a missing project. Reviewer-verified:
        // `chmod 000` on a real project directory reproduces this — the
        // gitignore/sops-yaml findings come back false-`.ok`/false-`.warning`
        // exactly as `rootMissing` was meant to prevent, just for a
        // different underlying cause.
        //
        // A second, narrower gap sits between the `fileExists` check above
        // and the `enumerator(at:)` call below: two separate syscalls, not
        // one atomic check. Reviewer-verified that `enumerator(at:)` does
        // *not* return `nil` for a root deleted in that exact window — it
        // returns a valid enumerator that simply yields zero items, so
        // `rootMissing` stays `false` and the old dishonest empty-tree pair
        // (`.ok` gitignore, `.warning` sops-yaml, both describing a walk
        // that saw nothing because there was nothing left to see) comes
        // back for that one race. Left open: this needs an adversary timing
        // a deletion or an unmount to land inside a window this narrow, and
        // closing it would mean replacing two `FileManager` calls with a
        // single atomic directory-open-and-enumerate primitive this type
        // does not have today. Far narrower than the deleted-before-scan
        // case above, and a materially different fix than either of the
        // gaps already named here.
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

    /// Reference-type box around the results array so `concurrentMap` can
    /// share it, by reference, across the GCD worker threads
    /// `DispatchQueue.concurrentPerform` below actually runs on.
    ///
    /// `@unchecked Sendable`: the compiler cannot see that every write below
    /// targets a distinct array index (`box.values[index] = ...`, one
    /// `index` per GCD iteration, never reused), so two threads never touch
    /// the same element — safe by construction, not by locking, which is
    /// exactly why this needs the escape hatch rather than a real lock. If
    /// this invariant is ever broken by a future edit, this is where a data
    /// race would reappear.
    private final class ResultsBox<Output>: @unchecked Sendable {
        var values: [Output?]
        init(count: Int) { values = [Output?](repeating: nil, count: count) }
    }

    /// Runs `transform` over `items` with at most `width` running
    /// concurrently, returning results **in `items`' original order**
    /// regardless of which finished first.
    ///
    /// Backed by `DispatchQueue.concurrentPerform`, not `withTaskGroup`.
    /// `transform` here wraps blocking syscalls (`open`/`fstat`/`pread`/`close`
    /// in `tailBytes`), and Swift's own concurrency documentation is explicit
    /// that blocking work must never run on the cooperative thread pool a
    /// `Task`'s body executes on — that pool is sized for the machine's core
    /// count on the assumption that every thread is always making progress,
    /// and a syscall that blocks pins one of those threads idle. An earlier
    /// version of this function used `withTaskGroup`, spawning one child
    /// `Task` per file; that put every file's blocking read directly on the
    /// cooperative pool. Measured effect: a 15-file scan running *concurrently
    /// alongside* this task's own multi-thousand-file fixtures (the normal
    /// case under Swift Testing's parallel test execution) went from ~0.1s in
    /// isolation to ~2.0s — roughly 15× slower — because those 15 tiny reads
    /// were queued behind the cooperative pool's fixed thread count, which
    /// the large fixtures' own blocking reads had saturated. The identical
    /// experiment against the pre-parallelisation code (no cooperative pool
    /// involved at all) showed no such effect. `DispatchQueue.concurrentPerform`
    /// runs its iterations on GCD's own elastic worker-thread pool, which is
    /// designed to grow when threads block — exactly the shape blocking I/O
    /// needs and the cooperative pool exists specifically to not provide. See
    /// the task-1b report for both experiments' numbers.
    ///
    /// Bounded by construction: `items` is sliced into batches of at most
    /// `width`, and the next batch is not dispatched until
    /// `concurrentPerform` returns from the previous one (a synchronous,
    /// blocking call — it does not return until every iteration in that
    /// batch has completed). So at most `width` units of work are ever
    /// in flight at once, full stop — not "usually", not "unless GCD decides
    /// otherwise". See `ProjectScanPerformanceTests.tailReadConcurrencyIsBounded`
    /// for a test that instruments this exact function and proves the
    /// in-flight count never exceeds `width`, under artificially scrambled
    /// completion order — not merely a test that it produces the right
    /// answer, which a correct-but-unbounded implementation would also pass.
    ///
    /// Determinism: each GCD iteration carries its own absolute index and
    /// writes into a pre-sized results array (`ResultsBox`) at that index,
    /// never appends — so the output order is the input order, not the
    /// completion order, exactly as before.
    ///
    /// `transform` is a plain synchronous closure, not `async`, on purpose:
    /// an `async` closure invites exactly the "just `await` something inside
    /// it" pattern that put blocking work back on the cooperative pool in
    /// the first version. If a future caller genuinely needs `await` inside
    /// `transform`, that is a sign `concurrentMap` is the wrong tool for that
    /// call, not a reason to add `async` back here.
    static func concurrentMap<Item: Sendable, Output: Sendable>(
        _ items: [Item], width: Int, _ transform: @escaping @Sendable (Item) -> Output
    ) async -> [Output] {
        guard !items.isEmpty else { return [] }
        let width = max(1, width)

        return await Self.runOffCooperativePool {
            let box = ResultsBox<Output>(count: items.count)
            var start = 0
            while start < items.count {
                let end = min(start + width, items.count)
                let batchCount = end - start
                // A local, immutable copy: `start` is a `var` mutated by
                // this same loop after `concurrentPerform` returns, but the
                // closure below runs (and finishes — `concurrentPerform`
                // blocks until every iteration completes) entirely within
                // this iteration, before `start` is ever reassigned. The
                // compiler cannot see that ordering guarantee, so it is
                // captured here as a `let` instead of asking for a
                // suppressed-warning `var` capture.
                let batchStart = start
                DispatchQueue.concurrentPerform(iterations: batchCount) { offset in
                    let index = batchStart + offset
                    box.values[index] = transform(items[index])
                }
                start = end
            }
            // Every index from 0..<items.count was written by exactly one
            // iteration above (each batch covers a disjoint, contiguous
            // index range, and every batch runs). Force-unwrap documents
            // that invariant rather than silently coalescing a would-be bug
            // into a dropped result.
            return box.values.map { $0! }
        }
    }

    /// Runs a synchronous, blocking `body` on a dedicated OS thread instead
    /// of wherever the caller happens to be executing, and bridges the
    /// result back into `async` — the shared mechanism behind both the
    /// directory walk and `concurrentMap`'s outer coordination not blocking
    /// Swift's cooperative thread pool.
    ///
    /// A genuinely new `Thread`, not `DispatchQueue.global().async`. The
    /// first version of this function used the latter, and it measurably
    /// did not solve the problem it was written for: `DispatchQueue.global()`
    /// is a *shared* elastic pool, and this function's caller holds
    /// whichever worker thread it gets for as long as `body` runs — for
    /// `scan`'s two uses of this, that is the walk's full duration or an
    /// entire `concurrentMap` batch's duration, i.e. seconds, not
    /// milliseconds. Under Swift Testing's parallel test execution, several
    /// scans' worth of these long-held submissions compete for the same
    /// shared pool's finite worker supply and libdispatch's own
    /// rate-limited thread-injection pacing, so a *tiny* scan's walk could
    /// still be measured queued for over a second behind unrelated large
    /// scans' outer dispatches — reproduced directly: see the task-1b
    /// report's account of Finding 3's second round for the diagnostic
    /// numbers (a 1–3 file walk taking over a second, purely queueing delay
    /// before `Self.walk` ever started). A dedicated `Thread` is created and
    /// started immediately, with no shared queue to wait behind — the
    /// tradeoff (a new OS thread has more setup cost than reusing a pooled
    /// one) is the right one here precisely because this function is called
    /// a small, fixed number of times per scan (once for the walk, once per
    /// `concurrentMap` call), never once per file — the per-file fan-out
    /// inside a `concurrentMap` batch still goes through
    /// `DispatchQueue.concurrentPerform`, whose iterations are individually
    /// short-lived and recycle pool threads quickly, which is a materially
    /// different contention profile than a single thread pinned for a
    /// whole batch's duration.
    ///
    /// `body` is `@escaping @Sendable` because it runs on a different thread
    /// than the caller, asynchronously with respect to this function's own
    /// call site — the same reason `concurrentMap`'s `transform` is.
    private static func runOffCooperativePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: body())
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Cheap byte-level prefilter for sops metadata as written by its
    /// non-YAML stores. A hit here is a *candidate*, confirmed structurally by
    /// `SopsMetadataShape.isNonYAMLMetadata` — on its own this matches any
    /// file that happens to contain the bytes, including this very file.
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
    private static let utf8BOM = Data([0xEF, 0xBB, 0xBF])

    /// Drops a leading UTF-8 byte-order mark, if present, from a tail read.
    /// See `classify`'s doc comment for why this has to happen before any
    /// byte-level pattern match — `String(data:encoding:.utf8)` did this
    /// silently as part of decoding in the pre-parallelisation
    /// implementation, so matching that behaviour here is what keeps a
    /// BOM-prefixed sops file visible to the byte-level prefix check.
    private static func stripLeadingUTF8BOM(_ data: Data) -> Data {
        data.starts(with: Self.utf8BOM) ? data.dropFirst(Self.utf8BOM.count) : data
    }

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
    ///
    /// Every read is reported to `TailReadLedger`, which is inert unless a
    /// test has a recording open. That is the instrument
    /// `ProjectHealthCheckLargeFileTests` uses to assert the bound this
    /// function's whole design exists to provide — that a file's *size* never
    /// becomes this scanner's cost — without a wall-clock threshold, which
    /// under bare `swift test`'s single-process parallel run measures ambient
    /// machine load as much as it measures this code. See `TailReadLedger`.
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
        // Reported before the `bytesRead > 0` guard so a read that came back
        // empty is still visible as "this file was opened and read from" —
        // the alternative silently looks identical to a file that was never
        // visited, which is the vacuous-pass shape the ledger exists to make
        // impossible to write by accident.
        TailReadLedger.record(path: url.path, bytes: max(0, bytesRead))
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
