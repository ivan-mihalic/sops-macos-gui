import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

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

    /// SOPS-38 phase F2 task 3: JSON now reaches the real in-process bridge
    /// (F2 task 2), and `EncryptedFileMetadata` learned its metadata shape
    /// alongside this scanner change — so a JSON sops file is now
    /// *verifiable*, `tree.encrypted`, not `tree.encryptedInOtherFormats`.
    /// Mirrors `realDotenvIsRecognised` above; the CLI-only fixture this
    /// test used before F2 task 3 is retired in favour of the bridge, the
    /// same real-fixture standard the rest of this suite already holds
    /// dotenv to.
    @Test("a real sops JSON file is recognised as encrypted, not as another format")
    func realJSONIsRecognised() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let cipherText = try ProjectFixture.encryptedJSON("{\"db\": \"hunter2\"}", to: [key.public])

        let tree = try await scanOne("secrets.json", cipherText)

        #expect(tree.encrypted.count == 1,
                "got: encrypted=\(tree.encrypted.count) other=\(tree.encryptedInOtherFormats.count)")
        #expect(tree.encrypted.first?.format == .json)
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: tree.encrypted[0].tail) == [key.public])
    }

    /// See `realJSONIsRecognised`'s doc comment — same change, INI side.
    @Test("a real sops INI file is recognised as encrypted, not as another format")
    func realINIIsRecognised() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let cipherText = try ProjectFixture.encryptedINI("[db]\npassword=hunter2\n", to: [key.public])

        let tree = try await scanOne("secrets.ini", cipherText)

        #expect(tree.encrypted.count == 1,
                "got: encrypted=\(tree.encrypted.count) other=\(tree.encryptedInOtherFormats.count)")
        #expect(tree.encrypted.first?.format == .ini)
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(EncryptedFileMetadata.recipients(inEncryptedFile: tree.encrypted[0].tail) == [key.public])
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

    /// SOPS-38 phase F2 task 3 review finding: `isJSONMetadata` used to check
    /// only "does `mac` appear anywhere, does `version` appear anywhere, does
    /// `sops` appear anywhere followed by `{` anywhere" — three independent
    /// substring searches with no requirement that `mac`/`version` actually
    /// sit *inside* that `sops` object. An ordinary JSON document that
    /// happens to have its own top-level `mac`/`version` fields (a device
    /// inventory record is a completely ordinary shape for that) alongside
    /// an unrelated top-level `sops` object satisfied all three independently
    /// and was classified as an encrypted file — the exact class of bug
    /// `SopsMetadataShape`'s own doc comment already names for YAML and Go
    /// map literals, just not yet closed for JSON. Once classified, this
    /// task's own scanner change routes it into `tree.encrypted`, so the app
    /// would show it as an openable secrets file that fails to decrypt.
    @Test("an ordinary JSON document with its own top-level mac/version fields is not an encrypted file")
    func deviceInventoryJSONIsNotEncrypted() async throws {
        let tree = try await scanOne(
            "device.json",
            """
            {"mac": "00:11:22:33:44:55", "version": "1.0", "sops": {"foo": "bar"}}
            """)

        #expect(tree.encrypted.isEmpty,
                "an ordinary record with sibling mac/version/sops fields must not be offered as an openable encrypted file")
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(SopsMetadataShape.nonYAMLKind("""
            {"mac": "00:11:22:33:44:55", "version": "1.0", "sops": {"foo": "bar"}}
            """) == nil)
    }

    /// The decision this task's review asked to be made explicit: a JSON
    /// tail that cannot even be parsed — the shape a truncated read produces
    /// when a document's own sops metadata sits past `maxSniffedFileBytes`
    /// and the wider re-read in `ProjectScanner.classify` still doesn't
    /// reach far enough back to include the opening `{` — is honestly *not*
    /// detected as JSON metadata, rather than guessed at from whatever
    /// substrings happen to survive the cut. This is the same "cannot verify
    /// structurally, so do not guess" posture `isYAMLMetadata` already takes
    /// (a document that ends mid-block fails its own `mac`/`version`
    /// requirement) — the two now agree, even though YAML's own structural
    /// check can partially work on a tail that starts mid-document (it only
    /// ever looks at lines from `sops:` onward) while JSON's cannot (a
    /// document is one value, and half of one does not parse). The real
    /// mitigation for the false negative this implies is
    /// `ProjectScanner.looksLikeTruncatedSopsBlock` now recognising JSON's
    /// own near-tail shape too, so a legitimately oversized encrypted JSON
    /// file gets the same wider-read chance YAML already had — see
    /// `oversizedJSONMetadataBlockIsNotInvisible` below for the case that
    /// exercises this end to end, and `ProjectScanner.classify`'s own doc
    /// comment for how a still-truncated result becomes
    /// `.metadataBlockTooLarge` rather than silence.
    @Test("a JSON tail truncated before its own opening brace is not detected as metadata, not guessed at")
    func truncatedJSONTailIsNotMetadata() {
        // The tail end of a real document — starts mid-string, never opens
        // the top-level object at all. Carries `"mac":`/`"version":` inside
        // the `sops` object, exactly as a real file would; the only thing
        // missing is the document's own opening `{`.
        let truncatedTail = """
            some-trailing-plaintext-value","sops":{"age":[{"recipient":"age1x","enc":"..."}],"mac":"ENC[...]","version":"3.13.3"}}
            """
        #expect(SopsMetadataShape.nonYAMLKind(truncatedTail) == nil,
                "a tail that cannot parse as JSON at all must not be guessed at from its surviving substrings")
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

