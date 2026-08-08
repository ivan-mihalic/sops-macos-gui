import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SopsProjects

/// One group of projects that share a git main repository — a repository
/// and any of its linked worktrees the user has added, grouped together so
/// the sidebar doesn't list them as unrelated projects.
///
/// `mainRepositoryPath` is not necessarily the `rootPath` of any
/// `StoredProject` in `members`: a worktree can be added without its main
/// repository ever being added itself (`WorktreeResolver.kind(of:)` reports
/// the main repository's path regardless of whether anything is stored
/// there). `ProjectSidebar` uses that path as the group's header in exactly
/// that case — see its `groupHeaderText(_:)`.
public struct ProjectGroup: Identifiable, Equatable, Sendable {
    public var id: String { mainRepositoryPath }
    public let mainRepositoryPath: String
    public let members: [StoredProject]
}

/// Drives the project sidebar: groups the flat list `ProjectStore` persists
/// into `ProjectGroup`s, and turns `ProjectStore`'s throwing API into
/// something a view can call without a `do`/`catch` of its own.
@MainActor
@Observable
public final class ProjectSidebarModel {
    public private(set) var groups: [ProjectGroup] = []
    public var selection: StoredProject.ID?
    /// English text ready to show in an alert. `nil` means nothing to show.
    /// Not `private(set)`: the view that displays it is also what dismisses
    /// it (clearing it back to `nil` once the user acknowledges the alert).
    public var lastError: String?

    private let store: ProjectStore

    public init(store: ProjectStore) {
        self.store = store
        rebuildGroups()
    }

    /// Adds `path` as a project and selects it. On failure, sets `lastError`
    /// to English text a view can show directly — the view never sees
    /// `ProjectStore.Error` and never needs a `do`/`catch` of its own, which
    /// is the whole point of this method existing on top of
    /// `ProjectStore.add(path:)`: a throwing call sitting directly in a
    /// SwiftUI button action either crashes the build (SwiftUI action
    /// closures aren't `throws`) or gets silently discarded with `try?` —
    /// neither tells the user their project wasn't added.
    ///
    /// A duplicate still selects the *existing* entry — the user asked to
    /// see this project, and it's already there.
    public func addProject(path: String) {
        lastError = nil
        do {
            let project = try store.add(path: path)
            rebuildGroups()
            selection = project.id
        } catch ProjectStore.Error.alreadyAdded(let existing) {
            lastError = LocalizedKey.projectsErrorDuplicate.text
            selection = existing.id
        } catch ProjectStore.Error.notADirectory {
            lastError = LocalizedKey.projectsErrorNotDirectory.text
        } catch {
            // ProjectStore.Error.unreadable — persisting the updated list
            // failed. Not narrated more specifically: the underlying I/O
            // error names no secret and isn't actionable beyond "try again".
            lastError = LocalizedKey.projectsErrorAddFailed.text
        }
    }

    /// Forgets the project. Never touches its directory on disk — see
    /// `ProjectStore.remove(id:)`.
    ///
    /// If removal fails to persist, `selection` and `groups` are left
    /// exactly as they were — the project is still there, so clearing the
    /// selection would be showing the user a decision that didn't actually
    /// happen.
    public func remove(_ id: StoredProject.ID) {
        do {
            try store.remove(id: id)
            if selection == id { selection = nil }
            rebuildGroups()
        } catch {
            lastError = LocalizedKey.projectsErrorRemoveFailed.text
        }
    }

    /// Whether `project`'s directory can currently be found. Forwarded
    /// straight from `ProjectStore` — see its doc comment for why this
    /// re-checks the filesystem on every call rather than caching.
    public func isMissing(_ project: StoredProject) -> Bool {
        store.isMissing(project)
    }

    private func rebuildGroups() {
        groups = Self.buildGroups(from: store.projects)
    }

    /// Groups a flat, ordered project list by git main repository.
    ///
    /// Ordering is derived entirely from `projects`' own order — the order
    /// `store.projects` returns them in, which `ProjectStore` preserves as
    /// insertion order both in memory and across a JSON round-trip (a plain
    /// array, encoded and decoded in place; `JSONEncoder`'s `.sortedKeys`
    /// option sorts an *object*'s keys, never an array's elements). A group
    /// first appears at the position of the first project that resolves to
    /// its key, and every later project sharing that key is appended to the
    /// same group without moving it. That is what makes group order stable
    /// across a reload: run this twice on the same `store.projects` (whether
    /// freshly loaded or already in memory) and the groups come back in the
    /// same order, because nothing here depends on `Dictionary` iteration
    /// order or on any property of `ProjectGroup` itself.
    ///
    /// Grouping key, per project:
    /// - `.mainRepository(root:)` → the project's own path. It anchors a
    ///   group; any worktree of it (added or not) joins the same group.
    /// - `.worktree(root:, mainRepository:)` → the main repository's path,
    ///   whether or not that path is itself a `StoredProject`. See
    ///   `ProjectGroup`'s doc comment for what the sidebar shows when it
    ///   isn't.
    /// - `.notAGitRepository` → the project's own path. Since every stored
    ///   project has a unique `rootPath` (`ProjectStore` rejects duplicates),
    ///   this key can never collide with another project's key, so the
    ///   project forms a group of exactly one — never merged with, and never
    ///   hiding, anything else.
    static func buildGroups(from projects: [StoredProject]) -> [ProjectGroup] {
        var order: [String] = []
        var membersByKey: [String: [StoredProject]] = [:]

        for project in projects {
            let key: String
            switch WorktreeResolver.kind(of: project.rootPath) {
            case .mainRepository(let root):
                key = root
            case .worktree(_, let mainRepository):
                key = mainRepository
            case .notAGitRepository:
                key = project.rootPath
            }
            if membersByKey[key] == nil {
                order.append(key)
                membersByKey[key] = []
            }
            membersByKey[key]?.append(project)
        }

        return order.map { ProjectGroup(mainRepositoryPath: $0, members: membersByKey[$0] ?? []) }
    }
}

