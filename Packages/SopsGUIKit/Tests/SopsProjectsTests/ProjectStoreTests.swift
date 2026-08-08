import Foundation
import Testing
@testable import SopsProjects

@Suite("ProjectStore")
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

        store.remove(id: a.id)

        #expect(ProjectStore(fileURL: url).projects.count == 1)
    }

    @Test("the health-source adapter exposes exactly the stored projects")
    func healthSourceMatches() throws {
        let (store, _) = makeStore()
        let p = try store.add(path: try makeDirectory())

        let source = store.healthSource
        #expect(source.projects.map(\.rootPath) == [p.rootPath])
    }
}