/// SOPS-38 phase F3 task 4 (F2 review M4): `isYAMLMetadata`/`isINIMetadata`
/// (and, for symmetry, the JSON and dotenv readings inside `nonYAMLKind`)
/// used to require only that a `mac` *key* be present, never that its
/// *value* carry the shape sops's own MAC actually has. A plaintext file
/// that merely quotes or hand-writes a `[sops]`/`sops:` section with
/// ordinary-looking `mac`/`version` entries — not a real sops document —
/// satisfied every check this file already had and was classified as
/// encrypted.
///
/// F3 context for why this matters now, not merely in principle: F3's new
/// read-only "ciphertext" editor view (`ReadOnlyCiphertextDetector`) trusts
/// this classification to decide whether a file opens in that view at all.
/// A false positive here does not just mislabel a row in the file list —
/// it opens a plaintext file in a view that confidently tells the user it
/// is looking at ciphertext.
///
/// The fix anchors every format's `mac` check on the one shape sops's own
/// serializer writes unconditionally in every store: the value always
/// starts with `ENC[` (`ENC[AES256_GCM,data:…,iv:…,tag:…,type:str]` in
/// every store this app produces or reads). Verified against the real
/// in-process bridge for all four formats, captured once by hand against
/// `SopsBridge.encrypt` for each `SopsFileFormat`:
/// ```
/// YAML:   mac: ENC[AES256_GCM,data:…]
/// dotenv: sops_mac=ENC[AES256_GCM,data:…]
/// JSON:   "mac": "ENC[AES256_GCM,data:…]"
/// INI:    mac                         = ENC[AES256_GCM,data:…]
/// ```
///
/// No truncation hazard: `ProjectScanner.tailBytes(of:maxBytes:)` always
/// reads a *suffix* of the file ending at its true end-of-file
/// (`offset = size - readSize`), never a middle slice. Every one of these
/// four checks only asks about the `mac` line/entry *after* it has already
/// located the block's own header (YAML's `sops:` line, the INI `[sops]`
/// header, JSON's `sops` key, dotenv's `sops_mac=` prefix) — and once that
/// header is found inside the tail, everything from there to the file's
/// real end is present in full, because the tail read never stops short of
/// EOF. So whenever any of these four checks decides a `mac` key is
/// present at all, that key's *value* is guaranteed complete too — the
/// widened re-read `ProjectScanner.classify`/`looksLikeTruncatedSopsBlock`
/// already perform for an oversized block (see `SopsMetadataShape`'s own
/// doc comment) exists to get the block's *header* into view, not to
/// protect a `mac` value that was already at risk of being cut off midway;
/// it never was.
@Suite("sops metadata mac value is anchored on ENC[, not merely present")
struct SopsMetadataShapeMACAnchorTests {

    private func scanOne(_ name: String, _ contents: String) async throws -> ScannedTree {
        let root = try ProjectFixture.makeDirectory("mac-anchor")
        try ProjectFixture.write(contents, to: root, at: name)
        defer { try? FileManager.default.removeItem(at: root) }
        return await ProjectScanner.scan(root: root)
    }

    // MARK: - Reproducing: a plaintext sops-shaped section with an
    // ordinary-looking (non-ENC[) mac must not classify, in any format

