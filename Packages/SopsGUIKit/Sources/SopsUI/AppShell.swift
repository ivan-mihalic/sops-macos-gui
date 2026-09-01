import SopsEngine
import SopsProjects
import SwiftUI

public struct AppShell: View {
    public enum Section: String, CaseIterable, Hashable, Sendable {
        case projects, about, settings

        /// PROPOSAL.md §4: About and Settings sit at the bottom of the sidebar.
        /// `body` reads this directly to decide which rows scroll at the top
        /// versus which are pinned in the bottom inset — it is not just
        /// documentation, it drives the actual layout.
        public static let pinnedToBottom: [Section] = [.about, .settings]

        fileprivate var labelKey: LocalizedKey {
            switch self {
            case .projects: .sidebarProjects
            case .about: .sidebarAbout
            case .settings: .sidebarSettings
            }
        }

        fileprivate var systemImage: String {
            switch self {
            case .projects: "folder"
            case .about: "info.circle"
            case .settings: "gearshape"
            }
        }
    }

    /// Everything not pinned to the bottom, in declaration order. Derived from
    /// `pinnedToBottom` so there is one source of truth for the split.
    fileprivate static let scrollingSections: [Section] =
        Section.allCases.filter { !Section.pinnedToBottom.contains($0) }

    @State private var selection: Section = .projects
    /// A section the user asked for while the open document was dirty. Held
    /// here until the prompt resolves — see `guardedSelection`.
    @State private var pendingSection: Section?
    @State private var sectionSaveErrorMessage: String?
    private let projects: ProjectSidebarModel
    private let keyStore: SessionKeyStore
    private let unsavedChanges: UnsavedChangesTracker
    /// The same report the wizard and ⌘, show — one instance, because the
    /// Settings row now renders the Health pane in place and two view models
    /// would give the sidebar and ⌘, different answers about the same machine.
    private let health: HealthViewModel
    private let onUpdateConsentChanged: @MainActor () -> Void
    /// Passed straight through to `AboutView`. `nil` in every test and
    /// snapshot, because Sparkle is not a dependency of this package.
    private let onCheckForUpdates: (@MainActor () -> Void)?
    /// How the menu bar asks for a section — ⌘, and About are menu items, not
    /// separate scenes, and this is the only way they can move the sidebar.
    /// `nil` in tests and snapshots, which have no menu bar. See
    /// `SectionRouter` for why a request rather than a binding.
    private let router: SectionRouter?

    /// None of the three have defaults: the caller (`SopsGUIApp`) owns the
    /// single `ProjectStore`/`SessionKeyStore` instances the health check is
    /// also wired to (see `HealthViewModel.init(reportBuilder:)`), and a
    /// hidden default here would make it too easy to accidentally construct
    /// a second, unrelated store — which would desync the sidebar (or the
    /// editor's decryption identity) from what the health report sees,
    /// silently. `unsavedChanges` is shared the same way, with the app's own
    /// quit command as its other reader — see `UnsavedChangesTracker`'s doc
    /// comment.
    public init(projects: ProjectSidebarModel,
                keyStore: SessionKeyStore,
                unsavedChanges: UnsavedChangesTracker,
                health: HealthViewModel,
                onUpdateConsentChanged: @escaping @MainActor () -> Void = {},
                onCheckForUpdates: (@MainActor () -> Void)? = nil,
                router: SectionRouter? = nil) {
        self.projects = projects
        self.keyStore = keyStore
        self.unsavedChanges = unsavedChanges
        self.health = health
        self.onUpdateConsentChanged = onUpdateConsentChanged
        self.onCheckForUpdates = onCheckForUpdates
        self.router = router
    }

    public var body: some View {
        // Two shapes, and the switch between them is the point.
        //
        // Projects is a three-column app: sections, the project list, then the
        // files and the open document. About and Settings are single pages
        // with nothing to list beside them — a column of projects next to the
        // About page is a list the user cannot act on without leaving the page
        // they came to read.
        //
        // Returning `EmptyView()` from `content:` was tried and does not do
        // this: `NavigationSplitView` keeps the column and draws it blank.
        // Measured on the running app — a 408 pt empty stripe between the
        // sidebar and the About page. The column has to not be declared at
        // all, which is why this is two `NavigationSplitView`s rather than one
        // with a conditional middle.
        //
        // Leaving Projects already destroys `ProjectWorkspaceView`, and is
        // already guarded by `requestSectionSwitch` (see `guardedSelection`),
        // so rebuilding the split view on that same transition adds no new way
        // to lose an open document.
        Group {
            if selection == .projects {
                NavigationSplitView {
                    sectionSidebar
                } content: {
                    ProjectSidebar(model: projects)
                        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
                        // Same reason as the sidebar: a save is not
                        // interruptible, so a control that cannot be honoured
                        // until it lands should not look live.
                        .disabled(unsavedChanges.isSaving)
                } detail: {
                    ProjectWorkspaceView(projects: projects, keyStore: keyStore,
                                         unsavedChanges: unsavedChanges)
                }
            } else {
                NavigationSplitView {
                    sectionSidebar
                } detail: {
                    singlePage
                }
            }
        }
        // The window's minimum size, stated once, here.
        //
        // `.windowResizability(.contentMinSize)` reads the minimum off this
        // view, so without a minimum of its own the window inherited whatever
        // the *current* pane happened to demand. Measured with
        // `Scripts/ui-probe.swift`: 1138x189 on Projects, 352x1353 on About,
        // 270x179 on Settings — the window's limits changed under the user
        // every time they clicked a sidebar row, which is the "some screens
        // resize and some don't" in the report.
        //
        // `maxWidth`/`maxHeight` `.infinity` so the panes grow into a window
        // the user enlarges rather than leaving the extra space blank.

    }


