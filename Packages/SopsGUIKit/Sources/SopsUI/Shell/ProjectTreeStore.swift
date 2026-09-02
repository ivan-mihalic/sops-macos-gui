import Observation
import SopsProjects
import SwiftUI

/// One `FileListModel` and one `AccessInventory` per added project, kept for
/// as long as the window is open — SOPS-39 task 6.
///
/// ## Why a store at all
/// The four-column window only ever had **one** project's files in memory:
/// `ProjectWorkspaceView` built a fresh `FileListModel` every time the
/// project selection changed and threw the previous one away. A tree shows
/// every project's files at once, so "the model for the selected project" is
/// no longer a thing that exists — each project needs its own, alive
/// simultaneously, and something has to own them. This does.
///
/// ## Why the inventory lives here too
/// It is derived from the same scan. `FileListModel.refresh()` already walks
/// the project and now keeps its `ScannedTree` (`lastTree`), so `refresh(_:)`
/// below builds the inventory from *that* tree rather than scanning again.
/// Two independent walks would be two observations of a directory that can
/// change between them: the status dot beside a row could then describe a
/// file set the row list never showed, which is the kind of quiet
/// disagreement `ProjectWorkspaceView.recipientRegistryProjectRoot`'s own doc
/// comment records this app having shipped once already.
///
/// Models are keyed by `StoredProject.ID`, never by path: a project's stored
/// identity is what the tree's selection (`WorkspaceSelection`) is built on,
/// and two entries could legitimately resolve to the same directory through
/// a symlink.
@MainActor
@Observable
public final class ProjectTreeStore {

    private let keyStore: SessionKeyStore
    private var models: [StoredProject.ID: FileListModel] = [:]
    private var inventories: [StoredProject.ID: AccessInventory] = [:]
    private var accessModels: [StoredProject.ID: (targetFile: URL?, model: ProjectAccessModel)] = [:]

    public init(keyStore: SessionKeyStore) {
        self.keyStore = keyStore
    }

    /// The file list model for `project`, created on first use.
    ///
    /// Lazy rather than built for every stored project up front: a user with
    /// a dozen projects added would otherwise pay a dozen full directory
    /// walks to open a window, for rows that are collapsed and unread.
    public func model(for project: StoredProject) -> FileListModel {
        if let existing = models[project.id] { return existing }
        let model = FileListModel(
            projectRoot: URL(fileURLWithPath: project.rootPath), keyStore: keyStore)
        models[project.id] = model
        return model
    }

    /// The Access page's model for `project` — created on first use and
    /// **reused** for every later render of the same page.
    ///
    /// ## Why this cannot be built in a view body
    /// `ProjectAccessPage` holds its model as `@Bindable` and loads it from a
    /// bare `.task { await model.load() }` — no `id:`. A `.task` without an
    /// `id:` runs once per view *identity*, and the identity of the Access
    /// pane does not change when `AppShell`'s body is merely re-evaluated
    /// (another project finishing its scan, `lastError` clearing, the window
    /// resizing). So a model constructed inline in `AppShell.detail` would be
    /// replaced by a fresh, **unloaded** one on any such re-render while the
    /// view stayed put and never re-ran its `.task`: staged recipients gone,
    /// panel blank, no error anywhere. That is the SOPS-37 shape — a panel
    /// that accepts a recipient and silently drops it.
    ///
    /// ## When it *is* recreated
    /// Only when `targetFile` changes. That argument decides which rule the
    /// panel plans around (`ProjectAccessModel.init(projectRoot:keyStore:
    /// targetFile:)`), so keeping a model built for a different file would
    /// describe the wrong rule — the defect SOPS-38 fixed by threading the
    /// selected file through in the first place. Recreating on that one input
    /// is a deliberate, narrow exception to the reuse above, and it is safe
    /// for the same reason the reuse is necessary: a *new* model is a new
    /// view identity's worth of state, so the panel's `.task` runs again.
    public func accessModel(for project: StoredProject, targetFile: URL?) -> ProjectAccessModel {
        if let existing = accessModels[project.id], existing.targetFile == targetFile {
            return existing.model
        }
        let model = ProjectAccessModel(
            projectRoot: URL(fileURLWithPath: project.rootPath),
            keyStore: keyStore, targetFile: targetFile)
        accessModels[project.id] = (targetFile, model)
        return model
    }

    /// What `.sops.yaml` governs, and how each file compares against it —
    /// `nil` until `refresh(_:)` has completed for this project at least
    /// once. A row with no inventory yet draws no status dot, which is the
    /// honest rendering of "not measured", not "in sync".
    public func inventory(for id: StoredProject.ID) -> AccessInventory? {
        inventories[id]
    }

    /// Rescans `project` and rebuilds its inventory from that one scan.
    ///
    /// The inventory is assigned only after `refresh()` returns, so a view
    /// observing this store never sees the new file rows paired with the
    /// previous scan's statuses — the same one-pass discipline
    /// `FileListModel.refresh()` applies to its own properties.
    public func refresh(_ project: StoredProject) async {
        let model = model(for: project)
        await model.refresh()
        guard let tree = model.lastTree else {
            // `refresh()` always sets `lastTree`; a `nil` here would mean the
            // model changed underneath this call. Clearing rather than
            // keeping the previous inventory: a stale one would describe a
            // scan whose files are no longer on screen.
            inventories[project.id] = nil
            return
        }
        inventories[project.id] = AccessInventory.build(
            projectRoot: model.projectRoot, tree: tree)
    }

    /// Drops everything remembered about a project — called when it is
    /// removed from the sidebar, so a re-added directory is scanned afresh
    /// rather than answered from a model built before it was forgotten.
    public func forget(_ id: StoredProject.ID) {
        models[id] = nil
        inventories[id] = nil
        accessModels[id] = nil
    }
}
