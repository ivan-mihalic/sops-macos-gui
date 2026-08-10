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
        // Surfaced immediately, not just after the first failed add/remove:
        // `ProjectStore.loadError` is set once, at the store's own `init`,
        // if the file on disk existed but could not be read. Without this,
        // the sidebar would open on an empty list with no explanation —
        // which reads as "you have no projects", a claim the store never
        // actually established. See `ProjectStore.loadError`'s doc comment.
        self.lastError = store.loadError
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
        lastError = attemptAdd(path)
    }

    /// Adds one project and *returns* what went wrong rather than publishing
    /// it, so a caller handling several at once can decide what the user sees.
    ///
    /// Split out because `addProject` begins by clearing `lastError`, and a
    /// drop of several items calls it once per item: the last provider to
    /// finish decided which single error survived, and a successful add landing
    /// after a failure wiped the failure entirely. Measured, not supposed.
    private func attemptAdd(_ path: String) -> String? {
        do {
            let project = try store.add(path: path)
            rebuildGroups()
            selection = project.id
            return nil
        } catch ProjectStore.Error.alreadyAdded(let existing) {
            selection = existing.id
            return LocalizedKey.projectsErrorDuplicate.text
        } catch ProjectStore.Error.notADirectory {
            return LocalizedKey.projectsErrorNotDirectory.text
        } catch {
            // ProjectStore.Error.unreadable — persisting the updated list
            // failed. Not narrated more specifically: the underlying I/O
            // error names no secret and isn't actionable beyond "try again".
            return LocalizedKey.projectsErrorAddFailed.text
        }
    }

    /// One drop, however many items it carried, resolved into one outcome.
    ///
    /// `unreadableCount` is the number of items that claimed to be file URLs
    /// and carried nothing this app could read — see `droppedProjectPath`.
    /// Every readable path is still added; the alert reports the first problem
    /// and says how many others there were, so a mixed drop cannot end in
    /// silence and cannot report only whichever item happened to finish last.
    public func addDroppedProjects(paths: [String], unreadableCount: Int) {
        lastError = nil

        var problems: [String] = []
        for path in paths {
            if let problem = attemptAdd(path) { problems.append(problem) }
        }
        problems.append(
            contentsOf: Array(repeating: LocalizedKey.projectsErrorDropUnreadable.text,
                              count: max(0, unreadableCount)))

        guard let first = problems.first else { return }
        lastError = problems.count == 1
            ? first
            : String(format: LocalizedKey.projectsErrorDropPartial.text, first, problems.count - 1)
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
                // Task 9 added this everywhere a `List` in this app can run
                // past its frame and missed the one list that is *always*
                // short of room — the sidebar is the narrowest, shortest
                // column in the window, and a developer with a dozen projects
                // overflows it before anything else. Without it, the last
                // visible project row ends at a hard edge that reads exactly
                // like the end of the list. Only ever drawn when there really
                // is more (`scrollOverflowFade()`'s doc comment), so the
                // ordinary two- or three-project sidebar is unchanged.
                .scrollOverflowFade()
            }

            Divider()
            // The whole footer row is the button, not just the words.
            //
            // Measured on the running app with `Scripts/ui-probe.swift`:
            // `AXButton "Add Project…" 101x16` sitting in a 220 pt sidebar —
            // click anywhere but the text and nothing happened. Same defect
            // as the About/Settings rows had, same cause: `.buttonStyle(.plain)`
            // makes the hit region the *rendered* content, and padding renders
            // nothing.
            //
            // The `Spacer()` that used to sit beside it is gone: it pushed the
            // label left inside a row the button did not own, which is exactly
            // how the dead area got there.
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
    /// Every provider is resolved first, and the model is told once.
    ///
    /// The version this replaces called into the model from each provider's own
    /// completion handler, independently. Those finish in any order, and
    /// `addProject` starts by clearing `lastError` — so a mixed drop of one
    /// unreadable item and one good folder ended with no alert at all whenever
    /// the good one finished last, which is exactly the silence the unreadable
    /// branch was added to end.
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
            model.addDroppedProjects(paths: paths, unreadableCount: unreadable)
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

/// The filesystem path inside whatever `NSItemProvider.loadItem` hands back for
/// `public.file-url`, or `nil` if there isn't one.
///
/// Two representations, because the provider's choice is not ours to make: it
/// depends on the source application and on how the item was registered.
/// Finder, `NSFilePromiseProvider`, and a same-process drag do not agree. An
/// `NSURL` needs no branch of its own — `as? URL` bridges it, which was
/// checked by deleting the branch and watching `nsurlIsRead` stay green rather
/// than by assuming it.
///
/// The version this replaces accepted `Data` alone. An `NSURL` — which is what
/// a drag originating in this process delivers — fell through a `guard … else
/// { return }` and the drop did nothing at all: no project added, no alert, no
/// log. The user drags a folder onto the sidebar and the app appears to have
/// simply ignored them.
///
/// Free function rather than a method so a test can call it without building a
/// view and without a real drag. That is not incidental: the previous bug was
/// unreachable from any test precisely because it lived inside a `private func`
/// on a `View`, and every test of dropping went through `addProject` directly.
func droppedProjectPath(from item: NSSecureCoding?) -> String? {
    if let url = item as? URL {
        return url.isFileURL ? url.path : nil
    }
    if let data = item as? Data,
       let url = URL(dataRepresentation: data, relativeTo: nil),
       url.isFileURL {
        return url.path
    }
    return nil
}
