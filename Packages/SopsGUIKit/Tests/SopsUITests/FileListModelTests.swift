import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
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
// MARK: - Real age key pairs, for the isReadOnly (SOPS-38 phase F3) tests
// below only. Redeclared here rather than imported — the rest of this file's
// fixtures are deliberately hand-written text, but `isReadOnly` needs a real
// derived public key (`SessionKeyStore.sessionPublicKey`, via the real
// bridge) to compare against, and every other `SopsUITests` file that needs
// a real key pair already keeps its own file-private copy rather than
// reaching across targets for `SopsProjectsTests`' — see
// `FileListModelConfigStateTests.swift`'s own header comment.

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func toolPath(_ name: String) throws -> String {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        .map { ($0 as NSString).appendingPathComponent(name) }
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw FixtureError("\(name) not found in \(candidates)")
    }
    return found
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError(
            "\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): "
                + String(decoding: errData, as: UTF8.self))
    }
    return String(decoding: outData, as: UTF8.self)
}

private struct AgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> AgeKeyPair {
        let output = try run(try toolPath("age-keygen"), [])
        var priv = "", pub = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw FixtureError("age-keygen produced no usable key pair")
        }
        return AgeKeyPair(private: priv, public: pub)
    }
}

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

    private func writeSopsLike(
        _ root: URL, at relativePath: String,
        recipient: String = "age1exampleexampleexampleexampleexampleexampleexampleexamplex"
    ) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age:
                - recipient: \(recipient)
            mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            version: 3.13.3
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A file that is still genuinely sops-shaped (`sops:`, `mac:`,
    /// `version:` — `SopsMetadataShape.isYAMLMetadata` cares about those,
    /// never about `age` itself) but declares **no** age recipients at all:
    /// `age: []`. `EncryptedFileMetadata.recipients(inEncryptedFile:)` scans
    /// for `- recipient:`/`recipient:` lines inside the `sops:` block and
    /// finds none, so `SniffedFile.recipients` comes back `[]` — the same
    /// "unknown/unparseable metadata" shape `FileListModel.isReadOnly`'s own
    /// doc comment names, reached here without any real non-age backend
    /// (PGP/KMS), which this test target has no way to produce.
    private func writeSopsLikeWithNoRecipients(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age: []
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

    /// Task 5 (SOPS-38) put a dotenv sops file into `ScannedTree.encrypted`
    /// (verified, `format == .dotenv`), not `encryptedInOtherFormats` — but
    /// left it filtered out of `files` because the editor could not open it
    /// yet. Task 6 taught `SecretDocumentViewModel` a document's format
    /// (threaded through to the bridge), so that TEMPORARY filter in
    /// `FileListView.swift`'s `refresh()` is gone: a dotenv file is listed
    /// and openable exactly like YAML, carrying its own format so the
    /// editor opens it correctly, and `otherFormatCount` goes back to
    /// counting only what this build genuinely cannot verify at all
    /// (JSON/INI).
    @Test("a dotenv sops file is listed as openable, carrying its own format")
    func dotenvFileIsListedAndOpenable() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "config/secrets.yaml")
        try writeDotenvSopsLike(root, at: "config/secrets.env")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.count == 2)
        let dotenvFile = try #require(model.files.first { $0.url.lastPathComponent == "secrets.env" })
        #expect(dotenvFile.format == .dotenv)
        let yamlFile = try #require(model.files.first { $0.url.lastPathComponent == "secrets.yaml" })
        #expect(yamlFile.format == .yaml)
        #expect(model.otherFormatCount == 0)
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
        #expect(model.relativePath(for: found.url) == "config/secrets.yaml")
    }

    @Test("files are sorted by their relative path")
    func filesAreSortedByRelativePath() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "z-last.yaml")
        try writeSopsLike(root, at: "a-first.yaml")
        try writeSopsLike(root, at: "middle/b.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(model.files.map { model.relativePath(for: $0.url) } == [
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

    // MARK: - isReadOnly (SOPS-38 phase F3): detected from metadata, no decrypt

    @Test("a file encrypted to the session's own key is not read-only")
    func ownKeyFileIsNotReadOnly() async throws {
        let mine = try AgeKeyPair.generate()
        let root = try makeProject()
        try writeSopsLike(root, at: "mine.yaml", recipient: mine.public)

        let store = SessionKeyStore()
        try store.importKey(mine.private)
        let model = FileListModel(projectRoot: root, keyStore: store)
        await model.refresh()

        let file = try #require(model.files.first)
        #expect(!file.isReadOnly)
    }

    @Test("a file encrypted only to a foreign key is read-only")
    func foreignKeyFileIsReadOnly() async throws {
        let mine = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try makeProject()
        try writeSopsLike(root, at: "theirs.yaml", recipient: stranger.public)

        let store = SessionKeyStore()
        try store.importKey(mine.private)
        let model = FileListModel(projectRoot: root, keyStore: store)
        await model.refresh()

        let file = try #require(model.files.first)
        #expect(file.isReadOnly)
    }

    /// A project with both kinds of file must report each independently —
    /// this is what actually rules out a model-wide flag or a
    /// first-file-wins bug that a single-file test could not catch.
    @Test("a mixed project reports isReadOnly per file, not per project")
    func mixedProjectReportsPerFile() async throws {
        let mine = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try makeProject()
        try writeSopsLike(root, at: "mine.yaml", recipient: mine.public)
        try writeSopsLike(root, at: "theirs.yaml", recipient: stranger.public)

        let store = SessionKeyStore()
        try store.importKey(mine.private)
        let model = FileListModel(projectRoot: root, keyStore: store)
        await model.refresh()

        #expect(model.files.count == 2)
        let mineFile = try #require(model.files.first { $0.url.lastPathComponent == "mine.yaml" })
        let theirsFile = try #require(model.files.first { $0.url.lastPathComponent == "theirs.yaml" })
        #expect(!mineFile.isReadOnly)
        #expect(theirsFile.isReadOnly)
    }

    /// The conservatism the brief requires in both directions this app must
    /// never overclaim: no key store at all (`FileListModel`'s own default)
    /// is exactly the shape every pre-existing call site in this file uses,
    /// and it must keep behaving as "not known", not "everything is
    /// read-only".
    @Test("with no key store configured, no file is reported read-only")
    func noKeyStoreMeansNothingIsFlagged() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "secret.yaml", recipient: "age1exampleexampleexampleexampleexampleexampleexampleexamplex")

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        let file = try #require(model.files.first)
        #expect(!file.isReadOnly)
    }

    /// A key store with no key imported yet (a locked session) must behave
    /// identically to no key store at all — `sessionPublicKey` is `nil`
    /// either way, and `FileListModel` must not distinguish the two.
    @Test("a locked session (no key imported) reports nothing as read-only")
    func lockedSessionMeansNothingIsFlagged() async throws {
        let root = try makeProject()
        try writeSopsLike(root, at: "secret.yaml", recipient: "age1exampleexampleexampleexampleexampleexampleexampleexamplex")

        let store = SessionKeyStore()
        let model = FileListModel(projectRoot: root, keyStore: store)
        await model.refresh()

        let file = try #require(model.files.first)
        #expect(!file.isReadOnly)
    }

    /// The other half of the conservatism `isReadOnly`'s own doc comment
    /// requires: **with a session key configured**, a file whose own
    /// recipient metadata cannot be read (empty, unparseable, a shape this
    /// app does not recognise) must still not be flagged read-only — an
    /// empty `recipients` list is "unknown", never "this file protects
    /// nobody". This is the one branch review flagged as untested: every
    /// other `isReadOnly` fixture in this file populates a real recipient,
    /// so nothing before this test could fail if the `!recipients.isEmpty`
    /// guard were deleted from `FileListView.swift`'s `isReadOnly` helper.
    ///
    /// Verified by ablation, not merely inspection: temporarily removing
    /// that guard (`guard !recipients.isEmpty else { return false }`) makes
    /// this test fail (`empty recipients would otherwise be treated as
    /// "session key not in empty list" → true`) while every other test in
    /// this suite keeps passing — see the fix's own report for the exact
    /// commands run.
    @Test("a file with no readable recipients is not read-only, even with a session key configured")
    func unreadableRecipientsAreNotReadOnlyEvenWithAKeyConfigured() async throws {
        let mine = try AgeKeyPair.generate()
        let root = try makeProject()
        try writeSopsLikeWithNoRecipients(root, at: "unknown.yaml")

        let store = SessionKeyStore()
        try store.importKey(mine.private)
        let model = FileListModel(projectRoot: root, keyStore: store)
        await model.refresh()

        let file = try #require(model.files.first)
        #expect(!file.isReadOnly, "unreadable/empty recipient metadata must never be read as read-only")
    }
}
