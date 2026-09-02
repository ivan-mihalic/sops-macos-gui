import Foundation
import Observation
import SopsEngine
import SopsHealth
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

        /// What this refusal is called on screen.
        ///
        /// Lived on `ProjectAccessView` until SOPS-39 task 10 retired that
        /// panel; it belongs on the refusal itself, so no caller can produce
        /// one without a sentence to show for it. `RewrapCoordinator` is why
        /// it has to exist outside a view at all: a rule it cannot re-wrap is
        /// skipped *by name*, and the name is this.
        public var explanation: String {
            switch self {
            case .emptyRecipients: LocalizedKey.projectAccessErrorEmptyRecipients.text
            case .noFiles: LocalizedKey.projectAccessErrorNoFiles.text
            case .noKey: LocalizedKey.accessNeedsKeyBody.text
            case .notLoaded: LocalizedKey.projectAccessScanning.text
            case .alreadyRunning: LocalizedKey.projectAccessErrorAlreadyRunning.text
            case .widenedScopeNotAcknowledged:
                LocalizedKey.projectAccessErrorWidenedScopeNotAcknowledged.text
            }
        }
    }

    public private(set) var loadState: LoadState = .idle
    public private(set) var plan: ProjectRecipientApplier.Plan?
    public private(set) var registryRecords: [RecipientRecord] = []
    /// Set when the last registry read found `recipients.json` present but
    /// undecodable and moved it aside — see `RecipientRegistry
    /// .loadOrQuarantine(in:)`. `nil` on every ordinary path, including a
    /// project that has simply never named a recipient.
    public private(set) var registryQuarantineNotice: String?
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
    /// Where the session's decryption identity comes from. Readable so
    /// `RewrapCoordinator` can build the per-rule models a project-wide
    /// rewrap needs from the same store this model was given — the key
    /// itself never leaves `SessionKeyStore.withKey`'s lending API.
    public let keyStore: SessionKeyStore
    private let applier: ProjectRecipientApplier
    /// The file the panel should describe the governing rule of — typically
    /// whichever file is selected in the file list. `nil` falls back to
    /// `ProjectRecipientApplier.plan`'s own default: the first file in
    /// project-relative path order.
    private let targetFile: URL?
    private let loadRegistry: (URL) -> (records: [RecipientRecord], quarantineNotice: String?)
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
    ///   - targetFile: The file the panel should describe the governing rule
    ///     of. `nil` falls back to the first file in project-relative path
    ///     order — see `ProjectRecipientApplier.plan`.
    ///   - loadRegistry: How labels are read. Deliberately non-throwing — a
    ///     registry this cannot read degrades to "no labels" rather than
    ///     hiding recipients the config itself names. Returns a notice
    ///     alongside the records exactly when the registry existed but could
    ///     not be decoded and was moved aside — see `registryQuarantineNotice`.
    public init(
        projectRoot: URL,
        keyStore: SessionKeyStore,
        applier: ProjectRecipientApplier = ProjectRecipientApplier(),
        targetFile: URL? = nil,
        loadRegistry: @escaping (URL) -> (records: [RecipientRecord], quarantineNotice: String?) = { project in
            RecipientRegistry.loadOrQuarantine(in: project)
        }
    ) {
        self.projectRoot = projectRoot
        self.targetFile = targetFile
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

    /// Everything the Access page shows that a `Plan` alone does not: the
    /// project's named keys, every creation rule (not only the governing
    /// one), and each encrypted file's own recipients measured against the
    /// rule that governs it. Built by the same scan `plan()` already ran —
    /// see `AccessInventory` — so reading it costs nothing beyond a load
    /// that has happened anyway, and `nil` exactly while no load has
    /// succeeded yet.
    public var inventory: AccessInventory? { plan?.inventory }

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

    /// The files an apply would touch, each paired with its own document
    /// format (`ProjectRecipientApplier.ScopedFile`) since Task 7 (SOPS-38) —
    /// see `ProjectRecipientApplier.Plan.filesInScope` for why a project
    /// whose config governs nothing still has files in scope, and for why
    /// this is format-tagged rather than bare `URL`.
    public var filesToApply: [ProjectRecipientApplier.ScopedFile] { plan?.filesInScope ?? [] }

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

        let inspected = await applier.plan(
            projectRoot: projectRoot, recipients: stagedRecipients, targetFile: targetFile)

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
        let registry = loadRegistry(projectRoot)
        registryRecords = registry.records
        registryQuarantineNotice = registry.quarantineNotice
        // A record this app cannot read (corrupt JSON, a shape from a future
        // version) degrades to "nothing to report" rather than failing the
        // load — the same non-throwing-degrades-gracefully contract
        // `loadRegistry` already holds for the label directory, and for the
        // same reason: a local trace file must never be able to block the
        // panel from opening at all.
        //
        // Note the deliberate asymmetry with the registry directly above,
        // which *does* now surface a notice when it quarantines a corrupt
        // file: that one holds names the user typed and would silently lose,
        // so its loss is worth a sentence. This one is a trace of the app's
        // own last run, and re-running the apply reconstructs it.
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
        let registry = loadRegistry(projectRoot)
        registryRecords = registry.records
        registryQuarantineNotice = registry.quarantineNotice
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
        let fresh = await applier.plan(
            projectRoot: projectRoot, recipients: stagedRecipients, targetFile: targetFile)
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

    /// Adds a named key — one of the config's existing `keys:` anchors — to
    /// creation rule `ruleIndex` as an alias, then reloads.
    ///
    /// The one config edit available on a rule built from anchors or key
    /// groups, which `applyConfig()` refuses outright because rewriting such
    /// a rule's whole list means guessing at things the file does not say.
    /// It does not touch the staged set: the staged set belongs to the rule
    /// this model is *about*, and this may be any rule on the page. It
    /// re-encrypts nothing either — the reload is what makes the newly
    /// drifted files show up in the rewrap banner.
    public func addAliasToRule(ruleIndex: Int, anchor: String) async
        -> ProjectRecipientApplier.ConfigWriteOutcome
    {
        guard let plan else { return .nothingToWrite }
        let outcome = applier.addAliasToRule(
            configURL: plan.configURL, ruleIndex: ruleIndex, anchor: anchor,
            expecting: plan.configFingerprint)
        if case .written = outcome { configWritten = true }
        await load()
        return outcome
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

        // Captured before the run against `configRecipients` — the set the
        // governing rule declared when this was last loaded/planned — never
        // against a per-file "did this file actually lose one", which
        // `applyToOne` computes but does not expose. See
        // `recordRotationDebtIfNeeded`'s doc comment for why that
        // approximation is the honest one to make here.
        let removedRecipients = Set(configRecipients).subtracting(stagedRecipients)

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

        recordRotationDebtIfNeeded(removedRecipients: removedRecipients, results: run.results)
        return nil
    }

    /// `url`'s path relative to `projectRoot`. Duplicated from
    /// `FileListModel.relativePath(for:)` rather than shared — that type's
    /// own version of this exists for the identical reason
    /// `ProjectRecipientApplier.sortedByProjectRelativePath`'s doc comment
    /// gives for its own duplicate: a plain path computation with no
    /// dependency worth introducing one for.
    ///
    /// ⚠️ Not the same function as `projectRelativePath(of:in:)` below, which
    /// arrived in the same week from separate work and looks close enough to
    /// invite collapsing the two. They differ where it matters: this one
    /// compares `standardizedFileURL` paths, that one compares
    /// `CanonicalPath` (symlink-resolving). The run record this feeds is a
    /// local trace read back within the session; the rotation-debt ledger
    /// that one feeds is persisted, shared, and matched against paths
    /// computed elsewhere, so it cannot afford a `/var`-versus-`/private/var`
    /// mismatch. Collapse them only after deciding which semantics both
    /// callers should have.
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

    /// Records, in this project's `RotationDebtLedger`, that every file this
    /// run actually re-wrapped now owes a rotation — when a recipient was
    /// staged for removal at all.
    ///
    /// One recipient set is shared by every file `applyToFiles()` touches,
    /// so this cannot ask "did *this* file specifically lose a recipient" —
    /// `ProjectRecipientApplier.applyToOne` knows that (it already compares
    /// each file's own actual recipients against the requested set to
    /// decide `.updated` vs `.unchanged`), but does not expose it on
    /// `FileResult`. What this can say honestly is narrower but still
    /// correct: a file this run left `.unchanged` already matched the
    /// requested set, so it never held the removed recipient in the first
    /// place and owes nothing; a file marked `.updated` changed to match a
    /// set that no longer includes a recipient it previously declared to
    /// this project's config, which is exactly the condition
    /// `RotationDebtReason.recipientRemoved` describes. `.failed` files are
    /// left alone — nothing was actually re-wrapped for them.
    ///
    /// Best-effort and silent on failure, for the same reason
    /// `RecipientAccessModel.recordRotationDebtIfNeeded` is: the files this
    /// follows have already been re-wrapped and written, and a ledger write
    /// failing must never be reported as if the access change itself had.
    private func recordRotationDebtIfNeeded(
        removedRecipients: Set<String>, results: [ProjectRecipientApplier.FileResult]
    ) {
        guard !removedRecipients.isEmpty else { return }
        for result in results where result.outcome == .updated {
            let path = Self.projectRelativePath(of: result.url, in: projectRoot)
            try? RotationDebtLedger.record(path: path, reason: .recipientRemoved, in: projectRoot)
        }
    }

    /// `url`'s path relative to `projectRoot`, for the ledger entry's `path`
    /// field — never absolute, see `RotationDebtEntry.path`'s doc comment.
    /// Same shape and same fallback as
    /// `RecipientAccessModel.projectRelativePath`, duplicated rather than
    /// shared for the reason given there.
    private static func projectRelativePath(of url: URL, in projectRoot: URL) -> String {
        let filePath = CanonicalPath.of(url.path)
        let rootPrefix = CanonicalPath.of(projectRoot.path) + "/"
        guard filePath.hasPrefix(rootPrefix) else { return url.lastPathComponent }
        return String(filePath.dropFirst(rootPrefix.count))
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
