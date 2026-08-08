import Foundation
import Testing
@testable import SopsProjects

// Serialized: the relative-path normalization test below transiently
// changes the process's current working directory, which is global,
// mutable state. Parallel test execution would make that unsafe.
@Suite("ProjectStore", .serialized)
@MainActor
struct ProjectStoreTests {

    private func makeStore() -> (ProjectStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString).json")
        return (ProjectStore(fileURL: url), url)
    }

    private func makeDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("adding a directory persists it across instances")
    func addPersists() throws {
        let (store, url) = makeStore()
        let path = try makeDirectory()

        _ = try store.add(path: path)

        let reloaded = ProjectStore(fileURL: url)
        #expect(reloaded.projects.map(\.rootPath) == [path])
    }

    @Test("adding the same path twice reports the existing entry instead of duplicating")
    func rejectsDuplicates() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let first = try store.add(path: path)

        #expect(throws: ProjectStore.Error.self) { try store.add(path: path) }
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.id == first.id)
    }

    @Test("a file, not a directory, is refused")
    func rejectsFiles() throws {
        let (store, _) = makeStore()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("f-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: ProjectStore.Error.self) { try store.add(path: file.path) }
    }

    // A project directory the user deleted or unmounted must not crash the app
    // or vanish silently — the user needs to be told which one is gone.
    @Test("a project whose directory disappeared is kept and marked, not dropped")
    func survivesMissingDirectory() throws {
        let (store, url) = makeStore()
        let path = try makeDirectory()
        _ = try store.add(path: path)
        try FileManager.default.removeItem(atPath: path)

        let reloaded = ProjectStore(fileURL: url)
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.isMissing(reloaded.projects[0]))
    }

    @Test("a corrupt store file yields an empty list rather than throwing at launch")
    func toleratesCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString).json")
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)

        #expect(ProjectStore(fileURL: url).projects.isEmpty)
    }

    @Test("removing leaves the rest intact and persists")
    func removePersists() throws {
        let (store, url) = makeStore()
        let a = try store.add(path: try makeDirectory())
        _ = try store.add(path: try makeDirectory())

        try store.remove(id: a.id)

        #expect(ProjectStore(fileURL: url).projects.count == 1)
    }

    @Test("the health-source adapter exposes exactly the stored projects")
    func healthSourceMatches() throws {
        let (store, _) = makeStore()
        let p = try store.add(path: try makeDirectory())

        let source = store.healthSource
        #expect(source.projects.map(\.rootPath) == [p.rootPath])
    }

    // MARK: - Failure injection: in-memory state must never diverge from disk

    @Test("a failed persist during add leaves the in-memory list unchanged")
    func addDoesNotMutateOnPersistFailure() throws {
        let storeDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-dir-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: storeDir, withIntermediateDirectories: true)
        let url = storeDir.appendingPathComponent("projects.json")
        let store = ProjectStore(fileURL: url)

        let first = try store.add(path: try makeDirectory())

        // Read-only directory: the temp-file write inside persist() fails
        // before replaceItemAt is ever reached.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: storeDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: storeDir.path) }

        let second = try makeDirectory()
        #expect(throws: ProjectStore.Error.self) { try store.add(path: second) }

        // The in-memory list must match what's actually on disk: only the
        // first project, nothing appended for the failed add.
        #expect(store.projects.map(\.id) == [first.id])
        #expect(ProjectStore(fileURL: url).projects.map(\.id) == [first.id])

        // No stray temp file left behind either.
        let entries = try FileManager.default.contentsOfDirectory(atPath: storeDir.path)
        #expect(entries == ["projects.json"])
    }

    @Test("a failed persist during remove leaves the in-memory list unchanged")
    func removeDoesNotMutateOnPersistFailure() throws {
        let (store, url) = makeStore()
        let a = try store.add(path: try makeDirectory())
        let b = try store.add(path: try makeDirectory())

        // Immutable target file: the temp write succeeds, but replaceItemAt
        // fails at the swap step because the destination can't be replaced.
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path) }

        #expect(throws: ProjectStore.Error.self) { try store.remove(id: a.id) }

        // Both projects must still be present, in memory and on disk.
        #expect(Set(store.projects.map(\.id)) == [a.id, b.id])

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        #expect(Set(ProjectStore(fileURL: url).projects.map(\.id)) == [a.id, b.id])
    }

    // MARK: - Path normalization: the same directory must dedupe regardless of spelling

    @Test("a trailing slash is recognized as the same project")
    func dedupesTrailingSlash() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let first = try store.add(path: path)

        #expect(throws: ProjectStore.Error.alreadyAdded(existing: first)) {
            try store.add(path: path + "/")
        }
        #expect(store.projects.count == 1)
    }

    @Test("a path with .. components is recognized as the same project")
    func dedupesDotDotComponents() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let first = try store.add(path: path)

        let sibling = try makeDirectory()
        let viaDotDot = sibling + "/../" + (path as NSString).lastPathComponent

        #expect(throws: ProjectStore.Error.alreadyAdded(existing: first)) {
            try store.add(path: viaDotDot)
        }
        #expect(store.projects.count == 1)
    }

    @Test("a symlink and the directory it points to are recognized as the same project")
    func dedupesSymlinkAgainstTarget() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let first = try store.add(path: path)

        let symlink = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: URL(fileURLWithPath: path))

        #expect(throws: ProjectStore.Error.alreadyAdded(existing: first)) {
            try store.add(path: symlink.path)
        }
        #expect(store.projects.count == 1)
    }

    // MARK: - Display vs identity: carried over from Task 3's review

    // A project added through a symlink must be *identified* by the
    // resolved (target) path — that's what dedup keys off, proven by the
    // tests above — but *displayed* using the path the user actually typed.
    // Showing the resolved path in the sidebar would mean a user with a
    // symlinked home directory (iCloud Desktop/Documents does this) never
    // recognizes their own project.
    @Test("a project added via a symlink displays the symlink path, not the resolved target")
    func displaysSymlinkPathNotResolvedTarget() throws {
        let (store, _) = makeStore()
        let target = try makeDirectory()

        let symlink = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: URL(fileURLWithPath: target))

        let project = try store.add(path: symlink.path)

        // Identity: the resolved path, matching `WorktreeResolver` and every
        // filesystem operation the rest of the app performs on this project.
        #expect(project.rootPath == target)
        // Display: exactly what was typed, symlink component intact.
        #expect(project.displayPath == symlink.path)
        #expect(project.displayName == symlink.lastPathComponent)
    }

    // A non-symlinked path has nothing to disagree about: identity and
    // display must still both resolve to the same, ordinary directory.
    @Test("a project added via an ordinary path has matching identity and display paths")
    func displayMatchesIdentityWithoutASymlink() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()

        let project = try store.add(path: path)

        #expect(project.rootPath == path)
        #expect(project.displayPath == path)
    }

    // The display path must also survive a reload from disk — it is a real
    // stored field, not derived on the fly from `rootPath`.
    @Test("the display path persists across instances")
    func displayPathPersists() throws {
        let (store, url) = makeStore()
        let target = try makeDirectory()
        let symlink = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(
            at: symlink, withDestinationURL: URL(fileURLWithPath: target))

        _ = try store.add(path: symlink.path)

        let reloaded = ProjectStore(fileURL: url)
        #expect(reloaded.projects.map(\.displayPath) == [symlink.path])
        #expect(reloaded.projects.map(\.rootPath) == [target])
    }

    @Test("a relative path is recognized as the same project as its absolute form")
    func dedupesRelativePath() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let first = try store.add(path: path)

        let parent = (path as NSString).deletingLastPathComponent
        let leaf = (path as NSString).lastPathComponent
        let previousCWD = FileManager.default.currentDirectoryPath
        #expect(FileManager.default.changeCurrentDirectoryPath(parent))
        defer { FileManager.default.changeCurrentDirectoryPath(previousCWD) }

        #expect(throws: ProjectStore.Error.alreadyAdded(existing: first)) {
            try store.add(path: leaf)
        }
        #expect(store.projects.count == 1)
    }
}
