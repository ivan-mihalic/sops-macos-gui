import Foundation
import SopsProjects
import Testing
@testable import SopsUI

/// `NSItemProvider.loadItem(forTypeIdentifier: "public.file-url")` does not
/// promise a representation. Which one arrives depends on the source of the
/// drag, and the sidebar used to accept exactly one of them.
@Suite("A dropped folder is read whatever representation it arrives in")
struct ProjectDropTests {

    private static let folder = "/tmp/some project folder"

    /// The representation a same-process drag delivers. Previously fell
    /// through to `return` inside the completion handler: no project, no
    /// alert, no trace — the sidebar simply ignored the drop.
    @Test("an NSURL drop yields its path")
    func nsurlIsRead() throws {
        let item = NSURL(fileURLWithPath: Self.folder)
        let path = try #require(droppedProjectPath(from: item),
                                "an NSURL drop was silently discarded")
        #expect(path == Self.folder)
    }

    @Test("a URL drop yields its path")
    func urlIsRead() throws {
        let item = URL(fileURLWithPath: Self.folder) as NSURL
        let path = try #require(droppedProjectPath(from: item))
        #expect(path == Self.folder)
    }

    /// The one representation that always worked. Kept so a fix that swapped
    /// which case is handled, rather than adding to them, fails here.
    @Test("a bookmark-data drop yields its path")
    func dataIsRead() throws {
        let data = URL(fileURLWithPath: Self.folder).dataRepresentation
        let path = try #require(droppedProjectPath(from: data as NSData as NSSecureCoding))
        #expect(path == Self.folder)
    }

    /// Not every `public.file-url` is a file. A drop this app cannot turn into
    /// a path must say so rather than be read as some other path.
    @Test("a non-file URL is refused rather than guessed at", arguments: [
        "https://example.com/secrets", "ftp://example.com/x",
    ])
    func nonFileURLIsRefused(_ text: String) throws {
        let url = try #require(URL(string: text))
        #expect(droppedProjectPath(from: url as NSURL) == nil,
                "a \(url.scheme ?? "?") URL was accepted as a project folder")
    }

    @Test("an item that carries nothing readable is refused")
    func unreadableItemIsRefused() {
        #expect(droppedProjectPath(from: nil) == nil)
        #expect(droppedProjectPath(from: "not a url" as NSString) == nil)
        #expect(droppedProjectPath(from: Data([0xFF, 0xFE]) as NSData) == nil)
    }
}

/// A drop carries several items, and each provider's completion handler used to
/// call into the model on its own. `addProject` starts by clearing `lastError`,
/// so which single message survived was decided by which provider finished
/// last — and a good folder finishing after an unreadable item wiped the alert
/// entirely, putting the user right back in the silence the alert was added to
/// end.
@Suite("One drop produces one outcome")
@MainActor
struct ProjectDropBatchTests {

    private func model() throws -> ProjectSidebarModel {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return ProjectSidebarModel(
            store: try ProjectStore(fileURL: directory.appendingPathComponent("projects.json")))
    }

    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("drop-folder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("an unreadable item is still reported when a good folder is in the same drop")
    func unreadableSurvivesAGoodFolder() throws {
        let model = try model()
        model.addDroppedProjects(paths: [try folder()], unreadableCount: 1)

        #expect(model.groups.count == 1, "the readable folder was not added")
        #expect(model.lastError != nil,
                "the unreadable item was reported by nobody because a successful add cleared it")
    }

    @Test("a drop with nothing wrong shows no alert")
    func cleanDropIsSilent() throws {
        let model = try model()
        model.addDroppedProjects(paths: [try folder(), try folder()], unreadableCount: 0)

        #expect(model.groups.count == 2)
        #expect(model.lastError == nil, "a drop that worked raised an alert")
    }

    @Test("several problems in one drop are counted, not overwritten",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on text a *format* key produces, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value, which carries no %@ to substitute into; run under xcodebuild or swift test --build-system swiftbuild"),)
    func problemsAreCounted() throws {
        let model = try model()
        let duplicate = try folder()
        model.addProject(path: duplicate)

        model.addDroppedProjects(paths: [duplicate], unreadableCount: 2)

        let reported = try #require(model.lastError)
        #expect(reported.contains("2"),
                "three problems in one drop were reported as one: \(reported)")
    }

    /// The readable folders must be added even when something else in the drop
    /// failed — refusing the whole batch would be a different bug.
    @Test("a failure does not discard the rest of the drop")
    func partialFailureStillAddsTheRest() throws {
        let model = try model()
        model.addDroppedProjects(paths: [try folder(), try folder()], unreadableCount: 1)

        #expect(model.groups.count == 2, "good folders were dropped because another item failed")
        #expect(model.lastError != nil)
    }
}
