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

        /// Only `unchangedCount` and `wasCancelled` survive as convenience
        /// tallies on this type. `updatedCount` and `failedCount` were
        /// removed: neither ever had a production caller —
        /// `ProjectAccessModel` unpacks `results`/`notAttempted` out of this
        /// struct and discards it, because the panel's own tallies have to
        /// update live as `fileResults` grows one file at a time while a run
        /// is still going, which a `RunResult` — only produced once a run is
        /// over — cannot answer mid-run. `ProjectAccessModel.updatedFileCount`
        /// / `.failedFileCount` are the real, single home for that count now;
        /// duplicating it here as well is exactly the "two expressions of one
        /// fact" this module's other docs warn drifts apart. `unchangedCount`
        /// is kept because it is still asserted directly against a completed
        /// `RunResult` in this module's own tests, documenting the type's
        /// contract independent of any UI.
        public var unchangedCount: Int { results.filter { $0.outcome == .unchanged }.count }
        public var wasCancelled: Bool { !notAttempted.isEmpty }
    }

    /// Everything a user needs to see before deciding: which files are in
    /// scope, what the config says today, and whether this app can rewrite it.
    public struct Plan: Sendable {
        public let projectRoot: URL
        public let configURL: URL
        /// Whether there is a `.sops.yaml` at the project root at all.
        public let configExists: Bool
        /// The recipient set this plan was computed for.
        ///
        /// Carried on the plan rather than only known by the caller because a
        /// plan is produced asynchronously and a caller may stage another
        /// change while one is in flight: two overlapping `plan(...)` calls can
        /// complete in either order, so "the plan I am holding" and "the set I
        /// am about to write" are two different questions. `configUpdateText`
        /// is the text for *this* list and no other — anything writing it must
        /// check this field first. See `ProjectAccessModel.applyConfig()`.
        public let requestedRecipients: [String]
        /// Every sops-encrypted YAML file the scan found, sorted ascending by
        /// path relative to `projectRoot` — the order the user already sees in
        /// the file list, and the order `targetFile` is taken from. See
        /// `sortedByProjectRelativePath`.
        ///
        /// One entry per file, not per name: a project holding both a symlink
        /// and its target holds one file, and it appears once, under the name
        /// that is the file. See `deduplicatedByResolvedPath`.
        public let encryptedFiles: [URL]
        /// How many names the scan found for a file already counted in
        /// `encryptedFiles` — the number `deduplicatedByResolvedPath` dropped.
        /// Zero for a project with no such alias. Not itself a warning: a
        /// symlink inside a project is unremarkable, but the count the user
        /// sees in `encryptedFiles.count` is smaller than the number of paths
        /// the scan actually found, and that gap deserves a word. See
        /// `ProjectAccessView`'s disclosure.
        public let duplicateFileNameCount: Int
        /// The subset of `encryptedFiles` governed by the same creation rule
        /// as `targetFile` — identified by the rule's *position* in
        /// `creation_rules`, not by two rules happening to name the same keys.
        public let matchedFiles: [URL]
        /// Encrypted files some other rule governs, or no rule does. Shown,
        /// not hidden: a project apply that quietly skipped files would be the
        /// confident-about-what-it-did-not-look-at failure PROPOSAL §6 D
        /// forbids.
        public let unmatchedFiles: [URL]
        /// Encrypted files that some creation rule *other* than the one this
        /// plan is about governs.
        ///
        /// Not the same list as `unmatchedFiles`, and it matters most where
        /// that one is empty: when no governing rule could be identified,
        /// `filesInScope` widens to every encrypted file found, and some of
        /// those may belong to rules with entirely different key sets. This is
        /// what lets the panel say so before an apply rather than after. See
        /// `filesInScope`.
        public let filesGovernedByOtherRules: [URL]
        /// The file whose governing rule this plan is about — the first
        /// encrypted file in project-relative path order, which is the first
        /// one the user sees in the file list. `nil` when the scan found none.
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
        ///
        /// What the fallback must not be is *silent*: it can reach across
        /// creation-rule boundaries, pulling in files whose keys another rule
        /// decides. `filesGovernedByOtherRules` names how many, and the panel
        /// and its confirmation both say so before anything is re-wrapped.
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
            try SopsBridge.recipients(in: $0, format: .yaml)
        },
        rewrapRecipients: @escaping @Sendable (String, [String], String) throws -> String = {
            try SopsBridge.updateRecipients($0, format: .yaml, to: $1, agePrivateKey: $2)
        },
        scanProject: @escaping @Sendable (URL) async -> ScannedTree = {
            await ProjectScanner.scan(root: $0, maxScannedFiles: ScanBudgetSetting.current())
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
        // TEMPORARY (Task 5, SOPS-38): `tree.encrypted` has carried dotenv
        // files since this task — before it, only YAML ever reached here.
        // Everything below this point — `readRecipients`/`rewrapRecipients`
        // above and `SopsBridge.updateConfigRecipients` in `proposeConfig` —
        // is still hardcoded to `format: .yaml`, because rewrapping a
        // project-wide recipient set is out of this task's scope (the next
        // task widens it). Feeding a dotenv file's contents to a
        // YAML-format bridge call here would not fail loudly — the tail read
        // in `readFile` doesn't care what it decodes to be *called*, so a
        // dotenv document would either be misread as YAML or (more likely)
        // rejected with a confusing "not valid YAML" error attributed to a
        // file that is a perfectly valid dotenv one. Excluding it here is
        // safer than reaching that call and finding out which. Remove this
        // filter once `readRecipients`/`rewrapRecipients`/`proposeConfig`
        // are format-aware.
        let yamlOnly = tree.encrypted.filter { $0.format == .yaml }
        let encryptedFiles = Self.sortedByProjectRelativePath(
            Self.deduplicatedByResolvedPath(
                Self.sortedByProjectRelativePath(yamlOnly.map(\.url), under: projectRoot)),
            under: projectRoot)
        // How many names the dedup above dropped. Computed once and reused
        // across every return below, including the ones that pass `[]` for
        // `encryptedFiles` — those are only reached when the scan itself
        // found nothing, so this is 0 there too. Measured against `yamlOnly`,
        // not `tree.encrypted`: a dotenv file excluded by the temporary
        // filter above is not a duplicate name, and counting it as one would
        // misreport why `encryptedFiles` is shorter than the raw scan.
        let duplicateFileNameCount = yamlOnly.count - encryptedFiles.count
        let configURL = projectRoot.appendingPathComponent(".sops.yaml")
        let configExists = FileManager.default.fileExists(atPath: configURL.path)

        guard configExists else {
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: false,
                requestedRecipients: recipients,
                encryptedFiles: encryptedFiles, duplicateFileNameCount: duplicateFileNameCount,
                matchedFiles: [], unmatchedFiles: encryptedFiles,
                filesGovernedByOtherRules: [],
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
                requestedRecipients: recipients,
                encryptedFiles: [], duplicateFileNameCount: duplicateFileNameCount,
                matchedFiles: [], unmatchedFiles: [],
                filesGovernedByOtherRules: [],
                targetFile: nil, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: configFingerprint, configError: nil,
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        }

        let update: ConfigRecipientUpdate
        do {
            update = try proposeConfig(
                Self.ruleMatchingPath(configURL), Self.ruleMatchingPath(targetFile),
                recipients, encryptedFiles.map(Self.ruleMatchingPath))
        } catch let error as SopsBridgeError {
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: true,
                requestedRecipients: recipients,
                encryptedFiles: encryptedFiles, duplicateFileNameCount: duplicateFileNameCount,
                matchedFiles: [], unmatchedFiles: encryptedFiles,
                filesGovernedByOtherRules: [],
                targetFile: targetFile, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: configFingerprint, configError: error.description,
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        } catch {
            return Plan(
                projectRoot: projectRoot, configURL: configURL, configExists: true,
                requestedRecipients: recipients,
                encryptedFiles: encryptedFiles, duplicateFileNameCount: duplicateFileNameCount,
                matchedFiles: [], unmatchedFiles: encryptedFiles,
                filesGovernedByOtherRules: [],
                targetFile: targetFile, incompleteScanReason: tree.incompleteScanReason,
                configRecipients: [], configRefusal: nil, configUpdateText: nil,
                configFingerprint: configFingerprint,
                configError: "this project's .sops.yaml could not be read",
                rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
        }

        let matchedPaths = Set(update.matchedFiles)
        let matched = encryptedFiles.filter { matchedPaths.contains(Self.ruleMatchingPath($0)) }
        let unmatched = encryptedFiles.filter { !matchedPaths.contains(Self.ruleMatchingPath($0)) }
        let otherRulePaths = Set(update.filesGovernedByOtherRules)
        let governedElsewhere = encryptedFiles.filter {
            otherRulePaths.contains(Self.ruleMatchingPath($0))
        }

        return Plan(
            projectRoot: projectRoot, configURL: configURL, configExists: true,
            requestedRecipients: recipients,
            encryptedFiles: encryptedFiles, duplicateFileNameCount: duplicateFileNameCount,
            matchedFiles: matched, unmatchedFiles: unmatched,
            filesGovernedByOtherRules: governedElsewhere,
            targetFile: targetFile, incompleteScanReason: tree.incompleteScanReason,
            configRecipients: update.currentRecipients,
            configRefusal: update.writable ? nil : update.reason,
            configUpdateText: update.writable && update.changed ? update.config : nil,
            configFingerprint: configFingerprint, configError: nil,
            rootMissing: tree.rootMissing, rootUnreadable: tree.rootUnreadable)
    }

    /// `urls` in the order the user already sees them, which is the order
    /// `FileListModel.refresh()` puts the project's file list in: ascending by
    /// path relative to the project root.
    ///
    /// This is not cosmetic. `plan` resolves which creation rule the panel is
    /// about from the *first* encrypted file, and `ProjectScanner` yields files
    /// in `FileManager.enumerator` order — directory-hash order on APFS, which
    /// is neither alphabetical nor stable across adding or deleting an
    /// unrelated file. Unsorted, a multi-rule project therefore targeted
    /// whichever file the filesystem happened to hand back first: not the file
    /// the user sees at the top of the list, and not the same rule twice in a
    /// row. For an action that rewrites who a project encrypts for, the choice
    /// has to be predictable and has to match what is on screen.
    ///
    /// The relative-path computation is duplicated from
    /// `FileListModel.relativePath(for:)` rather than shared, because that type
    /// lives in `SopsUI`, which depends on this module and not the other way
    /// round — the same reason `runOffCooperativePool` is duplicated here.
    /// `ProjectRecipientApplierOrderingTests` pins the resulting order.
    static func sortedByProjectRelativePath(_ urls: [URL], under root: URL) -> [URL] {
        func relativePath(_ url: URL) -> String {
            // Both sides through `ruleMatchingPath`, for the reason its own doc
            // comment gives: the scan's URLs come back with the directory
            // prefix's symlinks resolved and the project root's do not, so
            // stripping one from the other as a literal prefix is otherwise a
            // no-op and this sorts absolute paths. It happens to produce the
            // same order while every path shares a prefix, which is what kept
            // it invisible.
            let base = ruleMatchingPath(root)
            var path = ruleMatchingPath(url)
            guard path.hasPrefix(base) else { return path }
            path.removeFirst(base.count)
            if path.hasPrefix("/") { path.removeFirst() }
            return path
        }
        return urls.sorted { relativePath($0) < relativePath($1) }
    }

    /// The form of a path the bridge's rule selection is given.
    ///
    /// sops decides which creation rule governs a file by stripping the
    /// config's own directory off the file's path *as a literal prefix* and
    /// matching `path_regex` against what is left (config/config.go's
    /// `parseCreationRuleForFile`, transcribed in `matchingRuleIndex`). That
    /// only works if the two paths are spelled the same way — and they were
    /// not: `FileManager.enumerator` hands back entries with symlinks in the
    /// directory prefix already resolved (`/var/…` comes back as
    /// `/private/var/…`), while the project root keeps whatever form it was
    /// added in, because `ProjectStore` deliberately stores the display path a
    /// symlink was added under. With the two disagreeing, the prefix strip is a
    /// no-op and every rule is matched against an *absolute* path: an anchored
    /// `path_regex` like `^prod/` then matches nothing at all, and an
    /// unanchored one like `.*\.yaml$` matches everything, which is why this
    /// went unnoticed — the fixtures used the second kind.
    ///
    /// Resolving both sides here rather than at the seams keeps `Plan.configURL`
    /// and the file URLs themselves exactly as the caller supplied them: this
    /// form is used to *ask about* files, never to write one.
    static func ruleMatchingPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// One entry per *file*, where `urls` may hold several names for one.
    ///
    /// `ProjectScanner` reports a symlink to a regular file as a file in its
    /// own right, deliberately — from the project's point of view it is one.
    /// But a project holding both a symlink and its target hands this two URLs
    /// for one inode, and every count downstream then double-counts it: the
    /// files on the panel, the number in the destructive confirmation, and the
    /// per-file result table, which showed the same file twice with two
    /// different outcomes (`.updated` for the first name, then `.unchanged`
    /// for the second, arriving at a file the first had already re-wrapped —
    /// so a user was told a file they do not have was left alone).
    ///
    /// The survivor is the name that *is* the file, not one that merely
    /// reaches it, whatever the sort order says. Not cosmetic: it is the name
    /// shown in the results, and a file listed under a name whose contents can
    /// change from underneath it is a confusing thing to report a write
    /// against. (The write itself is safe either way —
    /// `AtomicFileWriter.write` resolves the path before replacing it, so a
    /// symlink is never overwritten with a copy of its target.)
    ///
    /// Where neither name is the file — two symlinks to a target outside the
    /// project — the first in the order given wins, which is why this is
    /// handed an already-sorted list: the choice must not depend on
    /// `FileManager.enumerator` order. `sortedByProjectRelativePath`'s doc
    /// comment has the full account of why that order is never trusted here.
    ///
    /// The duplicate is dropped silently. Saying so would take a sentence on
    /// the panel, and there is no honest one-line version of it — "this file
    /// is also reachable as ./alias.yaml" is a disclosure about the project's
    /// layout, not about the change being applied, and inventing a
    /// user-facing string for it is a decision for the view.
    static func deduplicatedByResolvedPath(_ urls: [URL]) -> [URL] {
        var chosen: [String: URL] = [:]
        var order: [String] = []
        for url in urls {
            let resolved = ruleMatchingPath(url)
            guard let existing = chosen[resolved] else {
                chosen[resolved] = url
                order.append(resolved)
                continue
            }
            let existingIsTheFile = existing.standardizedFileURL.path == resolved
            let thisIsTheFile = url.standardizedFileURL.path == resolved
            if thisIsTheFile, !existingIsTheFile { chosen[resolved] = url }
        }
        return order.compactMap { chosen[$0] }
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

        // A `nil` fingerprint alongside a file that reads fine is not a
        // harmless unknown: `AtomicFileWriter.write(expecting: nil)` *disables*
        // the changed-since-read check entirely, so a rewrap of this file would
        // be the one write in this app that clobbers a second writer
        // unconditionally. The window is narrow — the file has to appear
        // between the fingerprint above and the read — but the accepted
        // best-effort contract is a micro-window between check and rename, not
        // a check that never runs. `RecipientAccessModel.load()` refuses the
        // analogous state for the same reason; this refuses it too.
        if fingerprint == nil, FileManager.default.fileExists(atPath: url.path) {
            return .failed(
                "this file changed while it was being read, so this app cannot tell what it read: "
                    + url.lastPathComponent)
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
