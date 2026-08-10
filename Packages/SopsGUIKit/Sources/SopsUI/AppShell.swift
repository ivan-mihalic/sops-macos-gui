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
    private static let scrollingSections: [Section] =
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
                onUpdateConsentChanged: @escaping @MainActor () -> Void = {}) {
        self.projects = projects
        self.keyStore = keyStore
        self.unsavedChanges = unsavedChanges
        self.health = health
        self.onUpdateConsentChanged = onUpdateConsentChanged
    }

    public var body: some View {
        NavigationSplitView {
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
                // `SwiftUI.Section`, qualified: inside `AppShell` the bare
                // name is this type's own `Section` enum.
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
        } detail: {
            switch selection {
            case .projects:
                ProjectWorkspaceView(projects: projects, keyStore: keyStore, unsavedChanges: unsavedChanges)
            case .about:
                AboutView()
            case .settings:
                SettingsPaneView(health: health, keyStore: keyStore,
                                 onUpdateConsentChanged: onUpdateConsentChanged)
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
        HSplitView {
            ProjectSidebar(model: projects)
                .frame(minWidth: 180, idealWidth: 220, maxHeight: .infinity)
                // Everything that can leave the open document is unavailable
                // while that document is being written, for the same reason
                // `SecretEditorView` already disables its own rows and
                // toolbar: a save is not interruptible, so a control that
                // looks live but cannot be honoured until the save lands
                // should not look live. `requestProjectSwitch`/
                // `requestFileSwitch` still handle the case, because a click
                // can land in the instant before the disable takes effect and
                // a correctness property may not rest on a `.disabled`.
                .disabled(openDocumentIsSaving)
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

    @ViewBuilder
    private var fileListPane: some View {
        if let fileListModel {
            FileListView(
                model: fileListModel,
                selection: Binding(
                    get: { selectedFileURL },
                    set: { requestFileSwitch(to: $0) })
            )
        } else {
            centeredPlaceholder(.filesNoProjectSelected)
        }
    }

    @ViewBuilder
    private var editorPane: some View {
        if let documentViewModel, let selectedFileURL {
            SecretEditorView(
                viewModel: documentViewModel,
                fileName: selectedFileURL.lastPathComponent,
                unsavedChanges: unsavedChanges)
        } else {
            centeredPlaceholder(.editorNoFileSelected)
        }
    }

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
            fileListModel = FileListModel(projectRoot: URL(fileURLWithPath: project.rootPath))
        } else {
            fileListModel = nil
        }
    }

    private func activateFile(_ url: URL?) {
        selectedFileURL = url
        if let url {
            let vm = SecretDocumentViewModel(fileURL: url, keyStore: keyStore)
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
