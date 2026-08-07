import Foundation

/// A candidate file paired with the tail bytes already read from it, so
/// callers that need the content (`recipientFinding`) don't re-open and
/// re-read the file a second time after `encryptedFiles(under:)` already
/// paid that cost once.
public struct SniffedFile {
    public let url: URL
    public let tail: String
}

/// What one walk of a project tree found.
public struct ScannedTree {
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
    /// `FileHandle` seek — never more, regardless of the file's total size.
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
    public static func scan(root: URL) -> ScannedTree {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsPackageDescendants]) else { return ScannedTree() }

        var tree = ScannedTree()
        var seenSkippedNames: Set<String> = []
        var visitedFileCount = 0
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

            let tail = Self.tailText(of: url, maxBytes: Self.maxSniffedFileBytes)
            if let tail, tail.contains("\nsops:") || tail.hasPrefix("sops:") {
                tree.encrypted.append(SniffedFile(url: url, tail: tail))
            } else if let tail, Self.looksSopsEncryptedInAnotherFormat(tail) {
                tree.encryptedInOtherFormats.append(url)
            } else if Self.isPlaintextSecretCandidate(url.lastPathComponent) {
                tree.plaintextCandidates.append(url)
            }
        }
        return tree
    }

    /// sops metadata as written by its non-YAML stores. Only used to keep an
    /// encrypted file from being mistaken for a plaintext one — an encrypted
    /// `.env` reported as a leaking secret is a false alarm, and false alarms
    /// are how a user learns to skip this finding.
    private static func looksSopsEncryptedInAnotherFormat(_ tail: String) -> Bool {
        tail.contains("sops_mac=") || tail.contains("sops_version=")   // dotenv
            || tail.contains("\"sops\":")                              // json
            || tail.contains("\n[sops]")                               // ini
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

    /// Reads at most the last `maxBytes` bytes of `url` via `FileHandle`
    /// seek — see `maxSniffedFileBytes` for why the tail is always where
    /// the `sops:` block lives, regardless of the file's total size.
    private static func tailText(of url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        let readSize = min(UInt64(maxBytes), size)
        guard (try? handle.seek(toOffset: size - readSize)) != nil,
              var bytes = try? handle.read(upToCount: Int(readSize))
        else { return nil }

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