    /// The window's sidebar. One `List`, shared by both shapes above, so the
    /// sections and the guard on them cannot differ between them.
    @ViewBuilder
    private var sectionSidebar: some View {
            SectionSidebarList(guardedSelection: guardedSelection)
            .disabled(unsavedChanges.isSaving)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .confirmationDialog(
                LocalizedKey.editorUnsavedChangesTitle.text,
                isPresented: Binding(
                    get: { pendingSection != nil },
                    set: { isPresented in if !isPresented { pendingSection = nil } }),
                presenting: pendingSection
            ) { section in
                Button(LocalizedKey.editorSaveAndContinue.text) {
                    Task { await saveThenLeaveProjects(to: section) }
                }
                Button(LocalizedKey.editorDiscardChanges.text, role: .destructive) {
                    pendingSection = nil
                    selection = section
                }
                Button(LocalizedKey.actionCancel.text, role: .cancel) {
                    pendingSection = nil
                }
            } message: { _ in
                Text(.editorUnsavedChangesMessage)
            }
            .alert(
                LocalizedKey.editorSaveErrorTitle.text,
                isPresented: Binding(
                    get: { sectionSaveErrorMessage != nil },
                    set: { isPresented in if !isPresented { sectionSaveErrorMessage = nil } })
            ) {
                Button(LocalizedKey.actionDone.text) { sectionSaveErrorMessage = nil }
            } message: {
                Text(sectionSaveErrorMessage ?? "")
            }
            // A menu item asked for a section. It goes through
            // `requestSectionSwitch` — the same call the sidebar's own
            // binding makes — so ⌘, cannot leave a dirty document without
            // the prompt a click would have raised. Cleared immediately, so
            // asking for the section you are already on still works the next
            // time rather than being swallowed as "no change".
            .onChange(of: router?.requested) { _, requested in
                guard let requested else { return }
                requestSectionSwitch(to: requested)
                router?.clear()
            }
    }

    /// About and Settings: one page, no middle column.
    @ViewBuilder
    private var singlePage: some View {
            switch selection {
            case .projects:
                // Unreachable: `body` only builds this branch for the other
                // two sections. Spelled out rather than absorbed by a
                // `default`, because a silent catch-all here is exactly how
                // the About row came to render nothing at all in 0.1.1.
                EmptyView()
            case .about:
                // In a `ScrollView`, and that is load-bearing rather than
                // decorative. Placed directly in the detail column, `AboutView`
                // pinned the *window's* minimum height at 1382 pt — selecting
                // the About row grew the window and it could not be made
                // shorter again, at any width. Measured on the running app;
                // substituting a plain `Text` let the same window shrink to
                // 700 immediately, and `AboutView`'s own `fittingSize` is
                // 358 pt, so nothing about the view in isolation predicts it.
                //
                // A `ScrollView` proposes no minimum height of its own, so the
                // window is free again — and a page that might not fit should
                // scroll anyway, which is what a user with larger text or a
                // short window needs from it.
                ScrollView {
                    AboutView(checkForUpdates: onCheckForUpdates,
                              onUpdateConsentChanged: onUpdateConsentChanged)
                }
            case .settings:
                SettingsPaneView(health: health, keyStore: keyStore,
                                 onUpdateConsentChanged: onUpdateConsentChanged)
            }
    }

    // MARK: - Leaving Projects is leaving the open document

