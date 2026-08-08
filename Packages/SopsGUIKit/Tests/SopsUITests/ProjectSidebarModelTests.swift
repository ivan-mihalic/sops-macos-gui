import Foundation
import Testing
@testable import SopsUI
import SopsProjects

@Suite("ProjectSidebarModel")
@MainActor
struct ProjectSidebarModelTests {

    private func makeStore() -> (ProjectStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebar-projects-\(UUID().uuidString).json")
        return (ProjectStore(fileURL: url), url)
    }

    private func makeDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    /// A real repository with one real linked worktree, built with the real
    /// `git` binary — a hand-authored `.git` file proves nothing about
    /// grouping, only about parsing. Mirrors `WorktreeResolverTests`.
    private func makeRepoWithWorktree() throws -> (main: String, worktree: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let main = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)

        try git(["init", "-q"], in: main)
        try "x".write(to: main.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: main)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: main)

        let wt = base.appendingPathComponent("wt")
        try git(["worktree", "add", "-q", wt.path, "-b", "feature"], in: main)
        return (main.path, wt.path)
    }

    // MARK: - Grouping

    @Test("worktrees are grouped under their main repository")
    func worktreesGroupUnderMainRepository() throws {
        let (main, worktree) = try makeRepoWithWorktree()
        let (store, _) = makeStore()
        let mainProject = try store.add(path: main)
        let worktreeProject = try store.add(path: worktree)

        let model = ProjectSidebarModel(store: store)

        #expect(model.groups.count == 1)
        let group = try #require(model.groups.first)
        #expect(group.mainRepositoryPath == mainProject.rootPath)
        #expect(group.members.map(\.id) == [mainProject.id, worktreeProject.id])
    }

    @Test("a project that is not a git repository forms its own group")
    func nonGitProjectFormsItsOwnGroup() throws {
        let (store, _) = makeStore()
        let plain = try store.add(path: try makeDirectory())

        let model = ProjectSidebarModel(store: store)

        #expect(model.groups.count == 1)
        let group = try #require(model.groups.first)
        #expect(group.mainRepositoryPath == plain.rootPath)
        #expect(group.members.map(\.id) == [plain.id])
    }

    // The resolver reports a worktree's main repository path regardless of
    // whether anything is stored there — the sidebar still has to group the
    // worktree sensibly, under that path, rather than falling back to
    // treating it as an ungrouped, standalone project.
    @Test("a worktree whose main repository is not itself an added project still groups sensibly")
    func worktreeWithoutItsMainRepositoryAdded() throws {
        let (main, worktree) = try makeRepoWithWorktree()
        let (store, _) = makeStore()
        let worktreeProject = try store.add(path: worktree)
        // `main` is deliberately never added to the store.

        let model = ProjectSidebarModel(store: store)

        #expect(model.groups.count == 1)
        let group = try #require(model.groups.first)
        #expect(group.mainRepositoryPath == main)
        #expect(group.members.map(\.id) == [worktreeProject.id])
    }

    // Two unrelated non-git projects must never collapse into one group —
    // each project's own (unique, store-enforced) rootPath is its key.
    @Test("two unrelated non-git projects form two separate groups")
    func twoUnrelatedProjectsFormSeparateGroups() throws {
        let (store, _) = makeStore()
        let a = try store.add(path: try makeDirectory())
        let b = try store.add(path: try makeDirectory())

        let model = ProjectSidebarModel(store: store)

        #expect(model.groups.count == 2)
        #expect(Set(model.groups.map(\.mainRepositoryPath)) == [a.rootPath, b.rootPath])
    }

    // An unstable order makes the sidebar reshuffle itself on every launch
    // for no reason a user did anything to cause.
    @Test("group ordering is stable across reloads")
    func groupOrderingIsStableAcrossReloads() throws {
        let (main, worktree) = try makeRepoWithWorktree()
        let (store, url) = makeStore()
        _ = try store.add(path: try makeDirectory())
        _ = try store.add(path: main)
        _ = try store.add(path: worktree)
        _ = try store.add(path: try makeDirectory())

        let firstOrder = ProjectSidebarModel(store: store).groups.map(\.mainRepositoryPath)

        // A fresh store instance loading the same file, as a relaunch would.
        let reloadedStore = ProjectStore(fileURL: url)
        let secondOrder = ProjectSidebarModel(store: reloadedStore).groups.map(\.mainRepositoryPath)

        #expect(firstOrder == secondOrder)
        #expect(firstOrder.count == 3, "4 projects, but the repo pair collapses into 1 group")
    }

    // MARK: - Error surfacing

    @Test("adding a duplicate surfaces an error instead of throwing into the view")
    func addingDuplicateSurfacesError() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let model = ProjectSidebarModel(store: store)

        model.addProject(path: path)
        #expect(model.lastError == nil)
        let first = try #require(model.groups.first?.members.first)

        model.addProject(path: path)

        #expect(model.lastError != nil)
        #expect(model.groups.count == 1, "no duplicate group or member was created")
        #expect(model.groups.first?.members.count == 1)
        // The duplicate still selects the existing entry — the user asked to
        // see this project, and it's already there.
        #expect(model.selection == first.id)
    }

    @Test("adding a path that is not a directory surfaces an error")
    func addingAFileSurfacesError() throws {
        let (store, _) = makeStore()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("f-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let model = ProjectSidebarModel(store: store)

        model.addProject(path: file.path)

        #expect(model.lastError != nil)
        #expect(model.groups.isEmpty)
        #expect(model.selection == nil)
    }

    @Test("a successful add clears a previous error and selects the new project")
    func successfulAddClearsErrorAndSelects() throws {
        let (store, _) = makeStore()
        let model = ProjectSidebarModel(store: store)

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("f-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        model.addProject(path: file.path)
        #expect(model.lastError != nil)

        model.addProject(path: try makeDirectory())

        #expect(model.lastError == nil)
        #expect(model.selection == model.groups.first?.members.first?.id)
    }

    // MARK: - Selection

    @Test("removing the selected project clears the selection")
    func removingSelectedProjectClearsSelection() throws {
        let (store, _) = makeStore()
        let model = ProjectSidebarModel(store: store)
        model.addProject(path: try makeDirectory())
        let project = try #require(model.groups.first?.members.first)
        model.selection = project.id

        model.remove(project.id)

        #expect(model.selection == nil)
        #expect(model.groups.isEmpty)
    }

    @Test("removing a project that is not selected leaves the selection untouched")
    func removingUnselectedProjectLeavesSelectionUntouched() throws {
        let (store, _) = makeStore()
        let model = ProjectSidebarModel(store: store)
        model.addProject(path: try makeDirectory())
        let kept = try #require(model.selection)
        model.addProject(path: try makeDirectory())
        let toRemove = try #require(model.groups.last?.members.first?.id)
        #expect(toRemove != kept)

        // Re-select the first project explicitly — adding the second moved
        // selection onto it.
        model.selection = kept
        model.remove(toRemove)

        #expect(model.selection == kept)
    }

    // MARK: - Missing directories

    // A project whose directory disappeared must stay visible, grouped and
    // marked, not silently drop out of the sidebar.
    @Test("a project whose directory disappeared is shown as missing rather than vanishing")
    func missingDirectoryIsShownRatherThanDropped() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let project = try store.add(path: path)
        try FileManager.default.removeItem(atPath: path)

        let model = ProjectSidebarModel(store: store)

        #expect(model.groups.count == 1)
        #expect(model.groups.first?.members.map(\.id) == [project.id])
        #expect(model.isMissing(project))
    }
}

private func git(_ args: [String], in dir: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}
