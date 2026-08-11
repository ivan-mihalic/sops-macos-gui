import SopsProjects
import SwiftUI

/// The sheet behind the file list's "Project Access…" button: who the whole
/// project is encrypted for, which files a change would touch, and two
/// separate, separately confirmed applies — one for `.sops.yaml`, one for the
/// files.
///
/// Public rather than private so a test in `SopsUITests` can render it through
/// `GatingHost` and read the result off the accessibility tree — which is how
/// `ProjectAccessScopeDisclosureTests` checks that a scope sentence is really
/// on the panel and not merely correct in the model.
///
/// It has deliberately **no** `SnapshotTool/Catalog.swift` entry, unlike most
/// public views here: this one runs a live `ProjectScanner` walk from its own
/// `.task`, which the single-shot headless renderer would race — it draws once
/// and exits, so it would capture a spinner or a half-loaded panel depending on
/// timing. Accepted as carried-forward debt rather than papered over with a
/// fixture that renders a state the real panel never holds. Nothing in the app
/// constructs this except `AppShell`'s file-list pane.
///
/// ## Staged, not live
/// Every add/remove only calls `ProjectAccessModel.stageAdd`/`stageRemove`.
/// Nothing reaches disk until the user presses one of the two apply buttons
/// *and* confirms the dialog behind it. A staged removal is named in the
/// confirmation before anything is re-wrapped.
public struct ProjectAccessView: View {
    @Bindable private var model: ProjectAccessModel
    private let onClose: () -> Void
    private let onFilesApplied: () -> Void

    @State private var newRecipientText = ""
    @State private var addRefusal: RecipientAccessModel.StageAddRefusal?
    @State private var confirmingConfigUpdate = false
    @State private var confirmingFileApply = false
    @State private var errorMessage: String?
    @State private var labelEdit: RecipientLabelEditRequest?