    /// Every write to the outer sidebar's selection, routed through the same
    /// `WorkspaceSwitchDecision` the file and project switches use.
    ///
    /// ## Why this exists
    /// Selecting About or Settings takes `.projects` out of the `detail:`
    /// switch, which destroys `ProjectWorkspaceView` and with it the `@State`
    /// holding the open document — SwiftUI structural identity, no warning,
    /// no prompt. Until this binding existed, that was a third exit from a
    /// dirty document, and the only unguarded one: the file list and the
    /// project sidebar were both routed through `requestFileSwitch` /
    /// `requestProjectSwitch`, and the doc comment on `ProjectWorkspaceView`
    /// claimed project-switch had been guarded *"rather than being left as a
    /// narrower hole in the one property this milestone says must not break"*
    /// — while this wider one sat one view up.
    ///
    /// Worse than losing the edits on its own: `ProjectWorkspaceView`'s
    /// `SecretEditorView`'s `onDisappear` calls `unsavedChanges.clear()` as the
    /// editor is torn down with it, so the same click also
    /// disarmed ⌘Q. The user lost the document *and* the warning that would
    /// have mentioned it.
    ///
    /// ## Why the tracker rather than the view model
    /// `documentViewModel` lives inside `ProjectWorkspaceView` and is
    /// deliberately not reachable from here. `UnsavedChangesTracker` is the
    /// existing channel for exactly this question — the quit path already had
    /// to ask it from outside the view for the same reason — so this reads the
    /// same two flags ⌘Q does, rather than inventing a second notion of dirty.
    private var guardedSelection: Binding<Section> {
        Self.makeGuardedSelection(
            current: { selection },
            request: { requested in requestSectionSwitch(to: requested) })
    }

    /// The binding itself, built from two closures so a test can drive it.
    ///
    /// This exists because the source-text tests kept losing. Round one
    /// checked that something *named* `guardedSelection` reached the two
    /// controls — a review gutted the setter and left 583 tests green. Round
    /// two checked the setter's text — a review moved the matched literal into
    /// a `//` comment above the gutted code. Round three stripped `//`
    /// comments — a review used `/* */`. Each fix answered the last attack and
    /// invited the next, because none of them observed behaviour.
    ///
    /// So: a free function returning the `Binding`, which a test can actually
    /// write to. `AppShell`'s own property is now two lines with nothing to
    /// get wrong, and the property that matters — a write goes through
    /// `request`, never straight to `selection` — is checked by running it.
    static func makeGuardedSelection(
        current: @escaping () -> Section,
        request: @escaping (Section) -> Void
    ) -> Binding<Section> {
        Binding(get: current, set: request)
    }

    /// The question `guardedSelection` asks, as a pure function so a test can
    /// ask it too.
    ///
    /// Internal rather than private for that reason alone. It delegates
    /// straight to `WorkspaceSwitchDecision.forSwitch` and adds nothing — the
    /// point is that leaving Projects is a document switch, decided by the
    /// same rule as the other two, not that it needs a rule of its own.
    ///
    /// **What a test of this does not establish:** that `guardedSelection`
    /// actually consults it. That binding is the only writer of `selection`,
    /// which is verified by reading, in the same way and for the same reason
    /// as the three `.confirmationDialog` buttons.
    static func sectionSwitchDecision(
        from current: Section, to requested: Section,
        documentIsDirty: Bool, saveIsInFlight: Bool
    ) -> WorkspaceSwitchDecision {
        WorkspaceSwitchDecision.forSwitch(
            from: current, to: requested,
            documentIsDirty: documentIsDirty, saveIsInFlight: saveIsInFlight)
    }

    /// This view's two pieces of switch state, so the transition below can be a
    /// pure function.
    ///
    /// Extracted because the decision was computed correctly and **connected to
    /// nothing observable**: changing the `.askAboutUnsavedChanges` line from
    /// `pendingSection = requested` to `selection = requested` passed all 685
    /// tests. That change is silent data loss — a user with unsaved secret
    /// edits clicks About or Settings, no sheet appears, the editor is torn
    /// down, the edits are gone, which is the entire reason this guard exists.
    /// `OuterSidebarSwitchTests` covered the pure decision,
    /// `OuterSidebarWiringTests` covered the source text, and nothing read
    /// `pendingSection`.
    struct SectionSwitchState: Equatable {
        var selection: Section
        var pendingSection: Section?
    }

    /// The state a decision produces. Total and pure, so every branch is
    /// asserted in `SectionSwitchEffectTests` — including the one that must
    /// never move `selection`.
    static func applying(_ decision: WorkspaceSwitchDecision,
                         requested: Section,
                         to state: SectionSwitchState) -> SectionSwitchState {
        var next = state
        switch decision {
        case .alreadyThere:
            break
        case .proceed:
            next.selection = requested
        case .askAboutUnsavedChanges:
            // Deliberately only `pendingSection`. Moving `selection` here is
            // the data loss described above.
            next.pendingSection = requested
        case .waitForSaveInFlight:
            // Nothing yet — the caller re-asks once the save lands.
            break
        }
        return next
    }

