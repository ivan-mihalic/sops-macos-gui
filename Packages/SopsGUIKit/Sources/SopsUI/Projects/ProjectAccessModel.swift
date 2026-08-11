import Foundation
import Observation
import SopsEngine
import SopsProjects

/// Who can decrypt a whole project's secrets: what its `.sops.yaml` creation
/// rule says today, which encrypted files that rule governs, and the staged
/// recipient set the user may apply to either — separately.
///
/// ## Two applies, never one
/// `applyConfig()` rewrites `.sops.yaml`. `applyToFiles()` re-wraps the files.
/// Neither calls the other, and the view puts each behind its own
/// confirmation, because they are different promises: the config decides who
/// *new* files will be encrypted for, and the files decide who can read the
/// secrets that already exist. Doing one as a side effect of the other would
/// change access without saying so — see `ProjectRecipientApplier`'s doc
/// comment.
///
/// ## Staged edits are purely in memory
/// `stageAdd`/`stageRemove`/`discardStagedChanges` only touch
/// `stagedRecipients`. Nothing reaches the bridge or the filesystem until one
/// of the two apply methods is called and the user has confirmed — the same
/// contract `RecipientAccessModel` holds for one file, and pinned the same
/// way, by reading the bytes back off disk.
///
/// ## The registry is a label directory, never an access authority
/// Labels come from `RecipientRegistry`; a recipient the registry has never
/// heard of is still shown, identified by its `age1…` public key.
@MainActor
@Observable
public final class ProjectAccessModel {

    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        /// Fixed diagnostic text or the bridge's own error description —
        /// never a document value, a key or an identity.
        case failed(String)
    }

    public enum ConfigApplyOutcome: Equatable, Sendable {
        case written
        case nothingToWrite
        /// The staged set is empty. Refused before anything is touched: a
        /// creation rule with no recipients encrypts new files for nobody.
        case refusedEmptyRecipients
        case failed(String)
    }

    public enum FileApplyRefusal: Equatable, Sendable {
        case notLoaded
        case emptyRecipients
        case noFiles
        /// Re-wrapping needs a session identity; reading never did.
        case noKey
    }

    public private(set) var loadState: LoadState = .idle
    public private(set) var plan: ProjectRecipientApplier.Plan?
    public private(set) var registryRecords: [RecipientRecord] = []

    /// The recipients the project's creation rule declares today. The
    /// baseline `stagedRecipients` starts from and `entries` compares to.
    public private(set) var configRecipients: [String] = []
    public private(set) var stagedRecipients: [String] = []

    /// Results of the run in progress or the last completed one, in file
    /// order, appended as each file finishes.
    public private(set) var fileResults: [ProjectRecipientApplier.FileResult] = []
    public private(set) var isApplyingFiles = false
    /// Files a cancelled run never got to. Empty for a run that completed.
    public private(set) var notAttempted: [URL] = []
    /// Set once a config write has succeeded in this session, so the view can
    /// say so rather than leaving the button looking untouched.
    public private(set) var configWritten = false

    private let projectRoot: URL
    private let keyStore: SessionKeyStore
    private let applier: ProjectRecipientApplier
    private let loadRegistry: (URL) -> [RecipientRecord]
    private var runTask: Task<Void, Never>?

    /// - Parameters:
    ///   - projectRoot: The project this panel is about.
    ///   - keyStore: Where the session's decryption identity comes from.
    ///     Never copied out of its own lending API — see `applyToFiles()`.
    ///   - applier: The scan/plan/apply engine. Injectable for the same
    ///     reason `RecipientAccessModel`'s seams are: a test drives failure
    ///     paths without filesystem permission tricks.
    ///   - loadRegistry: How labels are read. Deliberately non-throwing — a
    ///     registry this cannot read degrades to "no labels" rather than
    ///     hiding recipients the config itself names.
    public init(
        projectRoot: URL,
        keyStore: SessionKeyStore,
        applier: ProjectRecipientApplier = ProjectRecipientApplier(),
        loadRegistry: @escaping (URL) -> [RecipientRecord] = { project in
            (try? RecipientRegistry.load(in: project)) ?? []
        }
    ) {
        self.projectRoot = projectRoot
        self.keyStore = keyStore
        self.applier = applier
        self.loadRegistry = loadRegistry
    }

    // MARK: - Derived state

    /// Whether the staged set differs from what the config declares.
    /// Compared as sets, for the same reason `RecipientAccessModel.isDirty`
    /// is: the row toggle's undo re-appends, which reorders without changing
    /// membership.
    public var isDirty: Bool { Set(stagedRecipients) != Set(configRecipients) }

    public var keyConfigured: Bool { keyStore.state == .configured }

    /// The files an apply would touch. See
    /// `ProjectRecipientApplier.Plan.filesInScope` for why a project whose
    /// config governs nothing still has files in scope.
    public var filesToApply: [URL] { plan?.filesInScope ?? [] }

    /// Every recipient worth showing, in config order first and then staged
    /// additions. Same shape and same fallback-to-the-public-key rule as the
    /// per-file panel — `RecipientAccessModel.AccessEntry` is reused rather
    /// than mirrored so the two panels cannot drift into showing a recipient
    /// differently.
    public var entries: [RecipientAccessModel.AccessEntry] {
        var seen = Set<String>()
        var result: [RecipientAccessModel.AccessEntry] = []
        for recipient in configRecipients {
            let status: RecipientAccessModel.AccessEntry.Status =
                stagedRecipients.contains(recipient) ? .unchanged : .pendingRemoval
            result.append(makeEntry(recipient, status: status))
            seen.insert(recipient)
        }
        for recipient in stagedRecipients where !seen.contains(recipient) {
            result.append(makeEntry(recipient, status: .pendingAddition))
        }
        return result
    }

    /// Entries that would lose access — what a destructive confirmation names
    /// before the user commits.
    public var pendingRemovals: [RecipientAccessModel.AccessEntry] {
        entries.filter { $0.status == .pendingRemoval }
    }

    private func makeEntry(
        _ recipient: String, status: RecipientAccessModel.AccessEntry.Status
    ) -> RecipientAccessModel.AccessEntry {
        let record = registryRecords.first { $0.ageRecipient == recipient }
        return RecipientAccessModel.AccessEntry(
            ageRecipient: recipient, label: record?.label, kind: record?.kind,
            note: record?.note, status: status)
    }

    // MARK: - Loading

    /// Scans the project and reads its config. Reads only — see
    /// `ProjectRecipientApplier.plan(projectRoot:recipients:)`.
    ///
    /// Runs exactly one scan. Nothing is staged yet at this point, so the plan
    /// is made with an empty recipient list, which the bridge treats as an
    /// *inspection*: it answers what the rule declares, which files it
    /// governs, and whether it could be rewritten, and proposes no text. The
    /// staged set is then seeded from what the rule already declares — so
    /// "Update .sops.yaml" correctly has nothing to do until the user changes
    /// something, without a second walk of the tree to establish it. Every
    /// staging change after this goes through `refreshPlan()`.
    public func load() async {
        loadState = .loading
        fileResults = []
        notAttempted = []
        configWritten = false

        let inspected = await applier.plan(projectRoot: projectRoot, recipients: stagedRecipients)

        // A walk that never happened produces the same empty result as a walk
        // that found nothing, so these two are checked before anything
        // downstream is allowed to read as an answer about this project. See
        // `ProjectRecipientApplier.Plan.rootUnreadable`.
        if inspected.rootMissing {
            plan = nil
            loadState = .failed(LocalizedKey.projectAccessRootMissing.text)
            return
        }
        if inspected.rootUnreadable {
            plan = nil
            loadState = .failed(LocalizedKey.projectAccessRootUnreadable.text)
            return
        }

        plan = inspected
        configRecipients = inspected.configRecipients
        if stagedRecipients.isEmpty {
            stagedRecipients = inspected.configRecipients
        }
        registryRecords = loadRegistry(projectRoot)
        loadState = .loaded
    }

    /// Re-plans against the current staged set, so the config preview
    /// (`plan.configUpdateText`, `plan.configRefusal`) matches what Apply
    /// would actually do. Cheap enough to call on every staging change: it is
    /// a scan plus one bridge call that writes nothing.
    public func refreshPlan() async {
        guard loadState == .loaded else { return }
        plan = await applier.plan(projectRoot: projectRoot, recipients: stagedRecipients)
    }

    // MARK: - Staging

    @discardableResult
    public func stageAdd(_ ageRecipient: String) -> RecipientAccessModel.StageAddRefusal? {
        guard loadState == .loaded else { return .notLoaded }
        let trimmed = ageRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !stagedRecipients.contains(trimmed) else { return .duplicate }
        stagedRecipients.append(trimmed)
        return nil
    }

    public func stageRemove(_ ageRecipient: String) {
        stagedRecipients.removeAll { $0 == ageRecipient }
    }

    public func discardStagedChanges() {
        stagedRecipients = configRecipients
    }

    // MARK: - Applying

    /// Writes the planned `.sops.yaml` update. Never touches a single
    /// encrypted file.
    public func applyConfig() async -> ConfigApplyOutcome {
        guard let plan else { return .nothingToWrite }
        guard !stagedRecipients.isEmpty else { return .refusedEmptyRecipients }
        guard plan.configUpdateText != nil else { return .nothingToWrite }

        switch applier.writeConfig(plan) {
        case .written:
            configWritten = true
            configRecipients = stagedRecipients
            await refreshPlan()
            return .written
        case .nothingToWrite:
            return .nothingToWrite
        case .failed(let message):
            return .failed(message)
        }
    }

    /// Re-wraps every file in `filesToApply` for exactly `stagedRecipients`.
    /// Never touches `.sops.yaml`.
    ///
    /// Returns the refusal when it cannot start; `nil` once a run has started,
    /// with progress landing in `fileResults` as each file finishes and the
    /// final tally in `notAttempted`.
    @discardableResult
    public func applyToFiles() async -> FileApplyRefusal? {
        guard loadState == .loaded else { return .notLoaded }
        guard !stagedRecipients.isEmpty else { return .emptyRecipients }
        let files = filesToApply
        guard !files.isEmpty else { return .noFiles }
        guard keyConfigured else { return .noKey }
        guard !isApplyingFiles else { return nil }

        isApplyingFiles = true
        fileResults = []
        notAttempted = []
        defer { isApplyingFiles = false }

        let recipients = stagedRecipients
        let applier = self.applier

        // `withKey` lends the identity for exactly this call and returns nil
        // without invoking the body when no key is configured — the same
        // contract `RecipientAccessModel.apply()` relies on. The guard above
        // means the nil branch is unreachable here, but it is handled rather
        // than force-unwrapped.
        let run = await keyStore.withKey { key -> ProjectRecipientApplier.RunResult in
            await applier.apply(
                files: files, recipients: recipients, agePrivateKey: key,
                onFileFinished: { [weak self] result in
                    await MainActor.run { self?.fileResults.append(result) }
                })
        }

        guard let run else { return .noKey }
        fileResults = run.results
        notAttempted = run.notAttempted
        return nil
    }

    /// Runs `applyToFiles()` in a task this model can cancel. Cancellation is
    /// honoured *between* files, never inside one — see
    /// `ProjectRecipientApplier.apply(files:recipients:agePrivateKey:onFileFinished:)`.
    public func startApplyingToFiles(onRefusal: @escaping @MainActor (FileApplyRefusal) -> Void) {
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            if let refusal = await self.applyToFiles() { onRefusal(refusal) }
        }
    }

    public func cancelRun() {
        runTask?.cancel()
    }
}
