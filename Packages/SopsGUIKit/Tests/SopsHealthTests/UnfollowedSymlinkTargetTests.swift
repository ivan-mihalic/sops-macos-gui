import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// Ticket #25 claim 2. An unfollowed directory symlink used to be recorded
/// with only the *link's own* path (`ScanLimitation.directorySymlinkNotFollowed(path:)`)
/// — the walk already resolves the target (`stat` on `linkTarget` in
/// `ProjectScanner.walk`) to decide the case applies at all, but threw that
/// resolution away rather than keeping it. Without the target, nothing
/// downstream could ever offer "this points at `<target>` — add it as its
/// own project", because nothing knew what the target was.
///
/// This pins that the target now survives into `ScannedTree`, through
/// `ScannedTree.unfollowedDirectorySymlinks` — the shape
/// `FileListModel`/`FileListView` read to offer that action.
@Suite("an unfollowed directory symlink keeps its target, not just its own path")
struct UnfollowedSymlinkTargetTests {

    @Test("the walk resolves and keeps the symlink's real target")
    func targetIsResolvedAndKept() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-target-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        let shared = sandbox.appendingPathComponent("shared-secrets")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let link = root.appendingPathComponent("secrets")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: shared)

        let scanned = await ProjectScanner.scan(root: root)

        let unfollowed = scanned.unfollowedDirectorySymlinks
        #expect(unfollowed.count == 1)
        let entry = try #require(unfollowed.first)
        // The walk enumerates under `root.resolvingSymlinksInPath()` (see
        // `ProjectScanner.walk`'s own comment on `enumerationRoot`), so the
        // reported path may run through `/private/var/...` on this machine
        // even though `link` itself was built from whatever spelling
        // `FileManager.temporaryDirectory` handed out — comparing suffixes
        // sidesteps that rather than trying to replicate the exact
        // resolution `walk` applies.
        #expect(entry.path.hasSuffix("/project/secrets"), "unexpected path: \(entry.path)")
        #expect(entry.target == shared.resolvingSymlinksInPath().path,
                "the recorded target must be the symlink's real destination, not the link itself")
    }

    /// A symlink that resolves to the excluded-directory-name route (e.g. a
    /// pnpm-style symlinked `node_modules`) is disclosed as the exclusion it
    /// is, not as an unfollowed-with-a-target case — `ProjectScanner.walk`'s
    /// own comment says so. Pinned here too, because that branch is what
    /// `unfollowedDirectorySymlinks` must **not** pick up.
    @Test("a symlink matching an excluded directory name is not offered as addable")
    func excludedNameSymlinkIsNotAnUnfollowedTarget() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("symlink-excluded-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(sandbox)
        let root = sandbox.appendingPathComponent("project")
        let realStore = sandbox.appendingPathComponent("real-node-modules")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realStore, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("node_modules"), withDestinationURL: realStore)

        let scanned = await ProjectScanner.scan(root: root)

        #expect(scanned.unfollowedDirectorySymlinks.isEmpty)
        #expect(scanned.skippedDirectoryNames.contains("node_modules"))
    }
}