    private func requestSectionSwitch(to requested: Section) {
        let decision = Self.sectionSwitchDecision(
            from: selection, to: requested,
            documentIsDirty: unsavedChanges.isDirty,
            saveIsInFlight: unsavedChanges.isSaving)

        let next = Self.applying(
            decision, requested: requested,
            to: SectionSwitchState(selection: selection, pendingSection: pendingSection))
        selection = next.selection
        pendingSection = next.pendingSection

        switch decision {
        case .alreadyThere, .proceed, .askAboutUnsavedChanges:
            return
        case .waitForSaveInFlight:
            // Unreachable in practice — the sidebar is `.disabled` while a
            // save is in flight — but decided rather than assumed, because
            // "the control is disabled" is a claim about the view and this is
            // a claim about the document. Re-asks once the save lands, the
            // same 133–380 ms wait the other two switches take.
            Task { @MainActor in
                await unsavedChanges.awaitSaveInFlight()
                requestSectionSwitch(to: requested)
            }
        }
    }

    private func saveThenLeaveProjects(to section: Section) async {
        pendingSection = nil
        switch await unsavedChanges.save() {
        case .saved, nil:
            // `nil` is "nothing was registered to save" — not a failure, and
            // by then there is nothing left to lose by leaving.
            selection = section
        case .failed(let message):
            // Stay on Projects. Leaving after a failed save would discard the
            // edits the save was meant to preserve, which is the outcome the
            // prompt existed to prevent.
            sectionSaveErrorMessage = message
        }
    }

    // MARK: - Task 7: reaching the new-file wizard

    /// The model a "New File" request would use right now, or `nil` when
    /// there is no project to create one in. The toolbar "+" and ⌘N (both
    /// live in `FileListView`, wired through `ProjectWorkspaceView
    /// .requestNewFile()`) call this rather than constructing
    /// `NewSecretFileModel` directly, so there is exactly one place that
    /// decides whether a project is selected — the same reason
    /// `sectionSwitchDecision`/`applying` exist as free functions rather
    /// than inline logic.
    ///
    /// A `nil` project root is not a hypothetical this needs to guess about:
    /// `FileListView`, and therefore its toolbar row, is never on screen
    /// without one (`ProjectWorkspaceView.fileListPane`'s `else` branch shows
    /// `.filesNoProjectSelected` instead) — so in practice this always
    /// returns a model when it is actually reachable. It is still a real
    /// `nil` case, tested directly, rather than an assumption folded into
    /// the caller: a pure function that admits "no project" is a case a test
    /// can drive without rendering a window, the same way `sectionSwitchDecision`
    /// is checked without one.
    static func makeNewFileModel(projectRoot: URL?, keyStore: SessionKeyStore) -> NewSecretFileModel? {
        guard let projectRoot else { return nil }
        return NewSecretFileModel(projectRoot: projectRoot, keyStore: keyStore)
    }
}

/// Everything shown once "Projects" is selected: the project list (Task 5's
/// `ProjectSidebar`, unchanged), the encrypted-file list for whichever
/// project is selected, and the editor for whichever file is selected —
/// plus the one piece of state that spans all three: whether leaving the
/// currently open file (by picking another file, another project, or
/// quitting the app) needs to ask first.
///
/// ## Why file-switch and project-switch are both guarded, not just file-switch
/// Task 9's brief calls out "switching files" by name. Switching *projects*
/// while a file is dirty reaches the exact same failure — the open document
/// is abandoned, silently, the instant `fileListModel` is torn down for the
/// new project — so it gets the identical prompt here rather than being left
/// as a narrower hole in the one property this milestone says must not
/// break.
///
/// ## Where the decision actually lives
/// Not here. `requestFileSwitch`/`requestProjectSwitch` below only *act* on
/// `WorkspaceSwitchDecision.forSwitch(from:to:documentIsDirty:)`; the
/// judgement is that pure function's, so it can be tested without a window.
/// This type being `private`, and the prompt being a `.confirmationDialog`,
/// is exactly why the decision was untestable before — see that type's doc
/// comment.
///
/// ## How the guard works without fighting SwiftUI's selection bindings
/// `FileListView`'s `selection` binding is owned by this type
/// (`requestFileSwitch(to:)` intercepts every write), so refusing to commit
/// a pending switch is enough on its own — the `List` re-reads the
/// (unchanged) binding on its next render and the row selection visually
/// reverts. `ProjectSidebarModel.selection` is not a binding this type
/// controls (`ProjectSidebar` owns that write directly, per Task 5), so a
/// refused project switch is reverted explicitly, in `cancelPendingSwitch()`.
private struct ProjectWorkspaceView: View {
    @Bindable var projects: ProjectSidebarModel
    let keyStore: SessionKeyStore
    let unsavedChanges: UnsavedChangesTracker

