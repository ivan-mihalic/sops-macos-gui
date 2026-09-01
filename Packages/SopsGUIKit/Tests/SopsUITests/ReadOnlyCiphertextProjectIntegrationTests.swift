import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

// MARK: - Task 5 (SOPS-38 phase F3): the read-only ciphertext chain, end to end
//
// `FourFormatProjectIntegrationTests` (F2 task 6) and
// `MomentakShapedDotenvIntegrationTests` (F1 task 10) each proved their own
// phase's seams still agree with each other once chained — scan → list →
// open → edit → save → access apply. Neither project had a file the session
// could not open: every fixture in both was encrypted for a key the session
// held. Phase F3 added a state neither of those chains ever exercises —
// `ListedFile.isReadOnly` (T1) and `LoadState.readOnlyCiphertext` (T1) feeding
// `CiphertextReadOnlyView` (T2) — and every existing test proves each seam in
// isolation, with hand-written fixtures (`FileListModelTests`) or an
// in-memory `readFile` override (`CiphertextReadOnlyViewTests`), never a real
// project scanned from disk with both a readable and an unreadable file
// sitting side by side.
//
// This is that missing chain: a project with one file encrypted only for a
// foreign key and one encrypted for the session's own key, both formats sops
// actually produces text metadata for (yaml and dotenv — `FileListModel`'s
// `isReadOnly` reads recipients through `EncryptedFileMetadata`, which only
// recognises yaml/json/ini/dotenv's own comment-header shape). Real bridge
// encryption throughout — no hand-written ciphertext — so the recipients this
// test reads back come from the same metadata parser the app itself uses on
// real sops output.
//
// What it proves that nothing upstream does together:
//   1. scan → FileListModel marks the foreign file isReadOnly == true and the
//      session's own file isReadOnly == false, in the same project, in the
//      same refresh() — not two separate single-file fixtures.
//   2. open the foreign file → SecretDocumentViewModel.load() reaches
//      .readOnlyCiphertext with a non-empty reason, rawCiphertext that is
//      byte-identical to what refresh() just scanned off disk (not a
//      re-derived or re-read copy), and recipients naming exactly the
//      foreign key — the metadata `isReadOnly` used to flag the file and the
//      metadata the editor reports once opened must agree.
//   3. that state has no path to mutation — addRow, save and removeRow all
//      refuse, mirroring `CiphertextReadOnlyViewTests.modelRefusesEveryMutation`
//      but now over a file that came from a real scanned project rather than
//      a synthetic `readFile` closure.
//   4. the session's own file, scanned and listed right alongside the
//      unreadable one, opens, edits and saves completely normally — the
//      read-only state is per file, never contagious to the rest of the
//      project.
//
// Both format variants the brief calls out (yaml and dotenv) run as two
// `@Test` cases sharing one project-building helper, rather than one test
// asserting both, so a failure in one format's chain does not hide whether
// the other format's chain also failed.

private struct ReadOnlyFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct ReadOnlyAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> ReadOnlyAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw ReadOnlyFixtureError("age-keygen not found in \(candidates)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw ReadOnlyFixtureError("age-keygen produced no usable key pair")
        }
        return ReadOnlyAgeKeyPair(private: priv, public: pub)
    }
}

private func readOnlyScratchDirectory(_ label: String = "readonly-ciphertext-project") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Task 5 integration — a project with a foreign-key file, scan through the read-only view")
@MainActor
struct ReadOnlyCiphertextProjectIntegrationTests {

