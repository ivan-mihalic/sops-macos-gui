import Foundation
import ScratchCleanup
import Testing

@testable import SopsProjects

/// How a file is *named* on screen: its path relative to the project root.
///
/// These assertions used to live on `ProjectAccessView.previewPath`, the
/// file-preview list of the project-wide Access panel SOPS-39 task 10
/// retired. The panel is gone; the computation is not — `AccessInventory
/// .FileAccess.relativePath` (and therefore every path the Access page, the
/// rewrap banner and the rule cards print) is exactly this function, and it
/// had no direct test of its own. Ported rather than deleted for that reason.
///
/// ⚠️ The hazard being pinned is a spelling one, not a string one. On this
/// machine `$TMPDIR` sits under a symlinked `/var`, so a scan hands back
/// `/private/var/…` while the project root keeps whatever spelling it was
/// constructed with. A literal prefix strip is then a no-op, every file is
/// named by its absolute path, and — far worse — every anchored `path_regex`
/// matches nothing. See `ProjectRecipientApplier.ruleMatchingPath`.
@Suite("A file is named by its path within the project")
struct ProjectRelativePathTests {

    @Test("a file under the root is named relative to it")
    func pathIsProjectRelative() {
        let root = URL(fileURLWithPath: "/tmp/relative-fixture")
        #expect(
            ProjectRecipientApplier.projectRelativePath(
                root.appendingPathComponent("prod/db.yaml"), under: root) == "prod/db.yaml")
        #expect(
            ProjectRecipientApplier.projectRelativePath(
                root.appendingPathComponent("a.yaml"), under: root) == "a.yaml")
    }

    /// A bare `lastPathComponent` is not a name in a project that keeps
    /// `db.yaml` under two directories, which is the ordinary shape — and the
    /// two spellings of one directory must not defeat the strip.
    @Test("the two spellings of the same directory do not defeat the strip")
    func pathResolvesSymlinkedSpellings() throws {
        let scratch = try ScratchDirectoryRegistry.shared.makeDirectory("relative-path")
        // A real tree, and a symlink pointing at it: the project root is
        // remembered under the symlink's spelling (`ProjectStore` stores the
        // display path a project was added under), while the walk that finds
        // the file resolves it. Built rather than borrowed from `/var`, so the
        // two spellings differ on any machine and not only this one.
        let real = scratch.appendingPathComponent("real", isDirectory: true)
        let directory = real.appendingPathComponent("prod", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("db.yaml")
        try "x\n".write(to: file, atomically: true, encoding: .utf8)

        let root = scratch.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: real)
        try #require(root.path != real.path, "precondition: the two spellings really do differ")

        #expect(ProjectRecipientApplier.projectRelativePath(file, under: root) == "prod/db.yaml")
        // And the other way round, which is the direction the scan actually
        // produces: root unresolved, file resolved.
        #expect(
            ProjectRecipientApplier.projectRelativePath(
                root.appendingPathComponent("prod/db.yaml"), under: real) == "prod/db.yaml")
    }

    /// A file outside the project has no relative name to give. Falling back
    /// to its absolute path is honest; a half-stripped one is not.
    @Test("a file outside the project keeps its own path")
    func pathFallsBackOutsideTheRoot() {
        let outside = ProjectRecipientApplier.projectRelativePath(
            URL(fileURLWithPath: "/elsewhere/db.yaml"),
            under: URL(fileURLWithPath: "/tmp/relative-fixture"))
        #expect(outside.hasSuffix("/elsewhere/db.yaml") || outside == "/elsewhere/db.yaml")
    }
}
