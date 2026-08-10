import Foundation
import ScratchCleanup
import Testing
@testable import SopsProjects

/// The sidebar badges a project **"Missing"** on the strength of
/// `ProjectStore.isMissing`, which was `FileManager.fileExists`. That call
/// needs `+x` on every directory above the one it is asked about, and answers
/// `false` — indistinguishable from "deleted" — when it does not have it.
///
/// `ProjectScanner` documented and fixed exactly this a round earlier, for the
/// project root, with `stat` and `errno`. The sidebar kept the old probe, so
/// with a locked parent directory one window says "Missing" while the file list
/// beside it says the folder could not be *read* — two parts of one app
/// disagreeing about one directory, and the sidebar holding the wrong end.
/// "Missing" sends the user to re-add the project; the real fix is permissions.
@Suite("A project that cannot be reached is not a project that is gone")
@MainActor
struct ProjectPresenceTests {

    private func store(_ directory: URL) throws -> ProjectStore {
        try ProjectStore(fileURL: directory.appendingPathComponent("projects.json"))
    }

    @Test("a project whose parent cannot be searched is not reported as missing")
    func unreadableParentIsNotMissing() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let parent = sandbox.appendingPathComponent("locked")
        let root = parent.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            try? FileManager.default.removeItem(at: sandbox)
        }

        let store = try store(sandbox)
        let project = try store.add(path: root.path)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        try #require(!FileManager.default.fileExists(atPath: root.path),
                     "the lock denied nothing — running as root would make this test vacuous")

        #expect(!store.isMissing(project),
                "the sidebar badges this project Missing while the folder is right there; only its parent's +x bit changed")
    }

    /// The other half: a project that really is gone must still say so, or the
    /// fix is just "never report missing".
    @Test("a deleted project is still reported as missing")
    func deletedProjectIsMissing() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-gone-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = try store(sandbox)
        let project = try store.add(path: root.path)
        try FileManager.default.removeItem(at: root)

        #expect(store.isMissing(project), "a deleted project was not reported as missing")
    }

    /// A path replaced by a plain file is not a usable project either.
    @Test("a project root replaced by a file is reported as missing")
    func fileInPlaceOfDirectoryIsMissing() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-file-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = try store(sandbox)
        let project = try store.add(path: root.path)
        try FileManager.default.removeItem(at: root)
        try "not a directory".write(to: root, atomically: true, encoding: .utf8)

        #expect(store.isMissing(project))
    }

    @Test("an ordinary project is present")
    func ordinaryProjectIsPresent() throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-ok-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let store = try store(sandbox)
        #expect(!store.isMissing(try store.add(path: root.path)))
    }
}