    public init(
        model: ProjectAccessModel,
        onClose: @escaping () -> Void,
        onFilesApplied: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose
        self.onFilesApplied = onFilesApplied
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(.projectAccessTitle).font(.headline)

            content

            HStack {
                if model.isApplyingFiles {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(LocalizedKey.projectAccessApplyingLabel.text)
                    Button(LocalizedKey.projectAccessCancelRun.text) { model.cancelRun() }
                }
                Spacer()
                Button(LocalizedKey.actionDone.text) {
                    model.discardStagedChanges()
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isApplyingFiles)

                Button(LocalizedKey.projectAccessUpdateConfigButton.text) {
                    confirmingConfigUpdate = true
                }
                .disabled(!canUpdateConfig)

                Button(LocalizedKey.projectAccessApplyFilesButton.text) {
                    confirmingFileApply = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canApplyToFiles)
            }
        }
        .padding(16)
        .frame(width: 560)
        .task { await model.load() }
        .confirmationDialog(
            LocalizedKey.projectAccessUpdateConfigConfirmTitle.text,
            isPresented: $confirmingConfigUpdate
        ) {
            Button(LocalizedKey.projectAccessUpdateConfigConfirmButton.text) {
                Task { await applyConfig() }
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {}
        } message: {
            Text(configUpdateConfirmationMessage)
        }
        .confirmationDialog(
            LocalizedKey.projectAccessApplyFilesConfirmTitle.text,
            isPresented: $confirmingFileApply
        ) {
            Button(
                LocalizedKey.projectAccessApplyFilesConfirmButton.text,
                role: model.pendingRemovals.isEmpty ? nil : .destructive
            ) {
                model.startApplyingToFiles { refusal in
                    errorMessage = Self.explanation(for: refusal)
                }
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {}
        } message: {
            Text(fileApplyConfirmationMessage)
        }
        .alert(
            LocalizedKey.projectAccessErrorTitle.text,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in if !isPresented { errorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Naming a recipient writes the registry and nothing else, so what
        // follows a save is `reloadRegistry()` — never `load()`, which would
        // re-scan and discard the staged access edits this sheet is holding,
        // and not `startRefreshingPlan()` either: a name changes nothing a plan
        // is about.
        .sheet(item: $labelEdit) { request in
            RecipientLabelEditorView(
                model: request.model,
                onClose: { labelEdit = nil },
                onChanged: { model.reloadRegistry() })
        }
        // Keyed on the run *finishing*, not on the result count: the last
        // result is appended by `onFileFinished` while `isApplyingFiles` is
        // still true, and the assignment that follows it sets the same count
        // again — so a count-keyed observer would see no change at the one
        // moment this needs to fire, and the editor would keep a stale save
        // fingerprint for a file this had just re-wrapped.
        .onChange(of: model.isApplyingFiles) { wasApplying, isApplying in
            guard wasApplying, !isApplying, !model.fileResults.isEmpty else { return }
            // The open document's own save fingerprint goes stale the moment
            // this re-wraps its file, so the editor is told to reload — the
            // same resync `SecretEditorView` does after the single-file panel
            // applies.
            onFilesApplied()
        }
    }

    // MARK: - Gates
    //
    // Pulled out as pure functions — mirroring `RecipientAccessView.canApply`
    // and `SecretEditorView.canOpenAccessPanel` — so they are testable
    // without rendering this view or driving a system dialog.

    private var canUpdateConfig: Bool {
        Self.canUpdateConfig(
            loadState: model.loadState, configNeedsWriting: model.plan?.configNeedsWriting == true,
            stagedIsEmpty: model.stagedRecipients.isEmpty, isApplyingFiles: model.isApplyingFiles)
    }

    static func canUpdateConfig(
        loadState: ProjectAccessModel.LoadState, configNeedsWriting: Bool,
        stagedIsEmpty: Bool, isApplyingFiles: Bool
    ) -> Bool {
        loadState == .loaded && configNeedsWriting && !stagedIsEmpty && !isApplyingFiles
    }

    private var canApplyToFiles: Bool {
        Self.canApplyToFiles(
            loadState: model.loadState, fileCount: model.filesToApply.count,
            stagedIsEmpty: model.stagedRecipients.isEmpty,
            keyConfigured: model.keyConfigured, isApplyingFiles: model.isApplyingFiles)
    }

    static func canApplyToFiles(
        loadState: ProjectAccessModel.LoadState, fileCount: Int, stagedIsEmpty: Bool,
        keyConfigured: Bool, isApplyingFiles: Bool
    ) -> Bool {
        loadState == .loaded && fileCount > 0 && !stagedIsEmpty && keyConfigured && !isApplyingFiles
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch model.loadState {
        case .idle, .loading:
            VStack(spacing: 8) {
                ProgressView()
                Text(.projectAccessScanning).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .failed(let message):
            VStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.red)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, minHeight: 200)
        case .loaded:
            loadedContent
        }
    }

    private var loadedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            scope
            filesPreview
            configSection

            List(model.entries) { entry in
                ProjectAccessRow(
                    entry: entry, onToggle: { toggleRemoval(for: entry) },
                    onEditLabel: { editLabel(for: entry) })
            }
            .frame(minHeight: 130, maxHeight: 200)
            .listStyle(.inset)
            .disabled(model.isApplyingFiles)

            HStack {
                TextField(LocalizedKey.accessAddRecipientField.text, text: $newRecipientText)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(addStagedRecipient)
                Button(LocalizedKey.actionAdd.text, action: addStagedRecipient)
                    .disabled(!RecipientRowContent.canAdd(newRecipientText))
            }
            .disabled(model.isApplyingFiles)

            if let addRefusal, addRefusal == .duplicate {
                Text(.accessAddDuplicate).font(.caption).foregroundStyle(.red)
            }
            // A key the creation rule names twice is collapsed into one row —
            // multiplicity is not access — but never without saying so. See
            // `ProjectAccessModel.duplicatedRecipients`.
            if !model.duplicatedRecipients.isEmpty {
                Text(
                    String(
                        format: LocalizedKey.projectAccessDuplicateRecipients.text,
                        model.duplicatedRecipients.count)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.keyConfigured {
                Label(.accessNeedsKeyBody, systemImage: "key.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            results
        }
    }

    /// What this panel is about to act on, and — just as important — what it
    /// is not. A scan that fell short says so, in the same sentence the file
    /// list and the health check use for the same condition.
    @ViewBuilder
    private var scope: some View {
        if let plan = model.plan {
            if let reason = plan.incompleteScanReason {
                VStack(alignment: .leading, spacing: 2) {
                    Label(.projectAccessScanIncompleteTitle, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.12))
            }

            if plan.encryptedFiles.isEmpty {
                Text(.projectAccessNoFiles).font(.caption).foregroundStyle(.secondary)
            } else if plan.governingRuleIdentified {
                Text(
                    String(
                        format: LocalizedKey.projectAccessFilesSummary.text,
                        plan.matchedFiles.count, plan.encryptedFiles.count)
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !plan.unmatchedFiles.isEmpty {
                    Text(
                        String(
                            format: LocalizedKey.projectAccessUnmatchedNote.text,
                            plan.unmatchedFiles.count)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                // No governing rule could be identified, so `filesInScope`
                // widens to every encrypted file found. That is the *widest*
                // an apply ever gets, and it used to be the one case the panel
                // said nothing about — the count appeared for the first time
                // in the confirmation dialog. See `Plan.filesInScope`.
                Text(
                    String(
                        format: LocalizedKey.projectAccessAllFilesInScope.text,
                        plan.filesInScope.count)
                )
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                // And the half of that widening the count alone hides: this
                // branch reaches across creation-rule boundaries. A file
                // governed by a rule with a different key set is re-wrapped
                // here exactly like one governed by nothing, and
                // `projectAccessUnmatchedNote` — the sentence that says
                // "governed by a different creation rule" — renders only in
                // the branch above, which is the one branch where it is not
                // needed.
                if !plan.filesGovernedByOtherRules.isEmpty {
                    Text(
                        String(
                            format: LocalizedKey.projectAccessOtherRulesInScope.text,
                            plan.filesGovernedByOtherRules.count)
                    )
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// What `.sops.yaml` says, and what — if anything — this app is willing to
    /// do about it. A shape it will not rewrite is explained here rather than
    /// discovered as a failure after the user presses a button.
    @ViewBuilder
    private var configSection: some View {
        if let plan = model.plan {
            VStack(alignment: .leading, spacing: 4) {
                Text(.projectAccessConfigSectionTitle)
                    .font(.caption.weight(.semibold))

                if !plan.configExists {
                    Text(.projectAccessNoConfig).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let error = plan.configError {
                    explanation(.projectAccessConfigErrorTitle, error, tint: .red)
                } else if let refusal = plan.configRefusal {
                    explanation(.projectAccessConfigReadOnlyTitle, refusal, tint: .orange)
                } else if model.configWritten {
                    Text(.projectAccessConfigWritten).font(.caption).foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !plan.configNeedsWriting {
                    Text(.projectAccessConfigUpToDate).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The files an apply would re-wrap, named — before it re-wraps them.
    ///
    /// The counts above say how many; this says which, which is the question a
    /// user has to answer before pressing a button that rewrites files. It
    /// scrolls inside a fixed height and builds its rows lazily, so a project
    /// with hundreds of encrypted files costs the same as one with two and does
    /// not push the buttons off the sheet.
    ///
    /// Rows are identified positionally rather than by URL: `encryptedFiles`
    /// does not deduplicate by resolved path, so a symlink and its target can
    /// both appear, and identity-by-value would be the same `List`-with-two-
    /// identical-ids defect the recipient rows just had.
    ///
    /// Not a `LazyVStack`: laziness is what would keep the cost flat, but a
    /// lazy stack inside a `ScrollView` realises nothing at all under the
    /// headless host these panels are checked through — measured, not assumed —
    /// so the list would be untestable and, worse, would be untestable in the
    /// direction that looks like it passes. `previewedFiles` bounds the cost
    /// instead, by building a fixed number of rows and counting the rest.
    @ViewBuilder
    private var filesPreview: some View {
        if let plan = model.plan, !model.filesToApply.isEmpty {
            let preview = Self.previewedFiles(model.filesToApply)
            VStack(alignment: .leading, spacing: 2) {
                Text(.projectAccessFilesPreviewTitle).font(.caption.weight(.semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(preview.shown.enumerated()), id: \.offset) { _, file in
                            // A path is not translatable, and resolved through
                            // the catalog it would vanish under whichever build
                            // system copies `.xcstrings` uncompiled — the same
                            // reason `KeyImportView` renders paths this way.
                            Text(verbatim: Self.previewPath(of: file, in: plan.projectRoot))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if preview.overflow > 0 {
                            Text(
                                String(
                                    format: LocalizedKey.projectAccessFilesPreviewMore.text,
                                    preview.overflow)
                            )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 96)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// How many previewed rows are ever built. A preview exists to answer "is
    /// this the set I meant?", which the first screenful and an honest
    /// remainder answer as well as an unbounded list would — and unlike an
    /// unbounded list, at a cost that does not grow with the project.
    static let filesPreviewLimit = 100

    /// The files the preview draws, and how many it did not.
    static func previewedFiles(_ files: [URL]) -> (shown: [URL], overflow: Int) {
        guard files.count > filesPreviewLimit else { return (files, 0) }
        return (Array(files.prefix(filesPreviewLimit)), files.count - filesPreviewLimit)
    }

    /// How a previewed file is named: its path relative to the project root, or
    /// its own last component when it is not under the root at all.
    ///
    /// Both sides are resolved before the strip. `ProjectScanner` returns
    /// entries with the directory prefix's symlinks already resolved
    /// (`/var/…` → `/private/var/…`) while the project root keeps whatever
    /// spelling it was added under, so a literal prefix strip is a no-op and
    /// every file would be previewed by its absolute path. That exact mismatch
    /// is what made every anchored `path_regex` fail to match for the whole of
    /// this feature's development — see `ProjectRecipientApplier.ruleMatchingPath`.
    /// This form is used only to *name* a file on screen; nothing is ever
    /// written through it.
    static func previewPath(of file: URL, in root: URL) -> String {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let filePath = file.resolvingSymlinksInPath().standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard filePath.hasPrefix(prefix) else { return file.lastPathComponent }
        return String(filePath.dropFirst(prefix.count))
    }

    /// `detail` is engine-produced or fixed diagnostic text shown verbatim —
    /// the same treatment a health finding's own sentence gets, and for the
    /// same reason: it names the specific shape found, which no fixed
    /// translation could.
    private func explanation(_ title: LocalizedKey, _ detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(tint)
            Text(detail).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var results: some View {
        if !model.fileResults.isEmpty || !model.notAttempted.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(.projectAccessResultsTitle).font(.caption.weight(.semibold))
                Text(
                    String(
                        format: LocalizedKey.projectAccessResultsSummary.text,
                        "\(model.fileResults.filter { $0.outcome == .updated }.count)",
                        "\(model.fileResults.filter { $0.outcome == .unchanged }.count)",
                        "\(model.fileResults.filter { if case .failed = $0.outcome { true } else { false } }.count)")
                )
                .font(.caption).foregroundStyle(.secondary)

                if !model.notAttempted.isEmpty {
                    Text(
                        String(
                            format: LocalizedKey.projectAccessCancelledNote.text,
                            model.notAttempted.count)
                    )
                    .font(.caption).foregroundStyle(.orange)
                }

                ForEach(model.fileResults) { result in
                    ProjectAccessResultRow(result: result)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func addStagedRecipient() {
        addRefusal = model.stageAdd(newRecipientText)
        if addRefusal == nil {
            newRecipientText = ""
            model.startRefreshingPlan()
        }
    }

    private func toggleRemoval(for entry: RecipientAccessModel.AccessEntry) {
        if entry.status == .pendingRemoval {
            model.stageAdd(entry.ageRecipient)
        } else {
            model.stageRemove(entry.ageRecipient)
        }
        model.startRefreshingPlan()
    }

    private func editLabel(for entry: RecipientAccessModel.AccessEntry) {
        labelEdit = RecipientLabelEditRequest(
            model: RecipientLabelEditorModel(
                projectURL: model.projectRoot,
                ageRecipient: entry.ageRecipient,
                existing: model.registryRecords.first { $0.ageRecipient == entry.ageRecipient }))
    }

    private func applyConfig() async {
        switch await model.applyConfig() {
        case .written, .nothingToWrite:
            break
        case .refusedEmptyRecipients:
            errorMessage = LocalizedKey.projectAccessErrorEmptyRecipients.text
        case .refusedStalePlan:
            errorMessage = LocalizedKey.projectAccessErrorStalePlan.text
        case .failed(let message):
            errorMessage = message
        }
    }

    /// What rewriting the creation rule changes, and for whom.
    ///
    /// This was the one mutating action of the three whose confirmation named
    /// nobody. It described the reformatting a rewrite causes and said files on
    /// disk are untouched, both true, but never who the rule would start or stop
    /// encrypting *new* files for — while the other two dialogs both name the
    /// people involved. Rewriting a rule really does not change access to
    /// anything that exists, which is why it was left; the asymmetry inside one
    /// feature is its own defect.
    ///
    /// The removal sentence carries the distinction rather than assuming the
    /// reader supplies it: dropping a recipient here takes nothing away from
    /// them. With nothing staged there is nobody to name, and the message is
    /// exactly the mechanical disclosure it always was — an empty "and nobody
    /// changes" sentence would be noise.
    ///
    /// Internal rather than private for the same reason
    /// `fileApplyConfirmationMessage` is.
    var configUpdateConfirmationMessage: String {
        var parts: [String] = []
        let gained = model.entries.filter { $0.status == .pendingAddition }
        if !gained.isEmpty {
            parts.append(
                String(
                    format: LocalizedKey.projectAccessConfigGains.text,
                    gained.map { $0.label ?? $0.ageRecipient }.joined(separator: ", ")))
        }
        let lost = model.pendingRemovals
        if !lost.isEmpty {
            parts.append(
                String(
                    format: LocalizedKey.projectAccessConfigLoses.text,
                    lost.map { $0.label ?? $0.ageRecipient }.joined(separator: ", ")))
        }
        parts.append(LocalizedKey.projectAccessUpdateConfigConfirmMessage.text)
        return parts.joined(separator: "\n\n")
    }

    /// Internal rather than private so a test can read the exact sentence the
    /// dialog will carry — a `.confirmationDialog`'s own body is not reachable
    /// from a unit test (the documented limitation `WorkspaceSwitchDecisionTests`
    /// states), so the string it is handed is the last thing that can be pinned.
    var fileApplyConfirmationMessage: String {
        let count = model.filesToApply.count
        var message: String
        if model.pendingRemovals.isEmpty {
            message = String(format: LocalizedKey.projectAccessApplyFilesConfirmMessage.text, count)
        } else {
            let names = model.pendingRemovals.map { $0.label ?? $0.ageRecipient }
            message = String(
                format: LocalizedKey.projectAccessApplyFilesRemovalMessage.text,
                names.joined(separator: ", "), count)
        }
        // The panel says this too (see `scope`), and the dialog says it again:
        // this is the last screen before files governed by *other* creation
        // rules are re-wrapped for a key set those rules never named.
        if let plan = model.plan, !plan.governingRuleIdentified,
            !plan.filesGovernedByOtherRules.isEmpty
        {
            message += "\n\n" + String(
                format: LocalizedKey.projectAccessOtherRulesInScope.text,
                plan.filesGovernedByOtherRules.count)
        }
        return message
    }

    static func explanation(for refusal: ProjectAccessModel.FileApplyRefusal) -> String {
        switch refusal {
        case .emptyRecipients: LocalizedKey.projectAccessErrorEmptyRecipients.text
        case .noFiles: LocalizedKey.projectAccessErrorNoFiles.text
        case .noKey: LocalizedKey.accessNeedsKeyBody.text
        case .notLoaded: LocalizedKey.projectAccessScanning.text
        }
    }
}

/// Whether the file list's Project Access button may be pressed.
///
/// Its own type, not a method on the (file-private) workspace view, for the
/// same reason `WorkspaceSwitchDecision` and `QuitRequest` are: the judgement
/// is what a test needs to reach, and a `private struct` inside `AppShell.swift`
/// is not reachable even with `@testable`.
///
/// Requires a **clean** open document, for the same reason
/// `SecretEditorView.canOpenAccessPanel` does: a project-wide apply re-wraps
/// every file the creation rule governs, which may include the file open in
/// the editor, and the reload that resyncs the editor's own save fingerprint
/// afterwards discards every pending edit, addition and removal — silently.
///
/// ## Why this gate has one term fewer, deliberately
/// `SecretEditorView.canOpenAccessPanel` also requires `loadState == .loaded`.
/// This one **does not require a loaded document**, and the difference is a
/// decision rather than an omission. The per-file panel's subject *is* the open
/// document: without a successful load there is no file whose recipients it
/// could be about, and the model it would build would have nothing to read. This
/// panel's subject is the project. It scans the tree and reads `.sops.yaml`
/// itself, from its own `.task`, and is perfectly meaningful with no document
/// open at all — which is the ordinary case, since the file list is where the
/// button lives. Requiring a loaded document here would disable the project
/// panel for a user who has not opened anything yet, for no benefit.
///
/// The terms they *do* share are the unsaved-work ones, and those are identical
/// on purpose: both panels can rewrite the file underneath an editor holding
/// edits nobody saved. `AccessGateAsymmetryTests` pins both halves — that the
/// load-state term is the only difference, and that this paragraph exists.
enum ProjectAccessGate {
    static func canOpen(hasProject: Bool, documentIsDirty: Bool, documentIsSaving: Bool) -> Bool {
        hasProject && !documentIsDirty && !documentIsSaving
    }
}

/// One recipient row: label (or raw public key, when the registry has no
/// record), the key beneath a label, the registry's kind, a staged-change
/// badge, and the toggle. The kind badge is `RecipientKindBadge`, shared with
/// the per-file panel so the same recipient cannot read differently in the two
/// places it appears.
private struct ProjectAccessRow: View {
    let entry: RecipientAccessModel.AccessEntry
    let onToggle: () -> Void
    let onEditLabel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.label ?? entry.ageRecipient)
                    .font(entry.label == nil ? .system(.body, design: .monospaced) : .body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(entry.status == .pendingRemoval)
                if entry.label != nil {
                    Text(entry.ageRecipient)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                RecipientRowContent.note(entry.note)
            }

            RecipientKindBadge(kind: entry.kind)

            Spacer()

            if let badge {
                Text(badge.0).font(.caption2).foregroundStyle(badge.1)
            }

            RecipientNamingButton(hasLabel: entry.label != nil, action: onEditLabel)

            Button(action: onToggle) {
                Image(systemName: entry.status == .pendingRemoval ? "arrow.uturn.backward.circle" : "minus.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                (entry.status == .pendingRemoval
                    ? LocalizedKey.accessUndoRemoval : LocalizedKey.accessRemoveRecipient
                ).text)
        }
        .padding(.vertical, 2)
    }

    private var badge: (LocalizedKey, Color)? {
        switch entry.status {
        case .unchanged: nil
        case .pendingRemoval: (.accessPendingRemovalBadge, .red)
        case .pendingAddition: (.accessPendingAdditionBadge, .green)
        }
    }
}

/// One file's outcome. A failure shows its reason inline rather than behind a
/// disclosure: a project run's whole point is that the failures do not stop
/// it, so they have to be readable where they happened.
private struct ProjectAccessResultRow: View {
    let result: ProjectRecipientApplier.FileResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(tint).font(.caption)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if case .failed(let reason) = result.outcome {
                    // Fixed diagnostic text or the bridge's own error
                    // description — never a document value. See
                    // `ProjectRecipientApplier.FileOutcome.failed`.
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Text(label).font(.caption2).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch result.outcome {
        case .updated: "checkmark.circle.fill"
        case .unchanged: "equal.circle"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch result.outcome {
        case .updated: .green
        case .unchanged: .secondary
        case .failed: .red
        }
    }

    private var label: String {
        switch result.outcome {
        case .updated: LocalizedKey.projectAccessResultUpdated.text
        case .unchanged: LocalizedKey.projectAccessResultUnchanged.text
        case .failed: LocalizedKey.projectAccessResultFailed.text
        }
    }
}