    /// Builds a project with two files of `format`: one encrypted only for
    /// `stranger` (never openable this session), one encrypted for `owner`
    /// (whose key is imported into the returned `SessionKeyStore`). Returns
    /// everything a caller needs to drive the rest of the chain without
    /// re-deriving fixture paths or plaintext.
    private func makeMixedAccessProject(
        format: SopsFileFormat, foreignName: String, ownName: String, foreignPlain: String, ownPlain: String
    ) throws -> (
        root: URL, foreignURL: URL, ownURL: URL, owner: ReadOnlyAgeKeyPair, stranger: ReadOnlyAgeKeyPair,
        keyStore: SessionKeyStore
    ) {
        let owner = try ReadOnlyAgeKeyPair.generate()
        let stranger = try ReadOnlyAgeKeyPair.generate()
        let root = try readOnlyScratchDirectory()

        // A flat `age:` rule naming the owner — new-file creation is not
        // under test here, but a project this app can classify at all still
        // needs a config, matching every other integration fixture in this
        // suite.
        let configText = """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)

            """
        try configText.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let foreignURL = root.appendingPathComponent(foreignName)
        let ownURL = root.appendingPathComponent(ownName)
        try SopsBridge.encrypt(foreignPlain, format: format, recipients: [stranger.public])
            .write(to: foreignURL, atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(ownPlain, format: format, recipients: [owner.public])
            .write(to: ownURL, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)

        return (root, foreignURL, ownURL, owner, stranger, keyStore)
    }

    /// Asserts the mutation-refusal contract `CiphertextReadOnlyViewTests
    /// .modelRefusesEveryMutation` proves in isolation, here against a model
    /// that came out of a real scanned project rather than a synthetic
    /// `readFile` closure.
    private func assertRefusesEveryMutation(_ model: SecretDocumentViewModel) async {
        #expect(model.rows.isEmpty, "precondition: nothing to select, add into or remove")

        let addOutcome = model.addRow(
            in: SecretDocumentViewModel.AddDestination(document: 0, parent: [], isList: false),
            key: "new_key", kind: .string, value: "value")
        #expect(addOutcome == .refused(.notLoaded),
                "addRow must refuse over a document that was never decrypted, got \(addOutcome)")

        let saveOutcome = await model.save()
        guard case .failed = saveOutcome else {
            Issue.record("save() must refuse over a document that was never decrypted, got \(saveOutcome)")
            return
        }

        model.removeRow(id: "does-not-exist")
        #expect(model.rows.isEmpty)
        #expect(!model.isDirty)
    }

    @Test(
        "yaml: scan flags the foreign file read-only and lists the owner's own file as writable; opening the foreign file reaches .readOnlyCiphertext with matching disk bytes and no mutation path, while the owner's own file opens and edits normally"
    )
    func yamlVariant() async throws {
        let fixture = try makeMixedAccessProject(
            format: .yaml, foreignName: "theirs.yaml", ownName: "mine.yaml",
            foreignPlain: "database:\n    password: theirs-original\n",
            ownPlain: "database:\n    password: mine-original\n")

        // Step 1: scan → FileListModel flags each file independently.
        let fileList = FileListModel(projectRoot: fixture.root, keyStore: fixture.keyStore)
        await fileList.refresh()
        #expect(fileList.files.count == 2)
        let listedForeign = try #require(fileList.files.first { $0.url.lastPathComponent == "theirs.yaml" })
        let listedOwn = try #require(fileList.files.first { $0.url.lastPathComponent == "mine.yaml" })
        #expect(listedForeign.format == .yaml)
        #expect(listedOwn.format == .yaml)
        #expect(listedForeign.isReadOnly, "a file encrypted only for a foreign key must be flagged read-only")
        #expect(!listedOwn.isReadOnly, "the session's own file must not be flagged read-only")

        // Step 2: open the foreign file at the format and URL the list
        // handed back — matching how `ProjectWorkspaceView.activateFile`
        // drives this in the real app.
        let onDiskForeign = try String(contentsOf: fixture.foreignURL, encoding: .utf8)
        let foreignEditor = SecretDocumentViewModel(
            fileURL: listedForeign.url, format: listedForeign.format, keyStore: fixture.keyStore)
        await foreignEditor.load()
        guard case .readOnlyCiphertext(let reason, let rawCiphertext, let recipients) = foreignEditor.loadState
        else {
            Issue.record("expected .readOnlyCiphertext, got \(foreignEditor.loadState)")
            return
        }
        #expect(!reason.isEmpty, "a read-only ciphertext document must state why")
        #expect(rawCiphertext == onDiskForeign, "the raw ciphertext shown must be exactly what is on disk")
        #expect(recipients == [fixture.stranger.public], "recipients must name exactly the foreign key")

        // Step 3: no mutation path exists over that state.
        await assertRefusesEveryMutation(foreignEditor)

        // Step 4: the owner's own file, scanned and listed right alongside
        // the unreadable one, opens and edits completely normally — the
        // read-only state is per file, not contagious.
        let ownEditor = SecretDocumentViewModel(
            fileURL: listedOwn.url, format: listedOwn.format, keyStore: fixture.keyStore)
        await ownEditor.load()
        #expect(ownEditor.loadState == .loaded)
        let ownRow = try #require(ownEditor.rows.first { $0.path == ["database", "password"] })
        #expect(ownRow.value == "mine-original")
        ownEditor.update(rowID: ownRow.id, to: "mine-rotated")
        #expect(ownEditor.isDirty)
        #expect(await ownEditor.save() == .saved)
        #expect(!ownEditor.isDirty)

        let ownAfterSave = try SopsBridge.decrypt(
            try String(contentsOf: fixture.ownURL, encoding: .utf8), format: .yaml, agePrivateKey: fixture.owner.private)
        #expect(ownAfterSave.contains("mine-rotated"))

        // And the foreign file the whole test opened as read-only never
        // moved — no path through this chain touched its bytes.
        #expect(try String(contentsOf: fixture.foreignURL, encoding: .utf8) == onDiskForeign)
    }

