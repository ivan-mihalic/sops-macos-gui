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

/// The Add Project panel, configured but not run.
///
/// Separate from the button that runs it so a test can look at it:
/// `runModal()` blocks on a real window, so a panel built inline in the
/// method that immediately runs it cannot be inspected at all — which is how
/// it went a whole release cycle without a New Folder button and nothing
/// noticed. See `ProjectOpenPanelTests`.
///
/// A free type rather than a static on the sidebar view: the view that owns
/// the footer is now `ProjectTreeSidebar` (SOPS-39 task 6), and pinning this
/// to whichever view currently draws the button is what made it move once
/// already.
public enum ProjectOpenPanel {
    public static func make() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        // `NSOpenPanel` defaults this to `false` — `NSSavePanel` is the one
        // that defaults to `true`. So the New Folder button was missing
        // because nobody asked for it, not because macOS withholds it from
        // open panels. A project is a directory the user may not have made
        // yet, and sending them to Finder to create one mid-flow is the kind
        // of small dead end that makes an app feel like it is not on your
        // side.
        panel.canCreateDirectories = true
        panel.prompt = LocalizedKey.actionAddProject.text
        return panel
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
