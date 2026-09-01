import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

// MARK: - Task 6 (SOPS-38 phase F2): the whole four-format chain in one flow
//
// `MomentakShapedDotenvIntegrationTests` (F1 task 10) proved this app's seams
// still agree with each other for a two-file, dotenv-only project. Phase F2
// added JSON and INI as first-class formats (T1 bridge, T2 enum/cshim, T3
// scanner/metadata, T4 editor, T5 creation/access/copy), each proved in
// isolation, plus two apply-level fixtures that already cover all four
// formats at once —
// `ProjectRecipientApplierTests.mixedProjectRewrapsAllFourFormats` and
// `ProjectAccessTests.fileApplyRewrapsAllFourFormats`. Neither of those goes
// through `FileListModel` (the scan the file list actually shows) or
// `SecretDocumentViewModel` (the editor a user actually opens) for the new
// formats — this test is the missing piece: one project with all four
// formats, scanned, listed, opened, edited and saved through the real UI
// view models, then re-wrapped for a newly staged recipient through
// `ProjectAccessModel`, with every file independently decryptable by both
// the original and the added key afterwards.
//
// yaml and dotenv already have their own open+edit+save coverage
// (`MomentakShapedDotenvIntegrationTests` for dotenv;
// `SecretDocumentJSONCapabilityTests`/`SecretDocumentINICapabilityTests` — a
// sibling suite in `SecretDocumentViewModelTests.swift` — for json/ini in
// isolation). This test only re-edits json and ini; yaml and dotenv are
// opened and their rows asserted, but left untouched, so the apply step
// still has to prove it re-wraps content it never rewrote through the
// editor.
//
// Fixtures go through the real in-process bridge, never hand-written
// ciphertext. Only key generation shells out, because there is no
// in-process keygen.

private struct FourFormatFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct FourFormatAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> FourFormatAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw FourFormatFixtureError("age-keygen not found in \(candidates)")
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
            throw FourFormatFixtureError("age-keygen produced no usable key pair")
        }
        return FourFormatAgeKeyPair(private: priv, public: pub)
    }
}

private func fourFormatScratchDirectory(_ label: String = "four-format-project") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Task 6 integration — a four-format project, scan through access apply")
@MainActor
struct FourFormatProjectIntegrationTests {

