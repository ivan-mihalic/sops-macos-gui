import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

// MARK: - Task 10 (SOPS-38): the whole F1 chain in one flow
//
// Every earlier task in this plan proved its own seam in isolation: T5 proved
// the scanner classifies a dotenv sops file by content, T6 proved the editor
// can open and save one, T7 proved `ProjectRecipientApplier`/`ProjectAccessModel`
// re-wrap a mixed-format project for a staged recipient, T8 proved creation
// and import. None of them proved the seams still agree with each other when
// chained — that `FileListModel`'s `ListedFile.format` is what
// `SecretDocumentViewModel` actually opens with, that a save through the
// editor is what Project Access then re-wraps, and that re-wrapping via a
// staged recipient produces bytes every intended reader can still open.
//
// The project shape is deliberately not the flat "age:" list every other
// fixture in this codebase uses: momentak's real `.sops.yaml` groups its age
// keys under `key_groups`, which `ProjectRecipientApplierTests
// .planExplainsAnUnsupportedConfigShape` already proved this app refuses to
// rewrite — the config text itself never changes. What is under test here is
// that config-rewrite refusal does not also block *file* re-wrapping: the
// governing rule is still identified from a key_groups config, so Project
// Access can still stage a third recipient and re-wrap both files for it,
// exactly as `ProjectRecipientApplierTests.planExplainsAnUnsupportedConfigShape`
// documents ("The rule was still identified, so the file list is still
// useful").
//
// Fixtures go through the real in-process bridge, never hand-written text —
// the discipline every suite this one draws on already holds to. Only key
// generation shells out, because there is no in-process keygen.

private struct MomentakFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private struct MomentakAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> MomentakAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else {
            throw MomentakFixtureError("age-keygen not found in \(candidates)")
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
            throw MomentakFixtureError("age-keygen produced no usable key pair")
        }
        return MomentakAgeKeyPair(private: priv, public: pub)
    }
}

private func momentakScratchDirectory(_ label: String = "momentak-shaped-project") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Suite("Task 10 integration — a momentak-shaped dotenv project, scan through access apply")
@MainActor
struct MomentakShapedDotenvIntegrationTests {

    @Test(
        "scan classifies both dotenv files, an edit saves through the editor, and Project Access re-wraps both for a staged recipient — every intended key still opens them"
    )
    func fullChainScanListOpenEditSaveAccessApplyDecrypt() async throws {
        let keyA = try MomentakAgeKeyPair.generate()
        let keyB = try MomentakAgeKeyPair.generate()
        let added = try MomentakAgeKeyPair.generate()

        let root = try momentakScratchDirectory()

        // Momentak's real config shape: a `key_groups` rule rather than a
        // flat `age:` list — the shape this app reads fine but will not
        // rewrite (`ProjectRecipientApplierTests.planExplainsAnUnsupportedConfigShape`).
        let configText = """
            creation_rules:
              - path_regex: secrets/.*\\.sops\\.env$
                key_groups:
                  - age:
                      - \(keyA.public)
                      - \(keyB.public)

            """
        try configText.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secrets = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)

        let firstOriginal = "DATABASE_URL=postgres://prod\nAPI_KEY=sk-prod-original\n"
        let secondOriginal = "DATABASE_URL=postgres://staging\nAPI_KEY=sk-staging-original\n"
        let firstURL = secrets.appendingPathComponent("prod.sops.env")
        let secondURL = secrets.appendingPathComponent("staging.sops.env")
        try SopsBridge.encrypt(firstOriginal, format: .dotenv, recipients: [keyA.public, keyB.public])
            .write(to: firstURL, atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(secondOriginal, format: .dotenv, recipients: [keyA.public, keyB.public])
            .write(to: secondURL, atomically: true, encoding: .utf8)

        // Step 1: scan → FileListModel lists both, classified as `.dotenv`
        // from their own content — never from the `.sops.env` name, and
        // never from the config's own (unrelated) shape.
        let fileList = FileListModel(projectRoot: root)
        await fileList.refresh()
        #expect(fileList.files.count == 2)
        #expect(fileList.files.allSatisfy { $0.format == .dotenv })
        let listedFirst = try #require(
            fileList.files.first { $0.url.lastPathComponent == "prod.sops.env" })
        #expect(fileList.relativePath(for: listedFirst.url) == "secrets/prod.sops.env")

