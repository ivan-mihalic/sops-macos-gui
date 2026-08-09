import Foundation
import Testing
@testable import SopsUI

// Fixtures here are hand-written text carrying the same markers
// `ProjectScanner`'s own suite uses (`sops:`, `sops_mac=`) — not a real `sops`
// CLI encrypt. That mirrors `ProjectScanner`'s own tests (e.g.
// `ProjectScanBoundsTests`), because what's under test here is `FileListModel`
// wrapping `ProjectScanner`'s result — path formatting, sorting, and which
// published properties come from where — not sops's own file format, which
// `ProjectScanner`'s and the bridge's suites already hold to the real-binary
// standard.
//
// They must still carry the *shape* sops writes, not just its markers. Task 14
// tightened `ProjectScanner` from substring sniffing to a structural check
// (`SopsMetadataShape`) after this app classified two of its own Markdown task
// reports as openable encrypted files. A fixture with a `sops:` block but no
// `version:` under it was never something sops could have produced, and no
// longer passes for one.
@Suite("FileListModel")
@MainActor
struct FileListModelTests {

    private func makeProject() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSopsLike(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age:
                - recipient: age1exampleexampleexampleexampleexampleexampleexampleexamplex
            mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            version: 3.13.3
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a fresh model reports nothing scanned yet")
    func freshModelHasNotScanned() throws {
        let model = FileListModel(projectRoot: try makeProject())
        #expect(model.files.isEmpty)
        #expect(!model.hasScanned)
        #expect(!model.isScanning)
        #expect(!model.wasTruncated)
        #expect(!model.rootMissing)
    }

    @Test("refresh finds an encrypted file and reports it relative to the project root")
    func refreshFindsEncryptedFile() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "config/secrets.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.hasScanned)
        #expect(model.files.count == 1)
        let found = try #require(model.files.first)
        #expect(model.relativePath(for: found) == "config/secrets.yaml")
    }

    @Test("files are sorted by their relative path")
    func filesAreSortedByRelativePath() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "z-last.yaml")
        try writeSopsLike(root, at: "a-first.yaml")
        try writeSopsLike(root, at: "middle/b.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.map { model.relativePath(for: $0) } == [
            "a-first.yaml", "middle/b.yaml", "z-last.yaml",
        ])
    }

    @Test("a plaintext file is not listed as an encrypted file")
    func plaintextFileIsNotListed() async throws {
        let root = try makeProject()
        try "not encrypted at all".write(
            to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.isEmpty)
        #expect(model.hasScanned)
    }

    @Test("a missing project root is reported as rootMissing, not as an empty project")
    func missingRootIsReported() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.rootMissing)
        #expect(model.files.isEmpty)
    }

    @Test("relativePath falls back to the full path for a URL outside the project root")
    func relativePathFallsBackForForeignURL() throws {
        let model = FileListModel(projectRoot: try makeProject())
        let foreign = URL(fileURLWithPath: "/completely/elsewhere/file.yaml")
        #expect(model.relativePath(for: foreign) == foreign.path)
    }
}