    @Test("a plaintext YAML sops: block with an ordinary mac value is not classified")
    func plaintextYAMLWithOrdinaryMACIsNotClassified() async throws {
        let doc = """
            db_password: not-actually-encrypted
            sops:
                age:
                    - recipient: age1exampleexampleexampleexampleexampleexampleexampleexamplex
                lastmodified: "2026-08-09T00:00:00Z"
                mac: not-a-real-mac-value
                version: 3.13.2
            """
        let tree = try await scanOne("plain.yaml", doc)

        #expect(tree.encrypted.isEmpty,
                "a mac value that is not sops's own ENC[…] shape must not be classified as encrypted")
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(!SopsMetadataShape.isYAMLMetadata(doc))
    }

    @Test("a plaintext INI [sops] section with an ordinary mac value is not classified")
    func plaintextINIWithOrdinaryMACIsNotClassified() async throws {
        let doc = """
            [data]
            password = not-actually-encrypted

            [sops]
            age__list_0__map_recipient = age1exampleexampleexampleexampleexampleexampleexampleexamplex
            lastmodified                = 2026-08-09T00:00:00Z
            mac                         = not-a-real-mac-value
            version                     = 3.13.2
            """
        let tree = try await scanOne("plain.ini", doc)

        #expect(tree.encrypted.isEmpty,
                "a mac value that is not sops's own ENC[…] shape must not be classified as encrypted")
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(SopsMetadataShape.nonYAMLKind(doc) == nil)
    }

    @Test("a plaintext JSON sops object with an ordinary mac value is not classified")
    func plaintextJSONWithOrdinaryMACIsNotClassified() async throws {
        let doc = """
            {"db_password": "not-actually-encrypted", "sops": {"mac": "not-a-real-mac-value", "version": "3.13.2"}}
            """
        let tree = try await scanOne("plain.json", doc)

        #expect(tree.encrypted.isEmpty,
                "a mac value that is not sops's own ENC[…] shape must not be classified as encrypted")
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(SopsMetadataShape.nonYAMLKind(doc) == nil)
    }

    @Test("a plaintext dotenv sops_ block with an ordinary mac value is not classified")
    func plaintextDotenvWithOrdinaryMACIsNotClassified() async throws {
        let doc = """
            DB_PASSWORD=not-actually-encrypted
            sops_age__list_0__map_recipient=age1exampleexampleexampleexampleexampleexampleexampleexamplex
            sops_lastmodified=2026-08-09T00:00:00Z
            sops_mac=not-a-real-mac-value
            sops_version=3.13.2
            """
        let tree = try await scanOne(".env.plain", doc)

        #expect(tree.encrypted.isEmpty,
                "a mac value that is not sops's own ENC[…] shape must not be classified as encrypted")
        #expect(tree.encryptedInOtherFormats.isEmpty)
        #expect(SopsMetadataShape.nonYAMLKind(doc) == nil)
    }

    // MARK: - Nothing sops actually wrote may stop being recognised — the
    // real bridge fixture, all four formats, must still classify after the
    // anchor is added. (Mirrors `realYAMLIsStillEncrypted` /
    // `realDotenvIsRecognised` / `realJSONIsRecognised` / `realINIIsRecognised`
    // above; kept here too as a direct regression pin right next to the
    // change that could break them.)

    @Test("a real bridge-encrypted file in every format still classifies as encrypted")
    func realBridgeFixturesStillClassifyInEveryFormat() async throws {
        let key = try ProjectFixture.ageKeyPair()

        let yaml = try ProjectFixture.encrypted("db_password: hunter2\n", to: [key.public])
        let dotenv = try ProjectFixture.encryptedDotenv("FOO=bar\n", to: [key.public])
        let json = try ProjectFixture.encryptedJSON("{\"db\": \"hunter2\"}", to: [key.public])
        let ini = try ProjectFixture.encryptedINI("[db]\npassword=hunter2\n", to: [key.public])

        #expect(SopsMetadataShape.isYAMLMetadata(yaml))
        #expect(SopsMetadataShape.nonYAMLKind(dotenv) == .dotenv)
        #expect(SopsMetadataShape.nonYAMLKind(json) == .json)
        #expect(SopsMetadataShape.nonYAMLKind(ini) == .ini)

        let yamlTree = try await scanOne("secrets.yaml", yaml)
        let dotenvTree = try await scanOne(".env", dotenv)
        let jsonTree = try await scanOne("secrets.json", json)
        let iniTree = try await scanOne("secrets.ini", ini)
        #expect(yamlTree.encrypted.count == 1)
        #expect(dotenvTree.encrypted.count == 1)
        #expect(jsonTree.encrypted.count == 1)
        #expect(iniTree.encrypted.count == 1)
    }

    // MARK: - The predicate directly, boundary cases

    @Test("isYAMLMetadata requires the mac value itself to start with ENC[, not merely the key to be present")
    func yamlMACValueMustStartWithENC() {
        #expect(!SopsMetadataShape.isYAMLMetadata(
            "sops:\n    mac: not-a-real-mac\n    version: 3.13.3\n"))
        #expect(SopsMetadataShape.isYAMLMetadata(
            "sops:\n    mac: ENC[AES256_GCM,data:x]\n    version: 3.13.3\n"))
    }

    @Test("a mac value that merely contains ENC[ later in the string does not satisfy the anchor")
    func yamlMACValueMustStartNotContainENC() {
        #expect(!SopsMetadataShape.isYAMLMetadata(
            "sops:\n    mac: not-really-ENC[fake]\n    version: 3.13.3\n"))
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