    @Test(
        "scan classifies all four formats, editing the json and ini files saves through the editor, and Project Access re-wraps all four for a staged recipient — every intended key still opens every file"
    )
    func fullChainScanListOpenEditSaveAccessApplyDecrypt() async throws {
        let owner = try FourFormatAgeKeyPair.generate()
        let added = try FourFormatAgeKeyPair.generate()

        let root = try fourFormatScratchDirectory()

        // A single flat `age:` rule governing the whole tree — the shape
        // this app both reads and rewrites, so the config-write step is not
        // what is under test here (that is
        // `MomentakShapedDotenvIntegrationTests`' job, with its
        // `key_groups` refusal). What is under test is the four *file*
        // formats moving through one chain together.
        let configText = """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)

            """
        try configText.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let yamlPlain = "database:\n    password: correct-horse-battery-staple\n"
        let dotenvPlain = "DB_PASSWORD=hunter2\n"
        let jsonPlain = "{\"api_key\": \"json-original\"}\n"
        let iniPlain = "[db]\npassword = ini-original\n"

        let yamlURL = root.appendingPathComponent("secret.yaml")
        let dotenvURL = root.appendingPathComponent(".env")
        let jsonURL = root.appendingPathComponent("secret.json")
        let iniURL = root.appendingPathComponent("secret.ini")

        try SopsBridge.encrypt(yamlPlain, format: .yaml, recipients: [owner.public])
            .write(to: yamlURL, atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(dotenvPlain, format: .dotenv, recipients: [owner.public])
            .write(to: dotenvURL, atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(jsonPlain, format: .json, recipients: [owner.public])
            .write(to: jsonURL, atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(iniPlain, format: .ini, recipients: [owner.public])
            .write(to: iniURL, atomically: true, encoding: .utf8)

        // Step 1: scan → FileListModel lists all four, each classified from
        // its own content by `ProjectScanner.classify` — not from a filter
        // that only knew yaml and dotenv. `otherFormatCount` must be 0: F2
        // task 3 routed json and ini into `tree.encrypted` alongside yaml
        // and dotenv, so nothing should fall into the "other format" bucket
        // any more.
        let fileList = FileListModel(projectRoot: root)
        await fileList.refresh()
        #expect(fileList.files.count == 4)
        #expect(fileList.otherFormatCount == 0)

        func listed(_ name: String) throws -> ListedFile {
            try #require(fileList.files.first { $0.url.lastPathComponent == name })
        }
        let listedYAML = try listed("secret.yaml")
        let listedDotenv = try listed(".env")
        let listedJSON = try listed("secret.json")
        let listedINI = try listed("secret.ini")
        #expect(listedYAML.format == .yaml)
        #expect(listedDotenv.format == .dotenv)
        #expect(listedJSON.format == .json)
        #expect(listedINI.format == .ini)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)

        // Step 2a: yaml and dotenv are opened at the format the list handed
        // back and their rows checked, but left untouched — their
        // open+edit+save path already has dedicated coverage elsewhere
        // (see this file's header comment).
        let yamlEditor = SecretDocumentViewModel(
            fileURL: listedYAML.url, format: listedYAML.format, keyStore: keyStore)
        await yamlEditor.load()
        #expect(yamlEditor.loadState == .loaded)
        #expect(yamlEditor.rows.first { $0.path == ["database", "password"] }?.value == "correct-horse-battery-staple")

        let dotenvEditor = SecretDocumentViewModel(
            fileURL: listedDotenv.url, format: listedDotenv.format, keyStore: keyStore)
        await dotenvEditor.load()
        #expect(dotenvEditor.loadState == .loaded)
        #expect(dotenvEditor.rows.first { $0.path == ["DB_PASSWORD"] }?.value == "hunter2")

        // Step 2b: json is opened at the format the list handed back,
        // edited and saved through the editor.
        let jsonEditor = SecretDocumentViewModel(
            fileURL: listedJSON.url, format: listedJSON.format, keyStore: keyStore)
        await jsonEditor.load()
        #expect(jsonEditor.loadState == .loaded)
        let jsonRow = try #require(jsonEditor.rows.first { $0.path == ["api_key"] })
        jsonEditor.update(rowID: jsonRow.id, to: "json-rotated")
        #expect(jsonEditor.isDirty)
        #expect(await jsonEditor.save() == .saved)
        #expect(!jsonEditor.isDirty)

        // Step 2c: same for ini.
        let iniEditor = SecretDocumentViewModel(
            fileURL: listedINI.url, format: listedINI.format, keyStore: keyStore)
        await iniEditor.load()
        #expect(iniEditor.loadState == .loaded)
        let iniRow = try #require(iniEditor.rows.first { $0.path == ["db", "password"] })
        iniEditor.update(rowID: iniRow.id, to: "ini-rotated")
        #expect(iniEditor.isDirty)
        #expect(await iniEditor.save() == .saved)
        #expect(!iniEditor.isDirty)

        // The json and ini edits really landed, read back independently of
        // the view models that just wrote them, through the same
        // in-process bridge a real `sops` CLI invocation would use.
        let jsonAfterEdit = try SopsBridge.decrypt(
            try String(contentsOf: jsonURL, encoding: .utf8), format: .json, agePrivateKey: owner.private)
        #expect(jsonAfterEdit.contains("json-rotated"))
        let iniAfterEdit = try SopsBridge.decrypt(
            try String(contentsOf: iniURL, encoding: .utf8), format: .ini, agePrivateKey: owner.private)
        #expect(iniAfterEdit.contains("ini-rotated"))

        // Step 3: Project Access loads the project, sees all four files in
        // scope, stages a second recipient and re-wraps every file for it.
        let accessModel = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await accessModel.load()
        #expect(accessModel.loadState == .loaded)
        #expect(accessModel.plan?.matchedFiles.count == 4)
        #expect(accessModel.filesToApply.count == 4)
        #expect(Set(accessModel.filesToApply.map(\.format)) == Set([.yaml, .dotenv, .json, .ini]))

        let stageRefusal = accessModel.stageAdd(added.public)
        #expect(stageRefusal == nil)
        await accessModel.refreshPlan()
        #expect(accessModel.isDirty)

        let applyRefusal = await accessModel.applyToFiles()
        #expect(applyRefusal == nil)
        #expect(accessModel.fileResults.count == 4)
        #expect(accessModel.fileResults.allSatisfy { $0.outcome == .updated })

        // Step 4: every file, independently read from disk and decrypted
        // through the bridge, now opens for both the original owner and
        // the newly added recipient — and each carries the content that
        // was actually on disk after step 2, edited or not.
        let expectations: [(url: URL, format: SopsFileFormat, mustContain: [String])] = [
            (yamlURL, .yaml, ["correct-horse-battery-staple"]),
            (dotenvURL, .dotenv, ["DB_PASSWORD=hunter2"]),
            (jsonURL, .json, ["json-rotated"]),
            (iniURL, .ini, ["ini-rotated"]),
        ]

        for expectation in expectations {
            let onDisk = try String(contentsOf: expectation.url, encoding: .utf8)
            let recipients = try SopsBridge.recipients(in: onDisk, format: expectation.format)
            #expect(
                Set(recipients) == Set([owner.public, added.public]),
                "\(expectation.url.lastPathComponent) does not list both recipients after apply"
            )

            for identity in [owner.private, added.private] {
                let decrypted = try SopsBridge.decrypt(onDisk, format: expectation.format, agePrivateKey: identity)
                for needle in expectation.mustContain {
                    #expect(
                        decrypted.contains(needle),
                        "\(expectation.url.lastPathComponent) did not decrypt to the expected content for one of the two keys"
                    )
                }
            }
        }

        // The config text itself never changed — a flat `age:` rule is
        // writable in principle, but nothing in this flow asked Project
        // Access to rewrite it (only `applyToFiles`, never `applyConfig`,
        // was called).
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == configText)
    }
}
