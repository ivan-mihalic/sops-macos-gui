import AppKit
import SopsEngine
import SopsProjects
import SwiftUI
import UniformTypeIdentifiers

/// The window's only sidebar — SOPS-39 task 6.
///
/// ## What it replaces
/// Four columns: a sections list, a project list, a file list, and the
/// editor. Three of them were navigation, and only one project's files ever
/// existed at a time. This is one tree: every added project is a row, its
/// encrypted files are its children, an Access row sits under them, and
/// About/Settings stay pinned at the bottom (PROPOSAL §4).
///
/// ## Why one selection value
/// Every row — a file, a project's Access panel, a project's own row, About,
/// Settings — is a `WorkspaceSelection`, so the whole sidebar is a single
/// `List(selection:)` and the unsaved-changes guard has exactly one binding
/// to intercept. The four-column version needed three separate guards
/// (`requestFileSwitch`, `requestProjectSwitch`, `requestSectionSwitch`) and
/// shipped without the third one for a whole milestone, which is precisely
/// the shape of defect one binding cannot have.
///
/// The binding handed in here is expected to be the *guarded* one, exactly as
/// `SectionSidebarList` before it: writing to it is what asks `AppShell` for
/// a switch, and that request is what prompts before discarding a dirty
/// document.
public struct ProjectTreeSidebar: View {
    @Bindable private var projects: ProjectSidebarModel
    private let trees: ProjectTreeStore
    private let selection: Binding<WorkspaceSelection?>
    private let onNewFile: (StoredProject.ID) -> Void
    private let onAddProjectAtPath: (String) -> Void

    @State private var pendingRemoval: StoredProject?
    @State private var isDropTargeted = false

    public init(projects: ProjectSidebarModel,
                trees: ProjectTreeStore,
                selection: Binding<WorkspaceSelection?>,
                onNewFile: @escaping (StoredProject.ID) -> Void,
                onAddProjectAtPath: @escaping (String) -> Void) {
        self.projects = projects
        self.trees = trees
        self.selection = selection
        self.onNewFile = onNewFile
        self.onAddProjectAtPath = onAddProjectAtPath
    }

