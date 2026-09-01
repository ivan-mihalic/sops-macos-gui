import Foundation
import ScratchCleanup
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
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
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

    /// The dotenv counterpart to `writeSopsLike` — hand-written text carrying
    /// the shape sops's dotenv store actually writes (`sops_`-prefixed
    /// `KEY=value` lines, no `sops:` block at all), for the same reason
    /// `writeSopsLike` is hand-written rather than bridge-encrypted: this
    /// suite is about `FileListModel`'s own wiring, not sops's file format —
    /// `ProjectScanner`'s and `EncryptedFileMetadata`'s own suites already
    /// hold the dotenv *shape itself* to the real-bridge standard.
    private func writeDotenvSopsLike(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        KEY=ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops_age__list_0__map_recipient=age1exampleexampleexampleexampleexampleexampleexampleexamplex
        sops_mac=ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops_version=3.13.3
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test("a fresh model reports nothing scanned yet")
    func freshModelHasNotScanned() throws {
        let model = FileListModel(projectRoot: try makeProject())
        #expect(model.files.isEmpty)
        #expect(!model.hasScanned)
        #expect(!model.isScanning)
        #expect(model.incompleteScanReason == nil)
        #expect(!model.rootMissing)
    }

    /// The defect this suite missed for two rounds: the model read
    /// `wasTruncated` (the file budget) and `skippedDirectoryNames` (a
    /// permanent, non-blocking exclusion) and nothing else. Four of the five
    /// limitations that block an affirmative verdict left every property it
    /// read at its default, so a project whose secrets sit in a directory this
    /// process cannot list rendered as a plain, confident "No encrypted files
    /// found in this project."
    ///
    /// Run as root, `chmod 000` does not deny anything — the test would then
    /// be asserting nothing, so it says so rather than passing.
    @Test("a subdirectory that cannot be listed stops the list claiming the project is empty")
    func unreadableSubdirectoryBlocksTheEmptyClaim() async throws {
        let root = try makeProject()
        let vault = root.appendingPathComponent("vault")
        try writeSopsLike(root, at: "vault/secrets.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path) }

        try #require(
            !FileManager.default.isReadableFile(atPath: vault.appendingPathComponent("secrets.yaml").path),
            "chmod 000 denied nothing — running as root would make this test vacuous")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.isEmpty, "precondition: the scan cannot reach the file")
        let reason = try #require(
            model.incompleteScanReason,
            "an unlistable subdirectory left the list free to claim the project holds no encrypted files")
        #expect(!reason.isEmpty)
    }

    /// A walk that really did cover the tree must not raise the banner —
    /// otherwise the fix above is just "always warn", which tells a user
    /// nothing and would pass the test above with a hardcoded string.
    @Test("a complete scan reports no reason to doubt it")
    func completeScanHasNoIncompleteReason() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "config/secrets.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.count == 1)
        #expect(model.incompleteScanReason == nil,
                "a readable project was reported as only partially scanned")
    }

    /// Task 5 (SOPS-38): a dotenv sops file now lands in `ScannedTree.encrypted`
    /// (verified, `format == .dotenv`), not `encryptedInOtherFormats` — but
    /// this app's editor still only opens YAML (`SopsDocument`), so it must
    /// not turn into an openable row here. `FileListView.swift`'s own
    /// temporary filter is what keeps that true; this pins the model-level
    /// half of it.
    @Test("a dotenv sops file is not listed as openable, and is counted alongside other formats")
    func dotenvFileIsNotOpenableButIsCounted() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "config/secrets.yaml")
        try writeDotenvSopsLike(root, at: "config/secrets.env")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.count == 1)
        #expect(model.files.first?.lastPathComponent == "secrets.yaml")
        #expect(model.otherFormatCount == 1)
    }

    /// `.git` exists in every real repository, so this list is almost never
    /// empty — and it used to be rendered only inside the truncation banner,
    /// which fires only on the rare walk that exhausts the file budget.
    @Test("directory names the walk never enters are reported without needing a truncated scan")
    func skippedDirectoriesAreReportedOnAnOrdinaryScan() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "config/secrets.yaml")
        try writeSopsLike(root, at: "node_modules/pkg/secrets.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.incompleteScanReason == nil, "a skipped dependency directory is not a blocking limitation")
        #expect(model.skippedDirectoryNames.contains("node_modules"),
                "the exclusion was not disclosed on an ordinary, untruncated scan")
    }

    /// Ticket #25 claim 2. `FileListModel` is what `FileListView` reads to
    /// offer "Add as Project" for an unfollowed directory symlink's target —
    /// this pins that the model actually carries the pair
    /// (`ScannedTree.unfollowedDirectorySymlinks`), not just that the scanner
    /// itself produces it (`UnfollowedSymlinkTargetTests` in `SopsHealthTests`
    /// already covers that half).
    @Test("an unfollowed directory symlink's target reaches the model")
    func unfollowedSymlinkTargetReachesTheModel() async throws {
        let root = try makeProject()
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("file-list-symlink-target-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(shared)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: shared) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("linked-secrets"), withDestinationURL: shared)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.unfollowedDirectorySymlinks.count == 1)
        #expect(model.unfollowedDirectorySymlinks.first?.target == shared.resolvingSymlinksInPath().path)
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
        ScratchDirectoryRegistry.shared.register(root)

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