    private enum PendingSwitch: Equatable {
        case file(URL?)
        case project(StoredProject.ID?)
    }

    @State private var activeProjectID: StoredProject.ID?
    @State private var fileListModel: FileListModel?
    @State private var selectedFileURL: URL?
    @State private var documentViewModel: SecretDocumentViewModel?
    @State private var pendingSwitch: PendingSwitch?
    @State private var switchSaveErrorMessage: String?
    @State private var projectAccessRequest: ProjectAccessRequest?
    @State private var newFileRequest: NewFileRequest?

    init(projects: ProjectSidebarModel, keyStore: SessionKeyStore, unsavedChanges: UnsavedChangesTracker) {
        self.projects = projects
        self.keyStore = keyStore
        self.unsavedChanges = unsavedChanges
    }

    var body: some View {
        // One `HSplitView`, not a second `NavigationSplitView`.
        //
        // This used to be `NavigationSplitView { ProjectSidebar } detail: {
        // HSplitView { files; editor } }`, nested inside `AppShell`'s own
        // `NavigationSplitView`. Measured on the running app with
        // `Scripts/ui-probe.swift`, that produced a window whose **minimum
        // width was 2177 pt** — it could not be narrowed at all — and an
        // accessibility tree with two elements both called "Sidebar" and two
        // sidebar-toggle buttons, one of which did nothing visible.
        //
        // `NavigationSplitView` is a top-level container: it owns the window's
        // sidebar column, its toggle and its collapse behaviour. Nesting one
        // inside another's detail column gives you two of each and adds their
        // minimum widths together. Apple's own three-pane apps use a single
        // split view with three columns, which is what this is now — the
        // outer one supplies the sidebar, and these three panes sit in its
        // detail.
        // Two panes, not three: the project list lives in the window's
        // `content:` column now (see `AppShell.body`). What stays here is the
        // pair that belongs together — the selected project's files and the
        // document being edited — along with the guards that protect the open
        // document, which did not move and did not change.
        HSplitView {
            fileListPane
                .frame(minWidth: 180, idealWidth: 240, maxHeight: .infinity)
                .disabled(openDocumentIsSaving)
            editorPane
                .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: projects.selection, initial: true) { _, newValue in
            requestProjectSwitch(to: newValue)
        }
        .confirmationDialog(
            LocalizedKey.editorUnsavedChangesTitle.text,
            isPresented: Binding(
                get: { pendingSwitch != nil },
                set: { isPresented in if !isPresented { cancelPendingSwitch() } }),
            presenting: pendingSwitch
        ) { pending in
            Button(LocalizedKey.editorSaveAndContinue.text) {
                Task { await saveAndCommit(pending) }
            }
            Button(LocalizedKey.editorDiscardChanges.text, role: .destructive) {
                commit(pending)
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {
                cancelPendingSwitch()
            }
        } message: { _ in
            Text(.editorUnsavedChangesMessage)
        }
        .alert(
            LocalizedKey.editorSaveErrorTitle.text,
            isPresented: Binding(
                get: { switchSaveErrorMessage != nil },
                set: { isPresented in if !isPresented { switchSaveErrorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { switchSaveErrorMessage = nil }
        } message: {
            Text(switchSaveErrorMessage ?? "")
        }
    }

    /// The Project Access sheet's subject: a fresh model built at the moment
    /// the button is pressed, so it always starts from what the project's
    /// `.sops.yaml` and files say right now. Same shape, and the same reason,
    /// as `SecretEditorView.AccessRequest`.
    private struct ProjectAccessRequest: Identifiable {
        let id = UUID()
        let model: ProjectAccessModel
    }

    /// The new-file wizard's subject: a fresh `NewSecretFileModel`, built the
    /// moment the toolbar "+" or ⌘N fires. Same shape, and the same reason,
    /// as `ProjectAccessRequest` right above — a model built once and reused
    /// across sheet presentations could describe a `.sops.yaml`/key-store
    /// state that no longer holds by the second time it is opened.
    private struct NewFileRequest: Identifiable {
        let id = UUID()
        let model: NewSecretFileModel
    }

    @ViewBuilder
    private var fileListPane: some View {
        if let fileListModel {
            VStack(spacing: 0) {
                FileListView(
                    model: fileListModel,
                    selection: Binding(
                        get: { selectedFileURL },
                        set: { requestFileSwitch(to: $0) }),
                    onNewFile: { requestNewFile() },
                    // Ticket #25 claim 2. `ProjectSidebarModel.addProject`
                    // already owns error handling and selection for exactly
                    // this action — the sidebar's own drag-and-drop add uses
                    // it too — so this is the same call, reached from a
                    // second place rather than a second implementation of it.
                    onAddProjectAtPath: { path in projects.addProject(path: path) }
                )
                projectAccessBar(projectRoot: fileListModel.projectRoot)
            }
            .sheet(item: $projectAccessRequest) { request in
                ProjectAccessView(
                    model: request.model,
                    onClose: { projectAccessRequest = nil },
                    onFilesApplied: {
                        // A project apply may have re-wrapped the very file
                        // the editor has open: its bytes moved, so the
                        // document view model's save-time fingerprint is
                        // stale and the next Save would refuse it as changed
                        // on disk. Reloading resyncs it — the same resync
                        // `SecretEditorView` performs after the single-file
                        // panel applies. Safe to do unconditionally because
                        // the button that opened this sheet is gated on a
                        // clean document, so there is nothing to discard.
                        Task { await documentViewModel?.load() }
                        Task { await fileListModel.refresh() }
                    })
            }
            .sheet(item: $newFileRequest) { request in
                NewSecretFileSheet(
                    model: request.model,
                    onCreated: { created in
                        // Opening the file this wizard just created is a file
                        // switch like any other — `requestFileSwitch(to:)` is
                        // the one path that ever writes `selectedFileURL`
                        // (see this type's own doc comment, "How the guard
                        // works without fighting SwiftUI's selection
                        // bindings"), precisely because the *currently* open
                        // document may be dirty even though the file that
                        // was just created obviously is not. Committing the
                        // switch unconditionally here would be correct about
                        // the new file and silently discard unsaved edits in
                        // the old one — the exact hole this type exists to
                        // close for the file list and the project sidebar.
                        //
                        // The list is refreshed first so the new file is
                        // already in `fileListModel.files` by the time the
                        // switch selects it — `List(selection:)` cannot
                        // highlight a row that is not there yet.
                        Task {
                            await fileListModel.refresh()
                            requestFileSwitch(to: created)
                        }
                    })
            }
        } else {
            centeredPlaceholder(.filesNoProjectSelected)
        }
    }

    /// Builds the wizard's model through `AppShell.makeNewFileModel(
    /// projectRoot:keyStore:)` and presents it — or does nothing at all when
    /// there is no project, which is what makes ⌘N and the toolbar "+"
    /// "inactive" without one. In practice this guard is never the reason
    /// nothing happens: `fileListPane` never wires `onNewFile` (and
    /// therefore ⌘N) without a `fileListModel` to read a `projectRoot` from
    /// in the first place. It is kept anyway, rather than force-unwrapping,
    /// for the same reason `activateFile`/`requestFileSwitch` handle `nil`
    /// targets instead of assuming a caller never passes one.
    private func requestNewFile() {
        guard let model = AppShell.makeNewFileModel(
            projectRoot: fileListModel?.projectRoot, keyStore: keyStore)
        else { return }
        newFileRequest = NewFileRequest(model: model)
    }

    private func projectAccessBar(projectRoot: URL) -> some View {
        let canOpen = ProjectAccessGate.canOpen(
            hasProject: true, documentIsDirty: openDocumentIsDirty,
            documentIsSaving: openDocumentIsSaving)
        return VStack(spacing: 0) {
            Divider()
            Button {
                projectAccessRequest = ProjectAccessRequest(
                    model: ProjectAccessModel(projectRoot: projectRoot, keyStore: keyStore))
            } label: {
                Label(.projectAccessButton, systemImage: "person.2.badge.key")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!canOpen)
            .help(canOpen
                ? LocalizedKey.projectAccessButton.text
                : LocalizedKey.projectAccessDisabledUnsavedChanges.text)
            .padding(8)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let documentViewModel, let selectedFileURL {
            SecretEditorView(
                viewModel: documentViewModel,
                fileName: selectedFileURL.lastPathComponent,
                unsavedChanges: unsavedChanges,
                recipientAccess: SecretEditorView.RecipientAccessContext(
                    fileURL: selectedFileURL, keyStore: keyStore,
                    projectURL: recipientRegistryProjectRoot,
                    format: documentViewModel.format))
        } else {
            centeredPlaceholder(.editorNoFileSelected)
        }
    }

    /// The project root both Access panels read their recipient registry from.
    ///
    /// One source, deliberately. This used to be two: the per-file panel
    /// re-derived the root by looking `activeProjectID` up in
    /// `projects.groups`, while the project-wide panel took
    /// `fileListModel.projectRoot`. They answer differently whenever the lookup
    /// comes back empty — the project dropped out of the sidebar, or the store
    /// has not settled after a change — and the visible result was the same
    /// project showing recipients *with* labels in one panel and *without* them
    /// in the other, at the same moment. The file list model is the surviving
    /// source because it is the one already deciding which project's files are
    /// on screen: if a panel can be opened at all, this is the project it is
    /// about.
    private var recipientRegistryProjectRoot: URL? { fileListModel?.projectRoot }

    private func centeredPlaceholder(_ key: LocalizedKey) -> some View {
        Text(key)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Requesting a switch

    /// Whether leaving the open document right now needs to ask first. Read
    /// straight off the model — see `WorkspaceSwitchDecision`'s doc comment
    /// for why this is the whole of "dirty" (values, additions and removals),
    /// not just edited values.
    private var openDocumentIsDirty: Bool { documentViewModel?.isDirty == true }

    /// The other half of the question, and the half that used to be missing.
    /// See `WorkspaceSwitchDecision`'s "Why a save in flight is its own
    /// answer" for what a prompt put inside this window did to the file.
    private var openDocumentIsSaving: Bool { documentViewModel?.isSaving == true }

    private func requestProjectSwitch(to id: StoredProject.ID?) {
        switch WorkspaceSwitchDecision.forSwitch(
            from: activeProjectID, to: id,
            documentIsDirty: openDocumentIsDirty, saveIsInFlight: openDocumentIsSaving)
        {
        case .alreadyThere: return
        case .proceed: activateProject(id)
        case .askAboutUnsavedChanges: pendingSwitch = .project(id)
        case .waitForSaveInFlight:
            // The click is kept, not dropped: `projects.selection` already
            // holds `id` (ProjectSidebar writes it directly), so leaving it
            // alone and re-deciding when the save lands is both the honest
            // thing on screen and the one that does not lose the gesture.
            retryWhenSaveLands { requestProjectSwitch(to: id) }
        }
    }

    private func requestFileSwitch(to url: URL?) {
        switch WorkspaceSwitchDecision.forSwitch(
            from: selectedFileURL, to: url,
            documentIsDirty: openDocumentIsDirty, saveIsInFlight: openDocumentIsSaving)
        {
        case .alreadyThere: return
        case .proceed: activateFile(url)
        case .askAboutUnsavedChanges: pendingSwitch = .file(url)
        case .waitForSaveInFlight: retryWhenSaveLands { requestFileSwitch(to: url) }
        }
    }

    /// Re-asks the question once the save in flight has finished — 133–380 ms,
    /// measured — and never tears anything down in between.
    ///
    /// Terminates: `awaitSaveInFlight()` returns only when `isSaving` is back
    /// to `false`, so the re-decision cannot reach `.waitForSaveInFlight`
    /// again unless the user started *another* save in the meantime, which
    /// requires the Save button they cannot reach while the panes are
    /// disabled.
    private func retryWhenSaveLands(_ retry: @escaping @MainActor () -> Void) {
        guard let documentViewModel else {
            retry()
            return
        }
        Task { @MainActor in
            await documentViewModel.awaitSaveInFlight()
            retry()
        }
    }

    // MARK: - Resolving a pending switch

    private func cancelPendingSwitch() {
        if case .project = pendingSwitch {
            // `ProjectSidebar` already committed the click to
            // `projects.selection` directly — that write is not one this
            // type intercepted, so it is reverted explicitly here. See the
            // type's doc comment.
            projects.selection = activeProjectID
        }
        pendingSwitch = nil
    }

    private func commit(_ pending: PendingSwitch) {
        pendingSwitch = nil
        switch pending {
        case .file(let url): activateFile(url)
        case .project(let id): activateProject(id)
        }
    }

    private func saveAndCommit(_ pending: PendingSwitch) async {
        guard let documentViewModel else {
            commit(pending)
            return
        }
        let outcome = await documentViewModel.save()
        switch outcome {
        case .saved:
            commit(pending)
        case .failed(let message):
            // Left exactly where the user was — still on the dirty
            // document, with the edit intact — so a failed save here never
            // reads as "your edits are gone." See `SecretDocumentViewModel
            // .save()`'s own doc comment for the same guarantee one layer
            // down.
            pendingSwitch = nil
            if case .project = pending { projects.selection = activeProjectID }
            switchSaveErrorMessage = message
        }
    }

    // MARK: - Committing

    private func activateProject(_ id: StoredProject.ID?) {
        activeProjectID = id
        selectedFileURL = nil
        documentViewModel = nil
        unsavedChanges.clear()
        if let id, let project = projects.groups.flatMap(\.members).first(where: { $0.id == id }) {
            fileListModel = FileListModel(projectRoot: URL(fileURLWithPath: project.rootPath), keyStore: keyStore)
        } else {
            fileListModel = nil
        }
    }

    private func activateFile(_ url: URL?) {
        selectedFileURL = url
        if let url {
            // `fileListModel.files` is the one place that already knows this
            // file's format for certain — `ListedFile.format`, carried from
            // the scanner's own `SniffedFile.format` (Task 5) through
            // `FileListModel.refresh()`. Looked up rather than carried
            // alongside `selectedFileURL` itself: that binding is shared with
            // `FileListView`'s `List(selection:)`, which only ever hands back
            // a `URL` (`FileListView.swift`'s own `.tag(file.url)`), and
            // duplicating it as a second `@State` pair would be one more
            // place the two could disagree. Falling back to `.yaml` is only
            // ever reached for a file this switch did not learn about from a
            // scan — unreachable in practice (every `url` this function is
            // ever called with came from `fileListModel.files` itself, via
            // this binding or `NewSecretFileSheet`'s `onCreated`, and both
            // call sites refresh the list *before* switching — see
            // `onCreated`'s own comment above, "The list is refreshed first"
            // — so the lookup above never actually misses) — not a real
            // "guess when unsure".
            let format = fileListModel?.files.first(where: { $0.url == url })?.format ?? .yaml
            let vm = SecretDocumentViewModel(fileURL: url, format: format, keyStore: keyStore)
            documentViewModel = vm
            Task { await vm.load() }
        } else {
            documentViewModel = nil
            unsavedChanges.clear()
        }
    }
}

/// A sidebar row for a pinned section, styled to match the selection look of
/// a native `List` row so the bottom inset reads as part of the same
/// sidebar. Deliberately not a `List` row itself: a bare `Spacer()` inside a
/// `List` renders as an ordinary fixed-height row rather than flexible
/// space (that was the original bug), and a second `List` nested in the
/// `safeAreaInset` doesn't reliably self-size to its two rows even with
/// `.fixedSize(vertical: true)` — it rendered at zero height. Plain buttons
/// laid out in a `VStack` size themselves correctly at every window height.

/// The sections list, on its own.
///
/// Extracted from `AppShell` for one reason: the headless snapshot tool
/// cannot render a `NavigationSplitView`'s own `sidebar:` column — it comes
/// back blank (see this repo's CLAUDE.md, "Visual verification"). Standing
/// alone, the same `List` renders, which is what `docs/GUIDE.md` shows the
/// reader. Behaviour is unchanged: `AppShell` passes exactly the binding it
/// used to pass to `List` directly.
///
/// The property is called `guardedSelection` because that is what it must be
/// handed. Writing to it is what asks `AppShell` for a section switch, and
/// that request is what prompts before discarding an unsaved document —
/// `$selection` here would silently discard it. `OuterSidebarSwitchTests`
/// checks both halves of that sentence.
public struct SectionSidebarList: View {
    /// The same spelling `AppShell` uses, so the rows below read identically
    /// in both places — and so `OuterSidebarSwitchTests`' source-text check
    /// for `ForEach(Section.pinnedToBottom` still describes real code.
    typealias Section = AppShell.Section

    /// A stored `Binding`, not `@Binding`. The projected-value spelling
    /// (`$guardedSelection`) would read the same to the compiler and worse to
    /// a reader: what `List` must be handed here is the *guarded* binding, and
    /// naming it plainly at the use site is the point.
    /// The same array `AppShell` derives from `pinnedToBottom`, aliased so
    /// there is still exactly one source of truth for the split.
    private static let scrollingSections = AppShell.scrollingSections

    private let guardedSelection: Binding<Section>

    public init(guardedSelection: Binding<AppShell.Section>) {
        self.guardedSelection = guardedSelection
    }

    public var body: some View {
        // One `List`, two sections — not a `List` plus a `safeAreaInset`
        // holding hand-rolled `Button` rows, which is what this was.
        //
        // That arrangement was wrong twice over, both measured on the
        // running app with `Scripts/ui-probe.swift`:
        //
        // - The custom rows were clickable only where they drew:
        //   `AXButton "About" 58x16` inside a 220 pt sidebar, while the
        //   real `List` row above them took a click anywhere. A sidebar
        //   with two kinds of row, one of which mostly ignores you.
        // - The inset made the sidebar refuse to compress vertically. The
        //   split group stayed 1301 pt tall in a 612 pt window and hung
        //   off the top — "v detailu About se rozbije layout".
        //
        // A `List` row is full-width and selectable by construction, and
        // a trailing `Section` is how macOS sidebars group secondary
        // destinations. Nothing to hand-roll and nothing to pin.
        List(selection: guardedSelection) {
            // `SwiftUI.Section`, qualified: `Section` unqualified resolves
            // to `AppShell.Section` wherever that type is in scope, and
            // keeping the same spelling here as in `AppShell` means the
            // rows read identically in both places.
            SwiftUI.Section {
                ForEach(Self.scrollingSections, id: \.self) { section in
                    Label(section.labelKey, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            SwiftUI.Section {
                ForEach(Section.pinnedToBottom, id: \.self) { section in
                    Label(section.labelKey, systemImage: section.systemImage)
                        .tag(section)
                }
            }
        }
    }
}