    @Test(
        "dotenv: the same read-only chain — flagged in the list, .readOnlyCiphertext with matching disk bytes and recipients on open, no mutation path, own file unaffected"
    )
    func dotenvVariant() async throws {
        let fixture = try makeMixedAccessProject(
            format: .dotenv, foreignName: ".env.theirs", ownName: ".env.mine",
            foreignPlain: "DB_PASSWORD=theirs-original\n",
            ownPlain: "DB_PASSWORD=mine-original\n")

        let fileList = FileListModel(projectRoot: fixture.root, keyStore: fixture.keyStore)
        await fileList.refresh()
        #expect(fileList.files.count == 2)
        let listedForeign = try #require(fileList.files.first { $0.url.lastPathComponent == ".env.theirs" })
        let listedOwn = try #require(fileList.files.first { $0.url.lastPathComponent == ".env.mine" })
        #expect(listedForeign.format == .dotenv)
        #expect(listedOwn.format == .dotenv)
        #expect(listedForeign.isReadOnly, "a file encrypted only for a foreign key must be flagged read-only")
        #expect(!listedOwn.isReadOnly, "the session's own file must not be flagged read-only")

        let onDiskForeign = try String(contentsOf: fixture.foreignURL, encoding: .utf8)
        let foreignEditor = SecretDocumentViewModel(
            fileURL: listedForeign.url, format: listedForeign.format, keyStore: fixture.keyStore)
        await foreignEditor.load()
        guard case .readOnlyCiphertext(let reason, let rawCiphertext, let recipients) = foreignEditor.loadState
        else {
            Issue.record("expected .readOnlyCiphertext, got \(foreignEditor.loadState)")
            return
        }
        #expect(!reason.isEmpty, "a read-only ciphertext document must state why")
        #expect(rawCiphertext == onDiskForeign, "the raw ciphertext shown must be exactly what is on disk")
        #expect(recipients == [fixture.stranger.public], "recipients must name exactly the foreign key")

        await assertRefusesEveryMutation(foreignEditor)

        let ownEditor = SecretDocumentViewModel(
            fileURL: listedOwn.url, format: listedOwn.format, keyStore: fixture.keyStore)
        await ownEditor.load()
        #expect(ownEditor.loadState == .loaded)
        let ownRow = try #require(ownEditor.rows.first { $0.path == ["DB_PASSWORD"] })
        #expect(ownRow.value == "mine-original")
        ownEditor.update(rowID: ownRow.id, to: "mine-rotated")
        #expect(ownEditor.isDirty)
        #expect(await ownEditor.save() == .saved)
        #expect(!ownEditor.isDirty)

        let ownAfterSave = try SopsBridge.decrypt(
            try String(contentsOf: fixture.ownURL, encoding: .utf8), format: .dotenv, agePrivateKey: fixture.owner.private)
        #expect(ownAfterSave.contains("DB_PASSWORD=mine-rotated"))

        #expect(try String(contentsOf: fixture.foreignURL, encoding: .utf8) == onDiskForeign)
    }
}