/// The project list: groups with worktree members indented under their main
/// repository, an "Add Project" control (`NSOpenPanel`, directories only,
/// plus drag-and-drop of folder URLs), and removal with a confirmation that
/// says plainly that nothing on disk is touched.
public struct ProjectSidebar: View {
    @Bindable private var model: ProjectSidebarModel
    @State private var pendingRemoval: StoredProject?
    @State private var isDropTargeted = false

    public init(model: ProjectSidebarModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            if model.groups.isEmpty {
                emptyState
            } else {
                List(selection: $model.selection) {
                    ForEach(model.groups) { group in
                        groupContent(group)
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()
            HStack {
                Button {
                    presentOpenPanel()
                } label: {
                    Label(.actionAddProject, systemImage: "plus")
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(8)
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
                model.remove(project.id)
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
                get: { model.lastError != nil },
                set: { isPresented in if !isPresented { model.lastError = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(.projectsEmptyTitle)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A group with more than one member, or whose sole member is a
    /// worktree (main repository not itself added), gets a header naming the
    /// main repository — see `groupHeaderText(_:)`. A lone, ordinary project
    /// renders without one; a header over a list of exactly one unrelated
    /// project would just be visual noise repeating the row beneath it.
    @ViewBuilder
    private func groupContent(_ group: ProjectGroup) -> some View {
        let isMainRepositoryItselfAMember = group.members.contains { $0.rootPath == group.mainRepositoryPath }
        if group.members.count > 1 || !isMainRepositoryItselfAMember {
            Section {
                ForEach(group.members) { member in
                    row(for: member, in: group).tag(member.id)
                }
            } header: {
                Text(groupHeaderText(group))
            }
        } else {
            ForEach(group.members) { member in
                row(for: member, in: group).tag(member.id)
            }
        }
    }

    /// The main repository's own project, if it was itself added — its
    /// display name reflects what the user actually typed (`StoredProject`'s
    /// `displayPath`/`displayName`, not the resolved `rootPath`). Otherwise
    /// the last path component of `mainRepositoryPath`, so a worktree whose
    /// main repository was never added still groups under a name that
    /// identifies it, rather than being pinned under a path string the
    /// sidebar shows nowhere else.
    private func groupHeaderText(_ group: ProjectGroup) -> String {
        if let mainProject = group.members.first(where: { $0.rootPath == group.mainRepositoryPath }) {
            return mainProject.displayName
        }
        return (group.mainRepositoryPath as NSString).lastPathComponent
    }

    @ViewBuilder
    private func row(for member: StoredProject, in group: ProjectGroup) -> some View {
        let isWorktreeMember = member.rootPath != group.mainRepositoryPath
        HStack(spacing: 6) {
            Image(systemName: isWorktreeMember ? "arrow.triangle.branch" : "folder")
                .foregroundStyle(isWorktreeMember ? .secondary : .primary)
                .padding(.leading, isWorktreeMember ? 14 : 0)

            VStack(alignment: .leading, spacing: 1) {
                Text(member.displayName)
                if isWorktreeMember {
                    Text(.projectsWorktreeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if model.isMissing(member) {
                Text(.projectsMissingBadge)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange.opacity(0.18), in: Capsule())
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                pendingRemoval = member
            } label: {
                Label(.actionRemoveProject, systemImage: "trash")
            }
        }
    }

    private func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = LocalizedKey.actionAddProject.text
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addProject(path: url.path)
    }

    /// Drag-and-drop of one or more folders onto the sidebar. Each dropped
    /// URL goes through `model.addProject(path:)` exactly like the open
    /// panel — a non-directory drop, or a duplicate, surfaces the same
    /// `lastError` alert rather than failing silently.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handledAny = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handledAny = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }
                Task { @MainActor in
                    model.addProject(path: url.path)
                }
            }
        }
        return handledAny
    }
}
