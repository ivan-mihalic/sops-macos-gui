import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// `AcknowledgedUnreadableMarker` is ticket #10, claim 3's answer to "record
/// permanently that a file was created with `acknowledgedUnreadable == true`":
/// an extended attribute on the file itself, tagged by `SecretFileCreator`
/// right after a successful write and read back by `ProjectHealthCheck`'s new
/// finding.
///
/// A real file on the real filesystem, never a fake — the whole point is
/// exercising `setxattr`/`getxattr` against APFS, which a mock cannot stand
/// in for.
@Suite("AcknowledgedUnreadableMarker")
struct AcknowledgedUnreadableMarkerTests {

    private func makeFile() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acknowledged-unreadable-marker-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("secret.yaml")
        try "sops: {}\n".write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test("an unmarked file reports as unmarked")
    func unmarkedFileIsNotMarked() throws {
        let file = try makeFile()
        #expect(!AcknowledgedUnreadableMarker.isMarked(file))
    }

    @Test("a marked file reports as marked")
    func markedFileIsMarked() throws {
        let file = try makeFile()
        AcknowledgedUnreadableMarker.mark(file)
        #expect(AcknowledgedUnreadableMarker.isMarked(file))
    }

    @Test("marking one file does not mark a sibling")
    func markingIsPerFileNotPerDirectory() throws {
        let file = try makeFile()
        let sibling = file.deletingLastPathComponent().appendingPathComponent("other.yaml")
        try "sops: {}\n".write(to: sibling, atomically: true, encoding: .utf8)

        AcknowledgedUnreadableMarker.mark(file)

        #expect(AcknowledgedUnreadableMarker.isMarked(file))
        #expect(!AcknowledgedUnreadableMarker.isMarked(sibling))
    }

    @Test("a path with nothing on disk is reported as unmarked, not thrown")
    func nonexistentPathIsUnmarked() {
        let ghost = FileManager.default.temporaryDirectory
            .appendingPathComponent("acknowledged-unreadable-marker-ghost-" + UUID().uuidString)
            .appendingPathComponent("nothing-here.yaml")
        #expect(!AcknowledgedUnreadableMarker.isMarked(ghost))
    }
}
