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
        /// The staged set moved again while this was working out what to
        /// write, so the only text available belongs to an older set.
        /// Refused rather than written — see `applyConfig()`.
        case refusedStalePlan
        case failed(String)
    }

    public enum FileApplyRefusal: Equatable, Sendable {
        case notLoaded
        case emptyRecipients
        case noFiles
        /// Re-wrapping needs a session identity; reading never did.
        case noKey
        /// A run was already in progress the moment this call was made.
        ///
        /// Distinct from `nil`, which means *this* call is the one that
        /// started (or queued behind) a run. Before this case existed, an
        /// already-running call also returned `nil`, so a caller could not
        /// tell "under way" from "refused, nothing will happen" — and
        /// `startApplyingToFiles`'s `onRefusal` never fired for it either.
        /// `applyToFiles()` itself still only reaches this by racing another
        /// direct caller; `startApplyingToFiles` no longer produces it at
        /// all, because it now waits for whatever run was already in flight
        /// before calling `applyToFiles()` again — see its doc comment.
        case alreadyRunning
        /// The scope widened onto files a *different*, identifiable creation
        /// rule governs (`Plan.filesGovernedByOtherRules`), and the user has
        /// not said so is fine — see `requiresWidenedScopeAcknowledgement`.
        /// Ticket #24 claim 1: before this existed, the only thing standing
        /// between a user and re-wrapping another rule's files was a
        /// sentence on the panel restating what `filesInScope`'s own doc
        /// comment already calls out as the one way this fallback is not
        /// silent — reading it was never enforced.
        case widenedScopeNotAcknowledged
    }

    public private(set) var loadState: LoadState = .idle
    public private(set) var plan: ProjectRecipientApplier.Plan?
    public private(set) var registryRecords: [RecipientRecord] = []
    /// The age recipients the creation rule names **more than once**, each
    /// listed here exactly once. Same collapse, and the same reason for
    /// disclosing it rather than tidying it away, as
    /// `RecipientAccessModel.duplicatedRecipients` — sops does not deduplicate
    /// a flat rule's age list either.
    public private(set) var duplicatedRecipients: [String] = []

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
    /// Whether the user has explicitly said the current plan's widened scope
    /// — files a *different* creation rule governs — is fine. Ticket #24
    /// claim 1. Cleared on every new `plan` (`load()`, `refreshPlan()`), on
    /// purpose: an acknowledgement is about the scope the user actually saw,
    /// and a plan can change what that scope is (a file added, a rule
    /// edited elsewhere) without this model itself detecting whether it
    /// changed — clearing unconditionally is the only version of this that
    /// cannot go stale silently.
    public private(set) var widenedScopeAcknowledged = false
    /// The last-run record `load()` found on disk, when that run left files
    /// untouched (`RunRecord.wasCancelled`) — `nil` for a project with no
    /// prior run, or whose prior run completed. Ticket #24 claim 3: what the
    /// view reads to tell the user their last run did not finish, and how
    /// many files it never got to, surviving the panel having been closed
    /// and reopened. Updated again after this session's own `applyToFiles()`
    /// completes, so a run that finishes what a previous one left undone
    /// clears the banner within the same session rather than only on the
    /// next `load()`.
    public private(set) var previousIncompleteRun: RunRecord?

    /// The project this panel is about. Readable so the label editor knows
    /// which project's `.sops-gui/recipients.json` a name would be written to.
    public let projectRoot: URL
    private let keyStore: SessionKeyStore
    private let applier: ProjectRecipientApplier
    private let loadRegistry: (URL) -> [RecipientRecord]
    private var runTask: Task<Void, Never>?
    /// Which refresh is allowed to publish its result.
    ///
    /// `plan(...)` is a whole-tree walk plus a bridge call — hundreds of
    /// milliseconds — and the panel stays interactive throughout, so two
    /// refreshes can be in flight at once and can complete in either order.
    /// Without this, the *last to finish* won, which is not the same as the
    /// last to start: a plan computed for an older staged set could land on top
    /// of a newer one, and `plan.configUpdateText` is the exact text a
    /// confirmed "Update .sops.yaml" writes. The same generation-stamp
    /// technique `SecretDocumentViewModel.rowIdentityGeneration` uses.
    private var planGeneration = 0
    private var refreshTask: Task<Void, Never>?

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

    /// Live tallies over `fileResults`. The canonical place `ProjectAccessView`
    /// reads these from, rather than re-filtering `fileResults` itself —
    /// which is what it used to do, alongside `ProjectRecipientApplier
    /// .RunResult`'s own (uncalled) `updatedCount`/`failedCount`: two
    /// expressions of the same fact, computed two different ways, is how they
    /// drift. Computed over `fileResults` rather than taken from a completed
    /// `RunResult` because `fileResults` is what actually grows one file at a
    /// time while a run is still going — `applyToFiles()` appends to it via
    /// `onFileFinished` — so these update live instead of only once the run
    /// is over.
    public var updatedFileCount: Int { fileResults.filter { $0.outcome == .updated }.count }
    public var unchangedFileCount: Int { fileResults.filter { $0.outcome == .unchanged }.count }
    public var failedFileCount: Int {
        fileResults.filter { if case .failed = $0.outcome { true } else { false } }.count
    }

    /// The files an apply would touch. See
    /// `ProjectRecipientApplier.Plan.filesInScope` for why a project whose
    /// config governs nothing still has files in scope.
    public var filesToApply: [URL] { plan?.filesInScope ?? [] }

    /// Whether the current plan needs `widenedScopeAcknowledged` before
    /// `applyToFiles()` will run at all — ticket #24 claim 1.
    ///
    /// Deliberately narrower than `!plan.governingRuleIdentified`: a project
    /// whose rule matches *nothing* also falls back to every encrypted file,
    /// and that fallback is unremarkable — there is no other rule whose key
    /// set is at stake, only files nobody has opinions about yet. The
    /// consent this gate exists for is specifically about
    /// `filesGovernedByOtherRules`: files a *different*, identifiable rule
    /// already governs, which an apply here would re-wrap for a key set
    /// that rule never named.
    public var requiresWidenedScopeAcknowledgement: Bool {
        guard let plan else { return false }
        return !plan.governingRuleIdentified && !plan.filesGovernedByOtherRules.isEmpty
    }

    /// Records whether the user has said the current plan's widened scope
    /// is fine. The view's `Toggle` writes this directly; there is no
    /// validation to do here beyond storing the answer to the question that
    /// was actually asked.
    public func acknowledgeWidenedScope(_ acknowledged: Bool) {
        widenedScopeAcknowledged = acknowledged
    }

    /// Every recipient worth showing, in config order first and then staged
    /// additions. Same shape and same fallback-to-the-public-key rule as the
    /// per-file panel — `RecipientAccessModel.AccessEntry` is reused rather
    /// than mirrored so the two panels cannot drift into showing a recipient
    /// differently.
    public var entries: [RecipientAccessModel.AccessEntry] {
        var seen = Set<String>()
        var result: [RecipientAccessModel.AccessEntry] = []
        for recipient in configRecipients {
            // One `List` row per identity — see `RecipientAccessModel.entries`
            // for why this guard is restated where the id is minted rather than
            // trusted to `load()` alone.
            guard seen.insert(recipient).inserted else { continue }
            let status: RecipientAccessModel.AccessEntry.Status =
                stagedRecipients.contains(recipient) ? .unchanged : .pendingRemoval
            result.append(makeEntry(recipient, status: status))
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
        widenedScopeAcknowledged = false

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
        // Collapsed for the same reason, and by the same rule, the per-file
        // panel collapses a file's metadata: sops does not deduplicate a flat
        // rule's age list either, and two rows carrying one `AccessEntry.id`
        // is undefined row identity. See
        // `RecipientAccessModel.collapsingDuplicates`.
        let collapsed = RecipientAccessModel.collapsingDuplicates(inspected.configRecipients)
        configRecipients = collapsed.distinct
        duplicatedRecipients = collapsed.duplicated
        if stagedRecipients.isEmpty {
            stagedRecipients = collapsed.distinct
        }
        registryRecords = loadRegistry(projectRoot)
        // A record this app cannot read (corrupt JSON, a shape from a future
        // version) degrades to "nothing to report" rather than failing the
        // load — the same non-throwing-degrades-gracefully contract
        // `loadRegistry` already holds for the label directory, and for the
        // same reason: a local trace file must never be able to block the
        // panel from opening at all.
        previousIncompleteRun = (try? RunRecordStore.load(in: projectRoot))
            .flatMap { $0 }
            .flatMap { $0.wasCancelled ? $0 : nil }
        loadState = .loaded
    }

    /// Re-reads the project's registry, and *only* that.
    ///
    /// What the label editor calls after it writes a name. Not `load()`, which
    /// would re-scan the tree and reset `stagedRecipients`, discarding access
    /// edits the user staged and has not applied; and not `refreshPlan()`,
    /// because a name changes nothing a plan is about. Nothing encrypted is read
    /// or written here.
    public func reloadRegistry() {
        registryRecords = loadRegistry(projectRoot)
    }

    /// Re-plans against the current staged set, so the config preview
    /// (`plan.configUpdateText`, `plan.configRefusal`) matches what Apply
    /// would actually do. A scan plus one bridge call; it writes nothing.
    ///
    /// A result is published only if no later refresh has started since this
    /// one did — see `planGeneration`. A refresh overtaken by a newer one
    /// therefore leaves `plan` alone rather than replacing a newer plan with an
    /// older one; it is never the case that finishing last means being right.
    public func refreshPlan() async {
        guard loadState == .loaded else { return }
        planGeneration &+= 1
        let generation = planGeneration
        let fresh = await applier.plan(projectRoot: projectRoot, recipients: stagedRecipients)
        guard generation == planGeneration else { return }
        plan = fresh
        // See `widenedScopeAcknowledged`'s own doc comment: cleared
        // unconditionally on every accepted plan, not only when the scope
        // this model can detect actually changed.
        widenedScopeAcknowledged = false
    }

    /// Runs `refreshPlan()` in a task this model owns, cancelling whichever
    /// refresh was already in flight.
    ///
    /// The view calls this on every staging change rather than spawning its own
    /// detached `Task`: an unowned task cannot be cancelled, so a burst of
    /// toggles left a queue of whole-tree walks running to completion with only
    /// the generation stamp deciding which one mattered. Cancellation is a
    /// courtesy — correctness is `planGeneration`'s job — but a walk nobody
    /// will read should not go on walking.
    public func startRefreshingPlan() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refreshPlan() }
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
    ///
    /// The plan in hand is checked against the staged set *before* its text is
    /// written. A plan carries the recipient list it was computed for
    /// (`Plan.requestedRecipients`) precisely so this check can exist: a
    /// refresh that is still in flight, or one overtaken by a later staging
    /// change, leaves `plan.configUpdateText` holding the text for an older
    /// set — and writing that text would silently drop every recipient staged
    /// since, while `configRecipients` went on claiming they were in the file.
    /// A mismatch re-plans; if it still does not agree (the user staged
    /// something else again in the meantime) nothing is written at all.
    public func applyConfig() async -> ConfigApplyOutcome {
        guard plan != nil else { return .nothingToWrite }
        guard !stagedRecipients.isEmpty else { return .refusedEmptyRecipients }

        if plan?.requestedRecipients != stagedRecipients {
            await refreshPlan()
        }
        guard let plan, plan.requestedRecipients == stagedRecipients else {
            return .refusedStalePlan
        }
        guard plan.configUpdateText != nil else { return .nothingToWrite }

        switch applier.writeConfig(plan) {
        case .written:
            configWritten = true
            // From the plan, not from `stagedRecipients`: they are equal by the
            // guard above, and taking it from the thing that was actually
            // written is what keeps that true if the guard ever loosens.
            configRecipients = plan.requestedRecipients
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
        guard !requiresWidenedScopeAcknowledgement || widenedScopeAcknowledged else {
            return .widenedScopeNotAcknowledged
        }
        guard !isApplyingFiles else { return .alreadyRunning }

        isApplyingFiles = true
        fileResults = []
        notAttempted = []
        defer { isApplyingFiles = false }

        let recipients = stagedRecipients
        let applier = self.applier
        let startedAt = Date()

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

        // Ticket #24 claims 2 and 3. Persisted regardless of whether the run
        // completed or was cancelled — `RunRecord.wasCancelled` (derived
        // from `notAttempted`) is what a reader checks. `try?`: a failure to
        // persist this trace must never be reported as a failure of the
        // apply itself, which already happened and whose real results are
        // in `fileResults` on this model right now.
        let record = RunRecord(
            startedAt: startedAt, finishedAt: Date(), recipients: recipients,
            results: run.results.map { fileResult -> RunRecord.FileEntry in
                let failureReason: String?
                if case .failed(let reason) = fileResult.outcome { failureReason = reason } else { failureReason = nil }
                return RunRecord.FileEntry(
                    path: Self.relativePath(for: fileResult.url, under: projectRoot),
                    outcome: Self.recordOutcome(for: fileResult.outcome),
                    failureReason: failureReason)
            },
            notAttempted: run.notAttempted.map { Self.relativePath(for: $0, under: projectRoot) })
        try? RunRecordStore.save(record, in: projectRoot)
        // Re-read rather than reuse `record` in memory: JSON round-trips a
        // `Date` through ISO 8601 text, which is second-precision, so the
        // in-memory value (sub-second) and what a later `load()` would see
        // are not literally equal — reading back here is what keeps
        // `previousIncompleteRun` the same value a fresh `load()` in a new
        // session would produce, rather than a slightly different one only
        // this session ever sees.
        previousIncompleteRun = record.wasCancelled
            ? ((try? RunRecordStore.load(in: projectRoot)) ?? record) : nil

        return nil
    }

    /// `url`'s path relative to `projectRoot`. Duplicated from
    /// `FileListModel.relativePath(for:)` rather than shared — that type's
    /// own version of this exists for the identical reason
    /// `ProjectRecipientApplier.sortedByProjectRelativePath`'s doc comment
    /// gives for its own duplicate: a plain path computation with no
    /// dependency worth introducing one for.
    private static func relativePath(for url: URL, under root: URL) -> String {
        let base = root.standardizedFileURL.path
        var path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else { return path }
        path.removeFirst(base.count)
        if path.hasPrefix("/") { path.removeFirst() }
        return path
    }

    private static func recordOutcome(
        for outcome: ProjectRecipientApplier.FileOutcome
    ) -> RunRecord.Outcome {
        switch outcome {
        case .updated: .updated
        case .unchanged: .unchanged
        case .failed: .failed
        }
    }

    /// Runs `applyToFiles()` in a task this model can cancel. Cancellation is
    /// honoured *between* files, never inside one — see
    /// `ProjectRecipientApplier.apply(files:recipients:agePrivateKey:onFileFinished:)`.
    ///
    /// Queues behind whatever run is already in flight rather than racing it.
    /// The previous call is cancelled immediately, so it can stop as soon as
    /// its current file finishes, but this one does not call `applyToFiles()`
    /// until that previous `Task` has actually completed — awaiting its
    /// `.value`, not merely requesting its cancellation. Without that wait, a
    /// run requested while the old one was still finishing its last file
    /// reached `applyToFiles()`'s `isApplyingFiles` guard while it was still
    /// `true` and was refused on the spot: the button did nothing, silently,
    /// because nothing was left to report the refusal to `onRefusal` for.
    ///
    /// Awaiting `.value` here cannot deadlock the two runs against each
    /// other: it is a suspension point, not a lock, so the `@MainActor` this
    /// model is isolated to stays free to keep running the previous task's
    /// own remaining hops (including the one back to `applyToFiles()`'s
    /// `defer` that flips `isApplyingFiles` false) while this one waits. A
    /// user who cancels and immediately restarts still gets a real run,
    /// because the cancelled task completes quickly — cancellation is
    /// checked between every file — rather than hanging.
    public func startApplyingToFiles(onRefusal: @escaping @MainActor (FileApplyRefusal) -> Void) {
        let previous = runTask
        previous?.cancel()
        runTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            if let refusal = await self.applyToFiles() { onRefusal(refusal) }
        }
    }

    public func cancelRun() {
        runTask?.cancel()
    }
}
