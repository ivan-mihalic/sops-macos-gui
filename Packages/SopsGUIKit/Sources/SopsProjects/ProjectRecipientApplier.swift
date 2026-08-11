import Foundation
import SopsEngine
import SopsHealth

/// Applies one age recipient set across a whole project: which files a
/// project's `.sops.yaml` rule governs, what rewriting that rule would produce,
/// and the ordered, per-file result of re-wrapping each file for the new set.
///
/// ## Three separate actions, never one
///
/// Planning, rewriting `.sops.yaml`, and re-wrapping files are three calls, and
/// each is meant to sit behind its own explicit confirmation. Nothing here
/// changes a project's configuration as a side effect of changing its files, or
/// the other way round — `apply(files:recipients:agePrivateKey:)` never reads
/// the config at all, and `writeConfig(_:)` never touches a
/// document. The bridge makes half of that structural: `SopsBridge
/// .updateConfigRecipients` only ever *computes* the new config text (see its
/// doc comment), so a plan can be shown to a user without anything being at
/// risk of having already happened.
///
/// ## One bad file does not stop the run
///
/// A file that cannot be read, is not a SOPS document, is encrypted for
/// recipients the session key cannot decrypt, or cannot be written back is
/// recorded as `.failed` with a reason and the run *continues*. Results come
/// back in the order the files were given, one per file, so a caller can show
/// a table against the list it handed over. Cancellation is honoured
/// **between** files and never inside one: a run stopped mid-write would leave
/// exactly the partial state `AtomicFileWriter` exists to prevent.
///
/// ## What it never does
///
/// It never derives recipients from the config (that would change who can read
/// a file without saying so), never spawns the `sops` CLI, never puts key
/// material in the environment, and never lets a private identity or a
/// document value reach a `FileResult.failed` reason — every reason is either
/// fixed text or the bridge's own value-free diagnostic.
public struct ProjectRecipientApplier: Sendable {

    // MARK: - Results

    public enum FileOutcome: Equatable, Sendable {
        /// Re-wrapped for the new set and written back.
        case updated
        /// The file already listed exactly the requested recipients, so
        /// nothing was decrypted, re-wrapped or written. Distinct from
        /// `.updated` because a no-op rewrap still changes a file's MAC and
        /// `lastmodified`, and a user watching a project-wide run deserves to
        /// know which files this actually touched.
        case unchanged
        /// The associated text is fixed diagnostic text or the bridge's own
        /// error description — never a document value, a key, or an identity.
        case failed(String)
    }

    public struct FileResult: Identifiable, Equatable, Sendable {
        public let url: URL
        public let outcome: FileOutcome
        public var id: URL { url }

        public init(url: URL, outcome: FileOutcome) {
            self.url = url
            self.outcome = outcome
        }
    }

    public struct RunResult: Equatable, Sendable {
        /// One entry per file actually attempted, in the order given.
        public let results: [FileResult]
        /// Files never attempted because the run was cancelled between files.
        /// Reported rather than dropped: "we stopped here" is information a
        /// user needs to decide what to do next.
        public let notAttempted: [URL]

        public var updatedCount: Int { results.filter { $0.outcome == .updated }.count }
        public var unchangedCount: Int { results.filter { $0.outcome == .unchanged }.count }
        public var failedCount: Int {
            results.filter { if case .failed = $0.outcome { true } else { false } }.count
        }
        public var wasCancelled: Bool { !notAttempted.isEmpty }
    }

