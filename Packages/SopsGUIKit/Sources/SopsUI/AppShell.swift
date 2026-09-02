import SopsEngine
import SopsProjects
import SwiftUI

/// The window: one sidebar, one detail pane (SOPS-39 task 6).
///
/// ## What this used to be
/// Four columns — a sections list, a project list, a file list, and the
/// editor — with three independent selections and three separate
/// unsaved-changes guards (`requestSectionSwitch`, `requestProjectSwitch`,
/// `requestFileSwitch`). The third of those shipped missing for a whole
/// milestone: selecting About took `.projects` out of the `detail:` switch,
/// destroyed the open document's `@State`, and `SecretEditorView`'s
/// `onDisappear` cleared the unsaved-changes tracker on the way out, so the
/// user lost the document *and* the ⌘Q warning that would have named it.
///
/// Now every row a user can click is one `WorkspaceSelection`, written
/// through one binding (`guardedSelection`), decided by one rule
/// (`WorkspaceSwitchGate`). A fourth exit cannot be added without going
/// through it, because there is nowhere else to write the selection.
public struct AppShell: View {

    /// What the sidebar has selected. `nil` on a first run, before anything
    /// has been chosen — the detail pane shows the no-selection placeholder.
    @State private var selection: WorkspaceSelection?
    /// A selection the user asked for while the open document was dirty.
    /// Held here until the prompt resolves — see `guardedSelection`.
    @State private var pendingSelection: WorkspaceSelection?
    @State private var saveErrorMessage: String?
    /// The last file opened in each project, remembered so the Access page
    /// can highlight the rule governing the file the user was just looking
    /// at rather than an arbitrary first one.
    @State private var lastSelectedFile: [StoredProject.ID: URL] = [:]
    @State private var newFileRequest: NewFileRequest?

    private let projects: ProjectSidebarModel
    private let trees: ProjectTreeStore
    private let keyStore: SessionKeyStore
    private let unsavedChanges: UnsavedChangesTracker
    /// The same report the wizard and ⌘, show — one instance, because the
    /// Settings row renders the Health pane in place and two view models
    /// would give the sidebar and ⌘, different answers about the same machine.
    private let health: HealthViewModel
    private let onUpdateConsentChanged: @MainActor () -> Void
    /// Passed straight through to `AboutView`. `nil` in every test and
    /// snapshot, because Sparkle is not a dependency of this package.
    private let onCheckForUpdates: (@MainActor () -> Void)?
    /// How the menu bar asks for a screen — ⌘, and About are menu items, not
    /// separate scenes, and this is the only way they can move the sidebar.
    /// `nil` in tests and snapshots, which have no menu bar.
    private let router: SectionRouter?

    /// None of the first four have defaults: the caller (`SopsGUIApp`) owns
    /// the single `ProjectStore`/`SessionKeyStore` instances the health check
    /// is also wired to, and a hidden default here would make it too easy to
    /// construct a second, unrelated store — which would desync the sidebar
    /// (or the editor's decryption identity) from what the health report
    /// sees, silently.
    public init(projects: ProjectSidebarModel,
                keyStore: SessionKeyStore,
                unsavedChanges: UnsavedChangesTracker,
                health: HealthViewModel,
                onUpdateConsentChanged: @escaping @MainActor () -> Void = {},
                onCheckForUpdates: (@MainActor () -> Void)? = nil,
                router: SectionRouter? = nil) {
        self.projects = projects
        self.keyStore = keyStore
        self.trees = ProjectTreeStore(keyStore: keyStore)
        self.unsavedChanges = unsavedChanges
        self.health = health
        self.onUpdateConsentChanged = onUpdateConsentChanged
        self.onCheckForUpdates = onCheckForUpdates
        self.router = router
    }