    public var body: some View {
        VStack(spacing: 0) {
            // One `List`, two sections, exactly as `SectionSidebarList` had
            // it: a `List` row is full-width and selectable by construction,
            // and a trailing `SwiftUI.Section` is how macOS sidebars group
            // secondary destinations. Hand-rolled rows in a `safeAreaInset`
            // were tried and are what made the bottom rows clickable only on
            // their text (58 pt inside a 220 pt sidebar) and stopped the
            // sidebar compressing vertically — see the deleted
            // `SectionSidebarList`'s own comment, kept alive here because the
            // temptation to pin rows that way comes back every time.
            List(selection: selection) {
                if projects.groups.isEmpty {
                    // A `Section` rather than the previous full-pane empty
                    // state: About and Settings still have to be reachable
                    // on a first run, so the list cannot be replaced
                    // wholesale by a placeholder.
                    SwiftUI.Section {
                        Text(.projectsEmptyTitle)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(projects.groups) { group in
                        groupContent(group)
                    }
                }

                SwiftUI.Section {
                    Label(.sidebarSetupGuide, systemImage: "book")
                        .tag(WorkspaceSelection.setupGuide)
                    Label(.sidebarAbout, systemImage: "info.circle")
                        .tag(WorkspaceSelection.about)
                    Label(.sidebarSettings, systemImage: "gearshape")
                        .tag(WorkspaceSelection.settings)
                }
            }
            .listStyle(.sidebar)
            .scrollOverflowFade()

            Divider()
            // The whole footer row is the button, not just the words —
            // measured at `AXButton "Add Project…" 101x16` in a 220 pt
            // sidebar before `.frame(maxWidth:)` + `.contentShape` were
            // added. `ClickTargetTests.addProjectFillsTheFooter` pins it.
            Button {
                presentOpenPanel()
            } label: {
                Label(.actionAddProject, systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(isDropTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .confirmationDialog(
            LocalizedKey.projectsRemoveConfirmTitle.text,
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { isPresented in if !isPresented { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { project in
            Button(LocalizedKey.actionRemoveProject.text, role: .destructive) {
                projects.remove(project.id)
                trees.forget(project.id)
                pendingRemoval = nil
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {
                pendingRemoval = nil
            }
        } message: { _ in
            // Removal means "stop tracking", never "delete" — CLAUDE.md and
            // PROPOSAL.md both require the confirmation to say so plainly.
            Text(.projectsRemoveConfirmMessage)
        }
        .alert(
            LocalizedKey.projectsAddErrorTitle.text,
            isPresented: Binding(
                get: { projects.lastError != nil },
                set: { isPresented in if !isPresented { projects.lastError = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { projects.lastError = nil }
        } message: {
            Text(projects.lastError ?? "")
        }
    }

    // MARK: - Groups and projects

    /// A group with more than one member, or whose sole member is a worktree
    /// (main repository not itself added), gets a header naming the main
    /// repository. A lone, ordinary project renders without one — a header
    /// over a list of exactly one unrelated project just repeats the row
    /// beneath it. Carried over from the deleted `ProjectSidebar`.
    ///
    /// ⚠️ The `SwiftUI.Section` is **not** optional, and the header is the
    /// only part of it that is. Measured here: a bare `ForEach` holding a
    /// `DisclosureGroup`, sitting directly in a sidebar `List`, silently
    /// suppresses **every row after it** — the About and Settings section
    /// below simply never gets laid out, so PROPOSAL §4's pinned rows vanish
    /// from a window that has any project in it. Reproduced in isolation
    /// (`List { ForEach { DisclosureGroup } ; Section { About; Settings } }`
    /// renders no About), and wrapping the `ForEach` in a `Section` of its
    /// own is what makes them come back. `ProjectTreeSidebarTests
    /// .treeShowsFilesAndAccess` is what catches it, over a project with
    /// files — an empty sidebar renders fine and hides the whole thing.
    @ViewBuilder
    private func groupContent(_ group: ProjectGroup) -> some View {
        let isMainRepositoryItselfAMember = group.members.contains {
            $0.rootPath == group.mainRepositoryPath
        }
        SwiftUI.Section {
            ForEach(group.members) { member in
                projectNode(member, in: group)
            }
        } header: {
            if group.members.count > 1 || !isMainRepositoryItselfAMember {
                Text(Self.groupHeaderText(group))
            }
        }
    }

    static func groupHeaderText(_ group: ProjectGroup) -> String {
        if let main = group.members.first(where: { $0.rootPath == group.mainRepositoryPath }) {
            return main.displayName
        }
        return (group.mainRepositoryPath as NSString).lastPathComponent
    }

    /// One project: a disclosure row whose children are its encrypted files
    /// and its Access row.
    ///
    /// `isExpanded` is bound to `projects.selection` rather than to per-row
    /// `@State`, so exactly one project is open at a time and the open one is
    /// always the one whose contents the detail pane is describing. Collapsing
    /// clears the selection rather than remembering a second, invisible
    /// notion of "current project" that could disagree with the tree.
    @ViewBuilder
    private func projectNode(_ project: StoredProject, in group: ProjectGroup) -> some View {
        let isWorktreeMember = project.rootPath != group.mainRepositoryPath
        let isExpanded = projects.selection == project.id
        DisclosureGroup(
            isExpanded: Binding(
                get: { projects.selection == project.id },
                set: { expanded in
                    projects.selection = expanded ? project.id : nil
                })
        ) {
            fileRows(for: project)
            Label(.sidebarAccess, systemImage: "person.2")
                .help(LocalizedKey.sidebarAccessHelp.text)
                .tag(WorkspaceSelection.access(project: project.id))
        } label: {
            projectRow(project, isWorktreeMember: isWorktreeMember)
                .tag(WorkspaceSelection.projectHome(project.id))
        }
        // The scan that fills the rows above, and it runs **only for the
        // expanded project**.
        //
        // `.task` rather than a call in `body`, because a refresh is a
        // directory walk and a body may be evaluated any number of times for
        // reasons that have nothing to do with the project changing. And
        // keyed on *expansion* rather than on `project.id` alone, because
        // that version scanned every added project the moment the window
        // opened — a dozen full directory walks for rows nobody had looked
        // at, which is exactly what `ProjectTreeStore.model(for:)`'s own doc
        // comment promises does not happen.
        .task(id: isExpanded) {
            guard isExpanded else { return }
            await trees.refresh(project)
        }
    }

    private func projectRow(_ project: StoredProject, isWorktreeMember: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isWorktreeMember ? "arrow.triangle.branch" : "folder")
                .foregroundStyle(isWorktreeMember ? .secondary : .primary)

            VStack(alignment: .leading, spacing: 1) {
                Text(project.displayName)
                if isWorktreeMember {
                    Text(.projectsWorktreeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if projects.isMissing(project) {
                Text(.projectsMissingBadge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }

            newFileButton(for: project)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                onNewFile(project.id)
            } label: {
                Label(.filesNewFileButton, systemImage: "plus")
            }
            Button(role: .destructive) {
                pendingRemoval = project
            } label: {
                Label(.actionRemoveProject, systemImage: "trash")
            }
        }
    }

    /// The new-file control, per project rather than per window.
    ///
    /// ⌘N is attached only to the **selected** project's button. Attaching it
    /// to every row would register the same shortcut once per project and let
    /// SwiftUI pick which one fires — the user would press ⌘N and get a file
    /// in a project they were not looking at. With no project selected the
    /// shortcut is not registered at all, which is what makes ⌘N inert
    /// without one (`AppShell.makeNewFileModel` decides the same thing again
    /// on the other side, deliberately: see its doc comment).
    @ViewBuilder
    private func newFileButton(for project: StoredProject) -> some View {
        let button = Button {
            onNewFile(project.id)
        } label: {
            Label(.filesNewFileButton, systemImage: "plus")
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help(LocalizedKey.filesNewFileButton.text)

        if projects.selection == project.id {
            button.keyboardShortcut("n", modifiers: .command)
        } else {
            // No shortcut at all, rather than a second one on a different
            // chord: an inactive row's button is still clickable, it just
            // does not own ⌘N.
            button
        }
    }

    // MARK: - Files

    @ViewBuilder
    private func fileRows(for project: StoredProject) -> some View {
        let model = trees.model(for: project)
        let inventory = trees.inventory(for: project.id)
        ForEach(model.files) { file in
            fileRow(file, in: project, model: model, inventory: inventory)
        }
    }

    private func fileRow(_ file: ListedFile, in project: StoredProject,
                         model: FileListModel, inventory: AccessInventory?) -> some View {
        let status = inventory?.files.first { $0.url == file.url }?.status
        return HStack(spacing: 4) {
            Label(model.relativePath(for: file.url), systemImage: Self.systemImage(for: file.format))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if file.isReadOnly {
                // SOPS-38 phase F3, carried over from the deleted
                // `FileListView` row unchanged — a hint only, never "this
                // file cannot be opened". See `ListedFile.isReadOnly`.
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(LocalizedKey.filesReadOnlyBadge.text)
                    .help(LocalizedKey.filesReadOnlyBadge.text)
            }
            statusDot(status)
        }
        .tag(WorkspaceSelection.file(project: project.id, url: file.url))
    }

    /// The per-file drift indicator: green in sync, orange re-wrap needed,
    /// grey ungoverned, nothing at all before the project has been scanned.
    ///
    /// Both non-green states carry their sentence as an accessibility label
    /// *and* as a tooltip, because colour alone is never a message here —
    /// `ColourIndependenceTests` states the rule and Apple's guidance says
    /// the same. In-sync is deliberately silent: it is the ordinary state,
    /// and a tooltip on every row of a long list is noise.
    @ViewBuilder
    private func statusDot(_ status: AccessInventory.FileStatus?) -> some View {
        switch status {
        case .none:
            EmptyView()
        case .inSync:
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
        case .ruleDiffers:
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
                .accessibilityLabel(LocalizedKey.sidebarFileNeedsRewrap.text)
                .help(LocalizedKey.sidebarFileNeedsRewrap.text)
        case .ungoverned:
            Circle()
                .fill(.secondary)
                .frame(width: 6, height: 6)
                .accessibilityLabel(LocalizedKey.sidebarFileUngoverned.text)
                .help(LocalizedKey.sidebarFileUngoverned.text)
        }
    }

    /// A glyph per document shape. Total over `SopsFileFormat` on purpose —
    /// a `default` here would silently give a future format the YAML icon.
    static func systemImage(for format: SopsFileFormat) -> String {
        switch format {
        case .yaml: "doc.text"
        case .json: "curlybraces"
        case .ini: "list.bullet.rectangle"
        case .dotenv: "terminal"
        }
    }

    // MARK: - Adding projects

    private func presentOpenPanel() {
        let panel = ProjectOpenPanel.make()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        projects.addProject(path: url.path)
    }

    /// Drag-and-drop of one or more folders. Every provider is resolved
    /// first and the model told once — calling into the model from each
    /// provider's own completion handler let a good folder finishing last
    /// wipe an unreadable one's error, which is exactly the silence that
    /// branch exists to end.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let fileURLProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileURLProviders.isEmpty else { return false }

        Task { @MainActor in
            var paths: [String] = []
            var unreadable = 0
            for provider in fileURLProviders {
                if let path = await Self.path(from: provider) {
                    paths.append(path)
                } else {
                    unreadable += 1
                }
            }
            projects.addDroppedProjects(paths: paths, unreadableCount: unreadable)
        }
        return true
    }

    private static func path(from provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                continuation.resume(returning: droppedProjectPath(from: item))
            }
        }
    }
}