        // Step 2: SecretDocumentViewModel opens the file the list handed
        // back — at the format the list carries, not a hardcoded `.dotenv` —
        // edits one value, and saves.
        let keyStore = SessionKeyStore()
        try keyStore.importKey(keyA.private)
        let editor = SecretDocumentViewModel(
            fileURL: listedFirst.url, format: listedFirst.format, keyStore: keyStore)
        await editor.load()
        #expect(editor.loadState == .loaded)
        #expect(editor.rows.count == 2)

        let apiKeyRow = try #require(editor.rows.first { $0.path == ["API_KEY"] })
        editor.update(rowID: apiKeyRow.id, to: "sk-prod-rotated")
        #expect(editor.isDirty)

        let saveOutcome = await editor.save()
        #expect(saveOutcome == .saved)
        #expect(!editor.isDirty)

        // The edit really landed, read back independently of the view model
        // that just wrote it — through the same in-process bridge a real
        // `sops` CLI invocation would use.
        let afterEditOnDisk = try String(contentsOf: firstURL, encoding: .utf8)
        let afterEditPlain = try SopsBridge.decrypt(
            afterEditOnDisk, format: .dotenv, agePrivateKey: keyA.private)
        #expect(afterEditPlain.contains("API_KEY=sk-prod-rotated"))
        #expect(afterEditPlain.contains("DATABASE_URL=postgres://prod"))

        // Step 3: Project Access loads the project. The `key_groups` config
        // is read fine — both original recipients come back — but refused
        // for rewriting; the governing rule is still identified, so both
        // files are still in scope.
        let accessModel = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await accessModel.load()
        #expect(accessModel.loadState == .loaded)
        #expect(Set(accessModel.configRecipients) == Set([keyA.public, keyB.public]))
        #expect(accessModel.plan?.configRefusal?.contains("key_groups") == true)
        #expect(accessModel.plan?.configNeedsWriting == false)
        #expect(accessModel.plan?.matchedFiles.count == 2)
        #expect(accessModel.filesToApply.count == 2)
        #expect(accessModel.filesToApply.allSatisfy { $0.format == .dotenv })
        // The rule is still identified even though this app will not rewrite
        // it, so applying to files never needs the widened-scope consent
        // gate — that gate is only for a config this app could not
        // identify at all.
        #expect(!accessModel.requiresWidenedScopeAcknowledgement)

        // Step 4: stage a third recipient and re-wrap both files for it.
        let stageRefusal = accessModel.stageAdd(added.public)
        #expect(stageRefusal == nil)
        await accessModel.refreshPlan()
        #expect(accessModel.isDirty)

        let applyRefusal = await accessModel.applyToFiles()
        #expect(applyRefusal == nil)
        #expect(accessModel.fileResults.count == 2)
        #expect(accessModel.fileResults.allSatisfy { $0.outcome == .updated })

        // The config text itself never changed — this app refused to rewrite
        // a `key_groups` rule, and did not silently fall back to rewriting
        // it as a flat list.
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == configText)

        // Step 5: both files, independently read from disk and decrypted
        // through the bridge — the in-process stand-in for the `sops` CLI —
        // now open for every one of the three recipients, and the edit from
        // step 2 survived the re-wrap.
        for (url, expectedPlain) in [
            (firstURL, "DATABASE_URL=postgres://prod\nAPI_KEY=sk-prod-rotated\n"),
            (secondURL, secondOriginal),
        ] {
            let onDisk = try String(contentsOf: url, encoding: .utf8)
            let recipients = try SopsBridge.recipients(in: onDisk, format: .dotenv)
            #expect(Set(recipients) == Set([keyA.public, keyB.public, added.public]))

            for identity in [keyA.private, keyB.private, added.private] {
                let decrypted = try SopsBridge.decrypt(onDisk, format: .dotenv, agePrivateKey: identity)
                #expect(
                    decrypted == expectedPlain,
                    "\(url.lastPathComponent) did not decrypt to the expected content for one of the three keys"
                )
            }
        }
    }
}
