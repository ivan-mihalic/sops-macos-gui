import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

private let sopsBinary = ["/opt/homebrew/bin/sops", "/usr/local/bin/sops", "/usr/bin/sops"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

private let needsSopsCLI = Comment(
    rawValue: "needs the real sops binary: the JSON and INI stores are not reachable through this app's bridge (YAML and dotenv only, as of Task 5/SOPS-38), so the only honest fixture for them is output the shipping sops actually wrote")

/// PROPOSAL.md §3 metadata sniffing, second finding of the Task 14 brief.
///
/// `ProjectScanner` finds encrypted files by searching every file's tail for a
/// substring. Run against this app's own repository that misclassified eleven
/// files: two Markdown task reports quoting a `sops:` block were offered as
/// *openable encrypted files*, and nine more — review diffs, Swift tests, Go
/// tests, briefs — were counted as "sops-encrypted in a format this app does
/// not read", every one of them on ordinary code (`["sops": tool(…)]`,
/// `Data("sops_mac=".utf8)`; the sniffer was flagging its own source).
///
/// The two halves of this suite pull in opposite directions on purpose, and
/// both have to hold at once:
///
/// - **Nothing sops wrote may stop being recognised.** A false negative is the
///   dangerous direction: a sops-encrypted `.env` that is no longer seen as
///   encrypted becomes a plaintext-leak `.problem` about a file that is not
///   leaking. Fixtures for that half are produced by the real `sops` binary or
///   the real in-process bridge, never hand-typed.
/// - **Nothing that merely mentions sops may be recognised.** Fixtures for
///   that half are the literal shapes found in this repository.
@Suite("sops metadata shape")
struct SopsMetadataShapeTests {

    private func scanOne(_ name: String, _ contents: String) async throws -> ScannedTree {
        let root = try ProjectFixture.makeDirectory("sniff")
        try ProjectFixture.write(contents, to: root, at: name)
        defer { try? FileManager.default.removeItem(at: root) }
        return await ProjectScanner.scan(root: root)
    }

    /// `sops -e` on a document of the given format, as text.
    private func sopsEncrypted(_ plain: String, extension ext: String) throws -> String {
        let sops = try #require(sopsBinary)
        let dir = try ProjectFixture.makeDirectory("sops-cli")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("doc.\(ext)")
        try plain.write(to: file, atomically: true, encoding: .utf8)
        let key = try ProjectFixture.ageKeyPair()
        return try ProjectFixture.run(sops, ["-e", "--age", key.public, file.path])
    }

    // MARK: - Nothing sops wrote may stop being recognised

    @Test("a real sops YAML file is still recognised as encrypted")
    func realYAMLIsStillEncrypted() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let cipherText = try ProjectFixture.encrypted("db_password: hunter2\n", to: [key.public])

        let tree = try await scanOne("secrets.yaml", cipherText)

        #expect(tree.encrypted.count == 1)
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: tree.encrypted[0].tail) == [key.public])
    }

    /// A file whose *entire* content is the metadata block — `sops -e` over an
    /// empty document. There is no `\nsops:` in it at all, only the `sops:`
    /// prefix, which is the case `ProjectScanner.sopsBlockPrefix` exists for
    /// and the one a structural check is most likely to break by accident.
    @Test("a sops file that is nothing but its metadata block is still recognised")
    func metadataOnlyFileIsStillEncrypted() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let cipherText = try ProjectFixture.encrypted("{}\n", to: [key.public])

        let tree = try await scanOne("empty.yaml", cipherText)

        #expect(tree.encrypted.count == 1, "got: encrypted=\(tree.encrypted.count) other=\(tree.encryptedInOtherFormats.count)")
    }

    /// The dangerous direction, stated as its own test: a sops-encrypted
    /// `.env` must never fall through to the plaintext-leak finding.
    ///
    /// Uses the real in-process bridge, not the CLI (unlike the JSON/INI
    /// tests below) — the dotenv store has been reachable through
    /// `SopsBridge.encrypt(_:format:.dotenv:recipients:)` since Task 4, so a
    /// bridge-produced fixture is both the honest fixture (real sops output,
    /// same requirement as the JSON/INI tests) *and* one that doesn't need
    /// the CLI to exist on the machine running the suite.
    ///
    /// Task 5 (SOPS-38): a dotenv sops file is now a *verifiable* encrypted
    /// file — `tree.encrypted`, not `tree.encryptedInOtherFormats` — because
    /// `EncryptedFileMetadata` learned the dotenv metadata shape alongside
    /// this scanner change. See `EncryptedFileMetadataDotenvTests.swift`.
    @Test("a real sops dotenv file is recognised as encrypted, not as another format")
    func realDotenvIsRecognised() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let cipherText = try ProjectFixture.encryptedDotenv("DB_PASSWORD=hunter2\n", to: [key.public])

        let tree = try await scanOne(".env", cipherText)

        #expect(tree.encrypted.count == 1,
                "got: encrypted=\(tree.encrypted.count) other=\(tree.encryptedInOtherFormats.count)")
        #expect(tree.encrypted.first?.format == .dotenv)
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(tree.plaintextCandidates.isEmpty, "an encrypted .env is not a plaintext leak")
    }

    @Test("a real sops JSON file is recognised", .enabled(if: sopsBinary != nil, needsSopsCLI))
    func realJSONIsRecognised() async throws {
        let cipherText = try sopsEncrypted("{\"db\": \"hunter2\"}", extension: "json")

        let tree = try await scanOne("secrets.json", cipherText)

        #expect(tree.encryptedInOtherFormats.count == 1)
    }

    @Test("a real sops INI file is recognised", .enabled(if: sopsBinary != nil, needsSopsCLI))
    func realINIIsRecognised() async throws {
        let cipherText = try sopsEncrypted("[db]\npassword=hunter2\n", extension: "ini")

        let tree = try await scanOne("secrets.ini", cipherText)

        #expect(tree.encryptedInOtherFormats.count == 1)
    }

    // MARK: - Nothing that merely mentions sops may be recognised

    /// The visible wrong answer: a Markdown report quoting a complete sops
    /// metadata block inside a fenced code example, offered to the user as a
    /// decryptable secrets file. The quoted block here is a real one, so the
    /// only thing separating it from a genuine file is that the document
    /// carries on afterwards — which is exactly the structural fact sops
    /// guarantees and prose does not.
    @Test("a Markdown report quoting a sops block is not an encrypted file")
    func quotedBlockInMarkdownIsNotEncrypted() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let real = try ProjectFixture.encrypted("db_password: hunter2\n", to: [key.public])
        let report = """
            # Task 11 report

            The file on disk ends up looking like this:

            ```yaml
            \(real)
            ```

            Which is what the check reads its recipients out of.
            """

        let tree = try await scanOne("task-11-report.md", report)

        #expect(tree.encrypted.isEmpty,
                "a report quoting a sops block must not be offered as an openable encrypted file")
        #expect(tree.encryptedInOtherFormats.isEmpty)
    }

    /// A dictionary literal in Swift, and a map literal in Go — the shape
    /// behind eight of this repository's nine "format this app does not read"
    /// miscounts.
    @Test("a source file with a \"sops\" dictionary key is not an encrypted file",
          arguments: [
            "            locator: FakeLocator(tools: [\"sops\": tool(\"sops\", SemanticVersion(3, 13, 2))]),",
            "\tfor name, got := range map[string]string{\"sops\": sopsVersion, \"age\": ageVersion} {",
            "+            locator: FakeLocator(tools: [\"sops\": tool(\"sops\", SemanticVersion(3, 13, 3))]),",
          ])
    func sopsDictionaryKeyIsNotEncrypted(line: String) async throws {
        let tree = try await scanOne("Source.swift", "import Foundation\n\(line)\n// trailing\n")

        #expect(tree.encrypted.isEmpty)
        #expect(tree.encryptedInOtherFormats.isEmpty)
    }

    /// The sniffer flagging its own source. This is the literal line from
    /// `ProjectScanner`'s marker table.
    @Test("the scanner's own marker table is not an encrypted file")
    func markerTableIsNotEncrypted() async throws {
        let source = """
            private static let dotenvMacMarker = Data("sops_mac=".utf8)
            private static let dotenvVersionMarker = Data("sops_version=".utf8)
            private static let jsonMarker = Data("\\"sops\\":".utf8)
            """

        let tree = try await scanOne("ProjectScanner.swift", source)

        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(tree.encrypted.isEmpty)
    }

    /// A YAML document of the user's own that legitimately has a top-level
    /// `sops:` key — configuration for something else entirely — followed by
    /// more of the user's own keys. Not encrypted, and not metadata.
    @Test("a user's own top-level sops: key followed by other keys is not metadata")
    func unrelatedTopLevelSopsKeyIsNotMetadata() async throws {
        let doc = """
            sops:
                binary: /opt/homebrew/bin/sops
            deploy:
                target: staging
            """

        let tree = try await scanOne("tooling.yaml", doc)

        #expect(tree.encrypted.isEmpty)
    }

    /// The standing guard, run against the real thing rather than a fixture:
    /// this package's own `Sources/` tree contains every marker the scanner
    /// looks for, in the very file that defines them, and it contains no sops-
    /// encrypted files at all. If a single one is classified, the sniffer is
    /// reading prose again.
    ///
    /// Worth having as a live test rather than a one-off check, because it
    /// caught the fix's own regression: the first draft of
    /// `SopsMetadataShape`'s doc comment illustrated all four store formats
    /// with pasted literal examples, and the JSON one — a `sops` key followed
    /// by a brace, with `mac` and `version` nearby — made that file the
    /// twelfth false positive on this repository. A comment is prose no matter
    /// which file it sits in.
    @Test("the app never classifies its own source tree as encrypted")
    func ownSourceTreeIsNotEncrypted() async throws {
        // …/Tests/SopsHealthTests/<this file> → …/Sources
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SopsHealthTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SopsGUIKit
            .appendingPathComponent("Sources")
        #expect(FileManager.default.fileExists(atPath: sources.path),
                "sanity: expected this package's Sources at \(sources.path)")

        let tree = await ProjectScanner.scan(root: sources)

        #expect(tree.encrypted.map(\.url.lastPathComponent) == [])
        #expect(tree.encryptedInOtherFormats.map(\.lastPathComponent) == [])
    }

    // MARK: - The predicate directly, for the boundary cases

    @Test("a sops block missing mac or version is not metadata")
    func incompleteBlockIsNotMetadata() {
        #expect(!SopsMetadataShape.isYAMLMetadata("sops:\n    version: 3.13.3\n"))
        #expect(!SopsMetadataShape.isYAMLMetadata("sops:\n    mac: ENC[AES256_GCM,data:x]\n"))
        #expect(SopsMetadataShape.isYAMLMetadata("sops:\n    mac: ENC[AES256_GCM,data:x]\n    version: 3.13.3\n"))
    }

    /// `mac_only_encrypted` is a real sops option name and must not be read as
    /// the `mac` key.
    @Test("a key that merely starts with mac does not satisfy the mac requirement")
    func macPrefixedKeyIsNotMac() {
        #expect(!SopsMetadataShape.isYAMLMetadata(
            "sops:\n    mac_only_encrypted: true\n    version: 3.13.3\n"))
    }

    /// CRLF line endings must not silently turn a real file into an
    /// unrecognised one — the substring matching this replaced did not care
    /// about them, so neither may the structural check.
    @Test("CRLF line endings do not hide a real metadata block")
    func crlfIsTolerated() {
        #expect(SopsMetadataShape.isYAMLMetadata(
            "data: ENC[x]\r\nsops:\r\n    mac: ENC[y]\r\n    version: 3.13.3\r\n"))
    }

    // MARK: - nonYAMLKind, the disambiguated form

    /// Real dotenv metadata, as `SopsBridge.encrypt(_:format:.dotenv:...)`
    /// actually writes it — see `EncryptedFileMetadataDotenvTests.swift` for
    /// where this exact shape was verified against the real bridge.
    @Test("nonYAMLKind reads real dotenv metadata as .dotenv")
    func nonYAMLKindReadsDotenv() throws {
        let key = try ProjectFixture.ageKeyPair()
        let cipherText = try ProjectFixture.encryptedDotenv("FOO=bar\n", to: [key.public])

        #expect(SopsMetadataShape.nonYAMLKind(cipherText) == .dotenv)
    }

    @Test("nonYAMLKind reads a sops JSON document as .json")
    func nonYAMLKindReadsJSON() {
        let json = """
            {"password":"ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]","sops":{"mac":"ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]","version":"3.13.3"}}
            """
        #expect(SopsMetadataShape.nonYAMLKind(json) == .json)
    }

    @Test("nonYAMLKind reads a sops INI document as .ini")
    func nonYAMLKindReadsINI() {
        let ini = """
            [db]
            password = ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
            [sops]
            mac     = ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version = 3.13.3
            """
        #expect(SopsMetadataShape.nonYAMLKind(ini) == .ini)
    }

    @Test("nonYAMLKind is nil for a YAML sops file and for ordinary text")
    func nonYAMLKindIsNilOtherwise() throws {
        let key = try ProjectFixture.ageKeyPair()
        let yaml = try ProjectFixture.encrypted("db_password: hunter2\n", to: [key.public])
        #expect(SopsMetadataShape.nonYAMLKind(yaml) == nil)
        #expect(SopsMetadataShape.nonYAMLKind("just some prose, no sops metadata here\n") == nil)
    }

    /// `isNonYAMLMetadata` must keep agreeing with `nonYAMLKind` now that the
    /// former is implemented in terms of the latter — a boolean caller must
    /// see exactly the same answer it always did.
    @Test("isNonYAMLMetadata still agrees with nonYAMLKind")
    func isNonYAMLMetadataAgreesWithKind() throws {
        let key = try ProjectFixture.ageKeyPair()
        let dotenv = try ProjectFixture.encryptedDotenv("FOO=bar\n", to: [key.public])
        let yaml = try ProjectFixture.encrypted("db_password: hunter2\n", to: [key.public])

        #expect(SopsMetadataShape.isNonYAMLMetadata(dotenv))
        #expect(!SopsMetadataShape.isNonYAMLMetadata(yaml))
        #expect(!SopsMetadataShape.isNonYAMLMetadata("just prose\n"))
    }
}

