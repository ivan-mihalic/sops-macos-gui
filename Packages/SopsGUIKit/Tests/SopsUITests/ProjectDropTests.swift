import Foundation
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