    /// Everything a user needs to see before deciding: which files are in
    /// scope, what the config says today, and whether this app can rewrite it.
    public struct Plan: Sendable {
        public let projectRoot: URL
        public let configURL: URL
        /// Whether there is a `.sops.yaml` at the project root at all.
        public let configExists: Bool
        /// Every sops-encrypted YAML file the scan found, in scan order.
        public let encryptedFiles: [URL]
        /// The subset of `encryptedFiles` governed by the same creation rule
        /// as `targetFile` — identified by the rule's *position* in
        /// `creation_rules`, not by two rules happening to name the same keys.
        public let matchedFiles: [URL]
        /// Encrypted files some other rule governs, or no rule does. Shown,
        /// not hidden: a project apply that quietly skipped files would be the
        /// confident-about-what-it-did-not-look-at failure PROPOSAL §6 D
        /// forbids.
        public let unmatchedFiles: [URL]
        /// The file whose governing rule this plan is about — the first
        /// encrypted file in scan order. `nil` when the scan found none.
        public let targetFile: URL?
        /// Why nothing derived from this scan may claim to cover the whole
        /// project. `nil` when the walk did cover it.
        public let incompleteScanReason: String?
        /// The age recipients the governing rule declares today.
        public let configRecipients: [String]
        /// `nil` when the config can be rewritten; otherwise the sentence
        /// explaining which shape was found and what to do instead.
        public let configRefusal: String?
        /// The exact text to write over `.sops.yaml`, or `nil` when there is
        /// nothing to write — either because the config already declares the
        /// requested set, or because it is not rewritable.
        public let configUpdateText: String?
        /// What `.sops.yaml` looked like when this plan read it, to pass as
        /// the write's `expecting:` so a config changed in the meantime is
        /// refused rather than clobbered.
        public let configFingerprint: FileFingerprint?
        /// Set when the config could not be read or parsed at all — a missing
        /// file, invalid YAML, an unparseable `path_regex`. Distinct from
        /// `configRefusal`, which is a config this app read fine and chose
        /// not to rewrite.
        public let configError: String?
        /// The project root is not there any more — deleted, unmounted, or
        /// renamed since it was added.
        public let rootMissing: Bool
        /// The project root exists but this process cannot read it.
        ///
        /// Carried through rather than folded into "no files found", for the
        /// reason `ScannedTree.rootUnreadable`'s own doc comment gives: an
        /// empty result from a walk that never happened and an empty result
        /// from a walk that found nothing are the same value, and reporting
        /// the second when the first is true is a confident claim about a
        /// directory this app never looked inside.
        public let rootUnreadable: Bool

        /// Whether writing the config would change anything. False for a
        /// config that is unwritable *and* for one that already agrees.
        public var configNeedsWriting: Bool { configUpdateText != nil }

        /// Whether this app actually knows which creation rule governs these
        /// files. False for a project with no `.sops.yaml`, one whose config
        /// could not be read, one where no rule matches anything found here,
        /// and one where the scan found no files at all.
        ///
        /// It is the difference between `matchedFiles` meaning "the rule
        /// covers exactly these" and meaning "nothing was worked out". A
        /// caller must not read an empty `matchedFiles` as "this rule governs
        /// no files" when the second is true — see `filesInScope`.
        public var governingRuleIdentified: Bool {
            configExists && configError == nil && targetFile != nil && !matchedFiles.isEmpty
        }

        /// The files an apply should touch: the ones the governing rule
        /// covers when there is one, and otherwise every encrypted file found.
        ///
        /// The fallback is deliberate and is not a widening of scope behind
        /// the user's back: re-wrapping files is an explicit act on the files
        /// themselves and never consults the config, so a project whose
        /// `.sops.yaml` is missing, unreadable or governs nothing is still a
        /// project whose files can be re-wrapped. What must not happen is the
        /// *other* reading — treating an empty `matchedFiles` as "the rule
        /// covers nothing", which would silently apply to no files at all and
        /// report success.
        public var filesInScope: [URL] {
            governingRuleIdentified ? matchedFiles : encryptedFiles
        }
    }

    // MARK: - Seams
    //
    // The same injection seams `RecipientAccessModel` uses, for the same
    // reason: a test can force a read, write, bridge or scan failure without
    // filesystem permission tricks, and can count calls to prove that a path
    // which must not touch the bridge or the disk does not.

    private let readFile: @Sendable (URL) throws -> String
    private let fingerprintFile: @Sendable (URL) -> FileFingerprint?
    private let writeFile: @Sendable (String, URL, FileFingerprint?) throws -> Void
    private let readRecipients: @Sendable (String) throws -> [String]
    private let rewrapRecipients: @Sendable (String, [String], String) throws -> String
    private let scanProject: @Sendable (URL) async -> ScannedTree
    private let proposeConfig: @Sendable (String, String, [String], [String]) throws -> ConfigRecipientUpdate

    public init(
        readFile: @escaping @Sendable (URL) throws -> String = {
            try String(contentsOf: $0, encoding: .utf8)
        },
        fingerprintFile: @escaping @Sendable (URL) -> FileFingerprint? = { FileFingerprint.of($0) },
        writeFile: @escaping @Sendable (String, URL, FileFingerprint?) throws -> Void = {
            contents, url, expecting in
            try AtomicFileWriter.write(contents, to: url, expecting: expecting)
        },
        readRecipients: @escaping @Sendable (String) throws -> [String] = {
            try SopsBridge.recipients(in: $0)
        },
        rewrapRecipients: @escaping @Sendable (String, [String], String) throws -> String = {
            try SopsBridge.updateRecipients($0, to: $1, agePrivateKey: $2)
        },
        scanProject: @escaping @Sendable (URL) async -> ScannedTree = {
            await ProjectScanner.scan(root: $0)
        },
        proposeConfig: @escaping @Sendable (String, String, [String], [String]) throws
            -> ConfigRecipientUpdate = { configPath, targetPath, recipients, candidates in
                try SopsBridge.updateConfigRecipients(
                    configPath: configPath, targetFilePath: targetPath,
                    to: recipients, candidateFilePaths: candidates)
            }
    ) {
        self.readFile = readFile
        self.fingerprintFile = fingerprintFile
        self.writeFile = writeFile
        self.readRecipients = readRecipients
        self.rewrapRecipients = rewrapRecipients
        self.scanProject = scanProject
        self.proposeConfig = proposeConfig
    }