/// The two readings of "which `sops:` block is the metadata" must agree.
///
/// `SopsMetadataShape.isYAMLMetadata` takes the last; `EncryptedFileMetadata`
/// used to take the first. A user key named `sops` at the top level split them
/// apart, and the app then accused a correct file of missing its own recipient.
@Suite("The metadata block is found the same way everywhere")
struct SopsBlockAgreementTests {

    /// A real shape: a project that stores sops-related settings under its own
    /// `sops:` key, with the actual metadata block below it as sops writes it.
    private static let documentWithAUserKeyNamedSops = """
        sops:
          note: this is the user's own key, not the metadata block
        db:
            password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            age:
                - recipient: age1realrecipientvaluegoeshere00000000000000000000000000
                  enc: |
                    -----BEGIN AGE ENCRYPTED FILE-----
                    -----END AGE ENCRYPTED FILE-----
            lastmodified: "2026-08-09T00:00:00Z"
            mac: ENC[AES256_GCM,data:mac,iv:iv,tag:tag,type:str]
            version: 3.13.2
        """

    @Test("a user key named sops does not hide the real recipient list")
    func userKeyNamedSopsDoesNotShadowTheMetadata() {
        let recipients = EncryptedFileMetadata.recipients(
            inEncryptedFile: Self.documentWithAUserKeyNamedSops)
        #expect(
            recipients.contains("age1realrecipientvaluegoeshere00000000000000000000000000"),
            "the recipient list came back empty, so the health check would report this correct file as missing its own key")
    }

    @Test("both readings agree that this file is encrypted")
    func bothReadingsAgree() {
        #expect(SopsMetadataShape.isYAMLMetadata(Self.documentWithAUserKeyNamedSops))
        #expect(
            !EncryptedFileMetadata.recipients(
                inEncryptedFile: Self.documentWithAUserKeyNamedSops).isEmpty)
    }
}