    public var body: some View {
        // Two columns, and no conditional shape.
        //
        // The four-column version built *two different* NavigationSplitViews
        // and switched between them, because a three-column split view keeps
        // its middle column and draws it blank for a page that has nothing to
        // list beside it (measured: a 408 pt empty stripe next to About).
        // With one sidebar there is no middle column to leave empty, so that
        // whole branch — and the document teardown that rebuilding the split
        // view caused on every About/Settings click — is gone.
        NavigationSplitView {
            ProjectTreeSidebar(
                projects: projects, trees: trees, selection: guardedSelection,
                onNewFile: { requestNewFile(in: $0) },
                // ProjectSidebarModel.addProject already owns error handling
                // and selection for exactly this action — the sidebar's own
                // drag-and-drop add uses it too — so this is the same call
                // reached from a second place rather than a second
                // implementation of it.
                onAddProjectAtPath: { path in projects.addProject(path: path) })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
                // A save is not interruptible, so a control that cannot be
                // honoured until it lands should not look live.
                .disabled(unsavedChanges.isSaving)
        } detail: {
            detail
        }
        .confirmationDialog(
            LocalizedKey.editorUnsavedChangesTitle.text,
            isPresented: Binding(
                get: { pendingSelection != nil },
                set: { isPresented in if !isPresented { pendingSelection = nil } }),
            presenting: pendingSelection
        ) { requested in
            Button(LocalizedKey.editorSaveAndContinue.text) {
                Task { await saveThenGo(to: requested) }
            }
            Button(LocalizedKey.editorDiscardChanges.text, role: .destructive) {
                pendingSelection = nil
                commit(requested)
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {
                pendingSelection = nil
            }
        } message: { _ in
            Text(.editorUnsavedChangesMessage)
        }
        .alert(
            LocalizedKey.editorSaveErrorTitle.text,
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in if !isPresented { saveErrorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
        .sheet(item: $newFileRequest) { request in
            NewSecretFileSheet(
                model: request.model,
                onCreated: { created in
                    // Opening the file this wizard just created is a
                    // selection change like any other, and goes through the
                    // same guarded path: the *currently* open document may be
                    // dirty even though the file that was just created
                    // obviously is not. Committing unconditionally here would
                    // be correct about the new file and silently discard
                    // unsaved edits in the old one.
                    //
                    // The tree is refreshed first so the new file is already
                    // in its project's rows by the time the switch selects it
                    // — List(selection:) cannot highlight a row that is not
                    // there yet.
                    Task {
                        if let project = project(for: request.projectID) {
                            await trees.refresh(project)
                        }
                        requestSwitch(to: .file(project: request.projectID, url: created))
                    }
                })
        }
        // A menu item asked for a screen. It goes through requestSwitch — the
        // same call the sidebar's own binding makes — so ⌘, cannot leave a
        // dirty document without the prompt a click would have raised.
        // Cleared immediately, so asking for the screen you are already on
        // still works the next time rather than being swallowed as "no
        // change".
        .onChange(of: router?.requested) { _, requested in
            guard let requested else { return }
            requestSwitch(to: requested)
            router?.clear()
        }
    }

    // MARK: - The detail pane

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .file(let projectID, let url):
            if let project = project(for: projectID) {
                let model = trees.model(for: project)
                let inventory = trees.inventory(for: projectID)
                FileDetailView(
                    fileURL: url, format: format(of: url, in: model),
                    projectRoot: model.projectRoot, keyStore: keyStore,
                    unsavedChanges: unsavedChanges,
                    // `nil` until the first scan of this project completes —
                    // the inspector then shows what it can and claims no
                    // format or rule it was not told. See
                    // `ProjectTreeStore.inventory(for:)`.
                    fileAccess: inventory?.files.first { $0.url == url },
                    recipientNameFor: { inventory?.name(for: $0) },
                    // Resolved here, where the rules actually live:
                    // `FileAccess` carries only an index into
                    // `AccessInventory.rules`, and the inspector has no
                    // inventory to look it up in.
                    fileRuleLabel: AppShell.ruleLabel(for: url, in: inventory))
            } else {
                centeredPlaceholder(.editorNoFileSelected)
            }

        case .access(let projectID):
            if let project = project(for: projectID) {
                // Task 8 replaces this with a full Access *page*. Until then
                // the existing panel renders inline rather than as a sheet:
                // the pane it sits in is the destination now, and a sheet
                // over a destination the user explicitly navigated to is a
                // modal with nothing behind it.
                //
                // The model comes from `ProjectTreeStore`, never from here: a
                // model constructed in this body would be replaced by a fresh,
                // unloaded one on any re-render, while the view's identity —
                // and therefore its `.task`, which is what loads it — stayed
                // put. See `ProjectTreeStore.accessModel(for:targetFile:)`.
                ProjectAccessView(
                    model: trees.accessModel(
                        for: project, targetFile: lastSelectedFile[projectID]),
                    onClose: { requestSwitch(to: .projectHome(projectID)) },
                    onFilesApplied: {
                        // A project apply may have re-wrapped files whose
                        // recipients the tree shows status dots for.
                        Task { await trees.refresh(project) }
                    })
            } else {
                centeredPlaceholder(.detailNoSelection)
            }

        case .projectHome(let projectID):
            if let project = project(for: projectID) {
                ProjectHomeView(
                    model: trees.model(for: project),
                    onNewFile: { requestNewFile(in: projectID) },
                    onAddProjectAtPath: { path in projects.addProject(path: path) })
            } else {
                centeredPlaceholder(.detailNoSelection)
            }

        case .about:
            // In a ScrollView, and that is load-bearing rather than
            // decorative. Placed directly in the detail column, AboutView
            // pinned the *window's* minimum height at 1382 pt — selecting the
            // About row grew the window and it could not be made shorter
            // again, at any width. A ScrollView proposes no minimum height of
            // its own, so the window is free.
            ScrollView { AboutView(checkForUpdates: onCheckForUpdates,
                                   onUpdateConsentChanged: onUpdateConsentChanged) }

        case .settings:
            SettingsPaneView(health: health, keyStore: keyStore,
                             onUpdateConsentChanged: onUpdateConsentChanged)

        case nil:
            centeredPlaceholder(.detailNoSelection)
        }
    }

    private func centeredPlaceholder(_ key: LocalizedKey) -> some View {
        Text(key)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func project(for id: StoredProject.ID) -> StoredProject? {
        projects.groups.flatMap(\.members).first { $0.id == id }
    }

    /// The format the scanner classified this file as. Looked up rather than
    /// re-derived from the extension: the scan is the one place that knows it
    /// for certain (`SniffedFile.format` → `ListedFile.format`), and
    /// `SecretDocumentViewModel.format`'s own doc comment is explicit that
    /// the format used to save a document must be the one used to load it.
    ///
    /// Fails loud (a `nil` the caller renders as "no file") rather than
    /// falling back to `.yaml`: a URL this shell was asked to open that its
    /// own project scan does not know about is a disagreement between the
    /// tree and the store, and quietly opening it as YAML would rewrite a
    /// dotenv/JSON/INI file in the wrong shape on save.
    private func format(of url: URL, in model: FileListModel) -> SopsFileFormat? {
        model.files.first { $0.url == url }?.format
    }

    // MARK: - Leaving a document is one question, asked in one place

    /// Every write to the sidebar's selection, routed through
    /// `WorkspaceSwitchGate`.
    ///
    /// Built from two closures so a test can drive it. That indirection is
    /// not decoration: three rounds of source-text tests for the same
    /// property were each defeated by a slightly cleverer comment (check the
    /// name → gut the setter; check the setter's text → move the literal into
    /// a `//` comment; strip `//` → use `/* */`), each leaving the whole
    /// suite green while a click discarded a dirty document. A `Binding` can
    /// be written to from a test, which closes the family.
    private var guardedSelection: Binding<WorkspaceSelection?> {
        Self.makeGuardedSelection(
            current: { selection },
            request: { requested in requestSwitch(to: requested) })
    }

    static func makeGuardedSelection(
        current: @escaping () -> WorkspaceSelection?,
        request: @escaping (WorkspaceSelection?) -> Void
    ) -> Binding<WorkspaceSelection?> {
        Binding(get: current, set: request)
    }

    private func requestSwitch(to requested: WorkspaceSelection?) {
        let decision = WorkspaceSwitchGate.decision(
            from: selection, to: requested,
            documentIsDirty: unsavedChanges.isDirty,
            saveIsInFlight: unsavedChanges.isSaving)

        let next = WorkspaceSwitchGate.applying(
            decision, requested: requested,
            to: WorkspaceSwitchState(selection: selection, pending: pendingSelection))
        selection = next.selection
        pendingSelection = next.pending

        switch decision {
        case .alreadyThere, .askAboutUnsavedChanges:
            return
        case .proceed:
            // `applying` has already moved `selection`; this records where in
            // each project the user last was, for the Access page.
            rememberLastFile(requested)
        case .waitForSaveInFlight:
            // Unreachable in practice — the sidebar is `.disabled` while a
            // save is in flight — but decided rather than assumed, because
            // "the control is disabled" is a claim about the view and this is
            // a claim about the document. Re-asks once the save lands, the
            // same 133–380 ms wait measured elsewhere.
            Task { @MainActor in
                await unsavedChanges.awaitSaveInFlight()
                requestSwitch(to: requested)
            }
        }
    }

    /// Commits a selection the user confirmed leaving the document for.
    ///
    /// `unsavedChanges.clear()` is the discard: the tracker is what ⌘Q and
    /// the sidebar both read, so leaving it set after the user chose Discard
    /// would keep warning about a document that is gone.
    private func commit(_ requested: WorkspaceSelection?) {
        selection = requested
        rememberLastFile(requested)
        unsavedChanges.clear()
    }

    private func rememberLastFile(_ requested: WorkspaceSelection?) {
        if case .file(let projectID, let url) = requested {
            lastSelectedFile[projectID] = url
        }
    }

    private func saveThenGo(to requested: WorkspaceSelection?) async {
        pendingSelection = nil
        switch await unsavedChanges.save() {
        case .saved, nil:
            // `nil` is "nothing was registered to save" — not a failure, and
            // by then there is nothing left to lose by leaving.
            selection = requested
            rememberLastFile(requested)
        case .failed(let message):
            // Stay put. Leaving after a failed save would discard the edits
            // the save was meant to preserve, which is the outcome the prompt
            // existed to prevent.
            saveErrorMessage = message
        }
    }

    // MARK: - The new-file wizard

    /// The wizard's subject: a fresh `NewSecretFileModel`, built the moment
    /// the request fires. A model built once and reused across presentations
    /// could describe a `.sops.yaml`/key-store state that no longer holds by
    /// the second time it is opened.
    private struct NewFileRequest: Identifiable {
        let id = UUID()
        let projectID: StoredProject.ID
        let model: NewSecretFileModel
    }

    private func requestNewFile(in projectID: StoredProject.ID) {
        guard let project = project(for: projectID),
              let model = Self.makeNewFileModel(
                projectRoot: URL(fileURLWithPath: project.rootPath), keyStore: keyStore)
        else { return }
        newFileRequest = NewFileRequest(projectID: projectID, model: model)
    }

    /// The model a "New File" request would use, or `nil` when there is no
    /// project to create one in. Every call site goes through this rather
    /// than constructing `NewSecretFileModel` directly, so there is exactly
    /// one place that decides whether a project is selected — and it is a
    /// pure function a test can drive without rendering a window.
    /// The `path_regex` of the rule governing `url`, or `nil` when nothing
    /// governs it, the file is not in the inventory, or there is no
    /// inventory yet. A pure function, so the index-into-`rules` lookup — and
    /// its out-of-range guard — is testable without rendering a window.
    static func ruleLabel(for url: URL, in inventory: AccessInventory?) -> String? {
        guard let inventory,
              let file = inventory.files.first(where: { $0.url == url }),
              let index = file.ruleIndex,
              inventory.rules.indices.contains(index) else { return nil }
        return inventory.rules[index].pathRegex
    }

    static func makeNewFileModel(projectRoot: URL?, keyStore: SessionKeyStore) -> NewSecretFileModel? {
        guard let projectRoot else { return nil }
        return NewSecretFileModel(projectRoot: projectRoot, keyStore: keyStore)
    }
}

/// The editor for one file, plus the state that belongs to having a document
/// open at all.
///
/// Split out of `AppShell` rather than inlined into its `detail` switch for
/// SwiftUI's own reason: `@State` is keyed to structural identity, so the
/// document view model has to live in a view whose identity changes exactly
/// when the file does. The `.task(id: fileURL)` below is what guarantees a
/// new file gets a new model rather than the previous file's.
private struct FileDetailView: View {
    let fileURL: URL
    /// `nil` when the project scan does not know this file — see
    /// `AppShell.format(of:in:)` for why that is refused rather than guessed.
    let format: SopsFileFormat?
    let projectRoot: URL
    let keyStore: SessionKeyStore
    let unsavedChanges: UnsavedChangesTracker
    /// What the project scan knows about this file, for the editor's row
    /// inspector. `nil` before the first scan completes.
    let fileAccess: AccessInventory.FileAccess?
    let recipientNameFor: (String) -> String?
    let fileRuleLabel: String?

    @State private var viewModel: SecretDocumentViewModel?

    var body: some View {
        Group {
            if let viewModel {
                SecretEditorView(
                    viewModel: viewModel,
                    fileName: fileURL.lastPathComponent,
                    unsavedChanges: unsavedChanges,
                    recipientAccess: SecretEditorView.RecipientAccessContext(
                        fileURL: fileURL, keyStore: keyStore,
                        projectURL: projectRoot,
                        format: viewModel.format),
                    fileAccess: fileAccess,
                    recipientNameFor: recipientNameFor,
                    fileRuleLabel: fileRuleLabel)
            } else {
                Text(.editorNoFileSelected)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: fileURL) {
            guard let format else {
                viewModel = nil
                return
            }
            let model = SecretDocumentViewModel(
                fileURL: fileURL, format: format, keyStore: keyStore)
            viewModel = model
            await model.load()
        }
    }
}