    // MARK: - Planning

    /// Walks `projectRoot`, works out which encrypted files the governing
    /// creation rule covers, and asks the bridge what rewriting that rule to
    /// `recipients` would produce.
    ///
    /// Reads only. Nothing on disk changes, including `.sops.yaml` — the
    /// bridge call this makes cannot write (see
    /// `SopsBridge.updateConfigRecipients`).
    ///
    /// `recipients` is the set the user is proposing. It is needed here rather
    /// than only at write time because the answer a user has to see — "this
    /// rule can be updated / here is why it cannot" — is the same call that
    /// produces the text.
    public func plan(projectRoot: URL, recipients: [String]) async -> Plan {
        let tree = await scanProject(projectRoot)
        let encryptedFiles = tree.encrypted.map(\.url)
        let configURL = projectRoot.appendingPathComponent(".sops.yaml")
        let configExists = FileManager.default.fileExists(atPath: configURL.path)

        guard configExists else {
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: false,
                encryptedFiles: encryptedFiles, matchedFiles: [], unmatchedFiles: encryptedFiles,
                targetFile: encryptedFiles.first, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: nil, configError: nil,
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        }

        // Taken before the read, for the same reason `SecretDocumentViewModel
        // .load()` does it in that order: a concurrent write then leaves this
        // holding an older fingerprint against newer contents, so the write
        // refuses rather than clobbers.
        let configFingerprint = fingerprintFile(configURL)

        guard let targetFile = encryptedFiles.first else {
            // No file to resolve a rule for. The config is not an error and
            // not a refusal — there is simply nothing to ask about it.
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: true,
                encryptedFiles: [], matchedFiles: [], unmatchedFiles: [],
                targetFile: nil, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: configFingerprint, configError: nil,
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        }

        let update: ConfigRecipientUpdate
        do {
            update = try proposeConfig(
                configURL.path, targetFile.path, recipients, encryptedFiles.map(\.path))
        } catch let error as SopsBridgeError {
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: true,
                encryptedFiles: encryptedFiles, matchedFiles: [], unmatchedFiles: encryptedFiles,
                targetFile: targetFile, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: configFingerprint, configError: error.description,
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        } catch {
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: true,
                encryptedFiles: encryptedFiles, matchedFiles: [], unmatchedFiles: encryptedFiles,
                targetFile: targetFile, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: configFingerprint,
                configError: "this project's .sops.yaml could not be read",
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        }

        let matchedPaths = Set(update.matchedFiles)
        let matched = encryptedFiles.filter { matchedPaths.contains($0.path) }
        let unmatched = encryptedFiles.filter { !matchedPaths.contains($0.path) }

        return Plan(
            projectRoot: projectRoot, configURL: configURL, configExists: true,
            encryptedFiles: encryptedFiles, matchedFiles: matched, unmatchedFiles: unmatched,
            targetFile: targetFile, incompleteScanReason: tree.incompleteScanReason,
            configRecipients: update.currentRecipients,
            configRefusal: update.writable ? nil : update.reason,
            configUpdateText: update.writable && update.changed ? update.config : nil,
            configFingerprint: configFingerprint, configError: nil,
            rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
    }

    // MARK: - Writing the config

    public enum ConfigWriteOutcome: Equatable, Sendable {
        case written
        /// There was nothing to write: the rule already declares the
        /// requested set, or it is one this app will not rewrite.
        case nothingToWrite
        /// The associated text is `AtomicFileWriter.Error`'s own description
        /// (a path and an `errno`) or fixed text — never file contents.
        case failed(String)
    }

    /// Writes `plan.configUpdateText` over `.sops.yaml`, atomically, refusing
    /// if the file changed since `plan` read it.
    ///
    /// Its own call, deliberately: this is the step that changes who can read
    /// a project's secrets, and it must be reachable only from a user saying
    /// so, never from having applied recipients to files.
    public func writeConfig(_ plan: Plan) -> ConfigWriteOutcome {
        guard let text = plan.configUpdateText else { return .nothingToWrite }
        do {
            try writeFile(text, plan.configURL, plan.configFingerprint)
            return .written
        } catch let error as AtomicFileWriter.Error {
            return .failed(error.description)
        } catch {
            return .failed("this project's .sops.yaml could not be written")
        }
    }

    // MARK: - Applying to files

    /// Re-wraps each of `files` for exactly `recipients`, in order, writing
    /// each one atomically and refusing any whose bytes changed since this
    /// read them.
    ///
    /// Never reads `.sops.yaml`: the set applied is the one handed in, which
    /// is what makes this an explicit act rather than a config sync with
    /// unstated consequences.
    ///
    /// A file already listing exactly `recipients` is reported `.unchanged`
    /// and is never decrypted — no identity is used on it and no write
    /// happens, so a re-run over a project costs one metadata read per
    /// already-correct file.
    ///
    /// Cancellation (`Task.isCancelled`) is checked once **before** each file
    /// and never during one. A run stopped part-way reports what it did and
    /// what it did not get to, in `RunResult.notAttempted`.
    ///
    /// `agePrivateKey` is used only for the duration of this call and is never
    /// stored, logged, or put in a result. Callers get it from
    /// `SessionKeyStore.withKey`, which is what bounds its lifetime.
    ///
    /// `onFileFinished` is called once per attempted file, in order, as soon
    /// as that file is done — so a caller can show a project-wide run
    /// progressing instead of a spinner that reveals everything at the end.
    /// It is `async` so a `@MainActor` model can update its own state from it
    /// without a detached hop of its own.
    public func apply(
        files: [URL],
        recipients: [String],
        agePrivateKey: String,
        onFileFinished: @escaping @Sendable (FileResult) async -> Void = { _ in }
    ) async -> RunResult {
        var results: [FileResult] = []
        results.reserveCapacity(files.count)

        for (offset, url) in files.enumerated() {
            if Task.isCancelled {
                return RunResult(results: results, notAttempted: Array(files[offset...]))
            }
            // One file's decrypt/re-encrypt is hundreds of milliseconds of
            // blocking work; a project-wide run is that many times over. Left
            // inline in this `async` function it would pin a cooperative-pool
            // thread for the whole run — see `ProjectScanner
            // .runOffCooperativePool`'s doc comment for the measurements
            // behind not using `Task.detached` or `DispatchQueue.global()`
            // here. The hop is per file rather than around the whole loop so
            // that the cancellation check above stays a real suspension point
            // between files.
            let outcome = await Self.runOffCooperativePool {
                applyToOne(url, recipients, agePrivateKey)
            }
            let result = FileResult(url: url, outcome: outcome)
            results.append(result)
            await onFileFinished(result)
        }
        return RunResult(results: results, notAttempted: [])
    }

    /// Runs blocking `body` on a dedicated OS thread and bridges the result
    /// back into `async`, rather than letting it block a cooperative-pool
    /// thread. Same technique and same reasoning as
    /// `ProjectScanner.runOffCooperativePool` and
    /// `RecipientAccessModel.runOffCooperativePool`; duplicated rather than
    /// shared because both of those are private to their own files.
    private static func runOffCooperativePool<T: Sendable>(
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: body()) }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// One file's whole read-check-rewrap-write cycle. Every failure path
    /// returns rather than throws, because a project run must not be able to
    /// end early by accident.
    private func applyToOne(_ url: URL, _ recipients: [String], _ key: String) -> FileOutcome {
        let fingerprint = fingerprintFile(url)

        let contents: String
        do {
            contents = try readFile(url)
        } catch {
            return .failed("this file could not be read: \(url.lastPathComponent)")
        }

        guard contents.crossesCBoundaryIntact else {
            return .failed(
                "this file contains a NUL byte, which this app cannot read without silently "
                    + "dropping everything after it: \(url.lastPathComponent)")
        }

        let current: [String]
        do {
            current = try readRecipients(contents)
        } catch let error as SopsBridgeError {
            return .failed(error.description)
        } catch {
            return .failed("this file's recipients could not be read: \(url.lastPathComponent)")
        }

        // Compared as sets: the order sops writes key groups in is not
        // something a user chose, so a reordering is not a change to who can
        // read the file, and re-wrapping for it would rewrite the file (new
        // MAC, new `lastmodified`) for nothing.
        guard Set(current) != Set(recipients) else { return .unchanged }

        let rewrapped: String
        do {
            rewrapped = try rewrapRecipients(contents, recipients, key)
        } catch let error as SopsBridgeError {
            return .failed(error.description)
        } catch {
            return .failed("this file's recipients could not be updated: \(url.lastPathComponent)")
        }

        do {
            try writeFile(rewrapped, url, fingerprint)
        } catch let error as AtomicFileWriter.Error {
            return .failed(error.description)
        } catch {
            return .failed("this file could not be written: \(url.lastPathComponent)")
        }
        return .updated
    }
}
