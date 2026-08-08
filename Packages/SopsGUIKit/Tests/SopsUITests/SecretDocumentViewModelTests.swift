import Foundation
import Testing
import SopsEngine
import SopsProjects
@testable import SopsUI

// MARK: - Real-binary fixture plumbing
//
// Every fixture in this file is produced by the real `sops` and `age`
// binaries, never by a hand-written string this app's own code would be
// predisposed to accept. This project has hit three separate multi-round
// defects from fixtures that were plausible-looking approximations rather
// than real tool output (see the M2 ledger); the document API itself
// (Task 7) settled its central risk the same way.

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
private func run(_ executable: String, _ arguments: [String], environment: [String: String] = [:]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
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

/// A throwaway age identity, generated per test via the real `age-keygen`.
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

/// A scratch directory, removed by the OS's own temp-file housekeeping —
/// mirrors `Tests/SopsEngineTests/TestSupport.swift`'s `TempFile`.
private func scratchDirectory(_ label: String = "vm-fixture") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Encrypts `plain` with the real `sops` CLI and writes the result to a file
/// inside a fresh scratch directory, returning that file's URL. The caller
/// gets a real on-disk SOPS document, exactly what `SecretDocumentViewModel`
/// is built to open.
private func encryptedFixture(
    _ plain: String, key: AgeKeyPair, extraArgs: [String] = []
) throws -> URL {
    let dir = try scratchDirectory()
    let plainURL = dir.appendingPathComponent("plain.yaml")
    try plain.write(to: plainURL, atomically: true, encoding: .utf8)

    let keysURL = dir.appendingPathComponent("keys.txt")
    try (key.private + "\n").write(to: keysURL, atomically: true, encoding: .utf8)

    try run(
        try toolPath("sops"),
        ["--encrypt", "--age", key.public] + extraArgs + ["--in-place", plainURL.path],
        environment: ["SOPS_AGE_KEY_FILE": keysURL.path])

    let encryptedURL = dir.appendingPathComponent("secret.yaml")
    try FileManager.default.moveItem(at: plainURL, to: encryptedURL)
    return encryptedURL
}

/// Decrypts a file with the real `sops` CLI — the compatibility oracle for
/// the round-trip test, exactly as Task 7's own tests use it.
private func cliDecrypt(_ url: URL, key: AgeKeyPair) throws -> String {
    let dir = try scratchDirectory("cli-decrypt")
    let keysURL = dir.appendingPathComponent("keys.txt")
    try (key.private + "\n").write(to: keysURL, atomically: true, encoding: .utf8)
    return try run(
        try toolPath("sops"), ["--decrypt", url.path],
        environment: ["SOPS_AGE_KEY_FILE": keysURL.path])
}

/// A small document with one of each scalar kind the editor has to render,
/// plus a comment and a nested map — enough to exercise path/value/kind
/// fidelity without repeating the full richness Task 7 already pinned at the
/// bridge layer.
private let sampleYAML = """
    # top of file
    db:
        host: localhost
        port: 5432
        enabled: true
        ratio: 0.5
        nothing: null
    api_key: sk-live-abc123
    empty_map: {}

    """

@Suite("SecretDocumentViewModel")
@MainActor
struct SecretDocumentViewModelTests {

    private func row(_ vm: SecretDocumentViewModel, _ path: String...) throws -> SecretRow {
        guard let found = vm.rows.first(where: { $0.path == path }) else {
            throw FixtureError("no row at \(path); present: \(vm.rows.map { $0.path.joined(separator: ".") })")
        }
        return found
    }

    // MARK: The property that matters most

    @Test("loading without a key reports needsKey rather than an empty editable form")
    func needsKeyWhenNoIdentityIsConfigured() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let emptyStore = SessionKeyStore()

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: emptyStore)
        #expect(vm.loadState == .idle)

        await vm.load()

        #expect(vm.loadState == .needsKey)
        #expect(vm.rows.isEmpty)
        #expect(!vm.isDirty)
    }

    @Test("a file that fails to decrypt reports failed and renders nothing editable")
    func failedDecryptReportsFailedWithNoRows() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: owner)

        let store = SessionKeyStore()
        try store.importKey(stranger.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()

        guard case .failed(let message) = vm.loadState else {
            Issue.record("expected .failed, got \(vm.loadState)")
            return
        }
        #expect(message.contains("none of the keys"), Comment(rawValue: message))
        #expect(vm.rows.isEmpty, "a failed load must render nothing editable")
        #expect(!vm.isDirty)
    }

    // MARK: Loading

    @Test("a successful load populates rows with paths, values and kinds intact")
    func successfulLoadPopulatesRows() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()

        #expect(vm.loadState == .loaded)
        #expect(
            vm.rows.map { $0.path.joined(separator: ".") } == [
                "db.host", "db.port", "db.enabled", "db.ratio", "db.nothing",
                "api_key", "empty_map",
            ])

        #expect(try row(vm, "db", "host").value == "localhost")
        #expect(try row(vm, "db", "port").value == "5432")
        #expect(try row(vm, "db", "port").kind == .int)
        #expect(try row(vm, "db", "enabled").kind == .bool)
        #expect(try row(vm, "db", "ratio").kind == .float)
        #expect(try row(vm, "db", "nothing").kind == .null)
        #expect(try row(vm, "api_key").value == "sk-live-abc123")
        #expect(try row(vm, "empty_map").kind == .emptyMap)
        #expect(try !row(vm, "empty_map").kind.isEditable)
        #expect(!vm.isDirty)
    }

    // MARK: Dirty tracking

    @Test("editing a value sets isDirty; setting it back to the original clears it")
    func editingTogglesIsDirty() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        let hostID = try row(vm, "db", "host").id

        #expect(!vm.isDirty)
        vm.update(rowID: hostID, to: "elsewhere")
        #expect(vm.isDirty)
        vm.update(rowID: hostID, to: "localhost")
        #expect(!vm.isDirty, "reverting to the original value must clear isDirty")
    }

    @Test("editing two values and reverting one leaves isDirty true")
    func partialRevertLeavesDirty() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        let hostID = try row(vm, "db", "host").id
        let apiKeyID = try row(vm, "api_key").id

        vm.update(rowID: hostID, to: "elsewhere")
        vm.update(rowID: apiKeyID, to: "sk-live-rotated")
        #expect(vm.isDirty)

        vm.update(rowID: hostID, to: "localhost")
        #expect(vm.isDirty, "one row is still changed from its baseline")
    }

    @Test("editing an uneditable row (empty map/list) is a no-op")
    func editingAnUneditableRowDoesNothing() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        let originalValue = try row(vm, "empty_map").value
        let emptyMapID = try row(vm, "empty_map").id

        vm.update(rowID: emptyMapID, to: "anything")

        #expect(!vm.isDirty)
        #expect(try row(vm, "empty_map").value == originalValue, "an uneditable row's value must not change")
    }

    // MARK: Saving

    @Test("save writes and clears isDirty, and the sops CLI reads back exactly the edit")
    func saveWritesAndClearsIsDirty() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "db.internal")
        #expect(vm.isDirty)

        let outcome = await vm.save()

        #expect(outcome == .saved)
        #expect(!vm.isDirty)

        // The file on disk really changed, and the real CLI reads the new
        // value back — not a claim this app's own decryptToRows would also
        // make if something were subtly wrong.
        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(decrypted.contains("host: db.internal"))
        #expect(decrypted.contains("port: 5432"), "an untouched value must survive the save")
        #expect(decrypted.contains("# top of file"), "comments must survive the save")
    }

    @Test("a failed save leaves isDirty set and the rows untouched")
    func failedSaveLeavesStateUntouched() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        struct WriteBoom: Error {}
        let vm = SecretDocumentViewModel(
            fileURL: fileURL, keyStore: store,
            writeFile: { _, _ in throw WriteBoom() })
        await vm.load()
        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "changed-but-unsaved")

        let outcome = await vm.save()

        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(vm.isDirty, "the user's unsaved edit must not be reported as saved")
        #expect(try row(vm, "db", "host").value == "changed-but-unsaved", "the edit must still be sitting in rows")

        // And the file on disk was never touched by the failed write.
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!onDisk.contains("changed-but-unsaved"))
        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(decrypted.contains("host: localhost"), "the on-disk file must be exactly what it was before the failed save")
    }

    @Test("saving with no edits is a no-op: no bridge call, no write, the file is untouched")
    func noEditsIsANoOp() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let before = try String(contentsOf: fileURL, encoding: .utf8)

        var writeWasCalled = false
        let vm = SecretDocumentViewModel(
            fileURL: fileURL, keyStore: store,
            writeFile: { contents, url in
                writeWasCalled = true
                try contents.write(to: url, atomically: true, encoding: .utf8)
            })
        await vm.load()
        #expect(!vm.isDirty)

        let outcome = await vm.save()

        #expect(outcome == .saved)
        #expect(!writeWasCalled, "no edits were made, so save() must not call the writer at all")
        let after = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(before == after, "the file on disk must be byte-for-byte untouched")
    }

    // MARK: No secret ever reaches an error string

    @Test("no error string exposed by the view model contains any row value")
    func noErrorStringCarriesARowValue() async throws {
        let canary = "SUPERSECRETCANARY9999"

        // 1. A load failure that, upstream of this app's own sanitisation,
        //    would otherwise quote the decrypted plaintext: a retyped
        //    `ENC[...,type:str]` tag authenticates fine and fails to
        //    *convert*, so sops's own strconv error carries the plaintext
        //    (Task 7 §7). This exercises the same hazard one layer up, through
        //    the view model rather than the bridge directly.
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture("api_key: \(canary)\nother: fine\n", key: key)
        var lines = try String(contentsOf: fileURL, encoding: .utf8).components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { $0.hasPrefix("api_key: ENC[") }) else {
            throw FixtureError("fixture has no encrypted api_key")
        }
        lines[index] = lines[index].replacingOccurrences(of: ",type:str]", with: ",type:int]")
        try lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let loadVM = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await loadVM.load()

        guard case .failed(let loadMessage) = loadVM.loadState else {
            Issue.record("expected the corrupted type tag to fail decryption")
            return
        }
        #expect(!loadMessage.contains(canary), Comment(rawValue: loadMessage))

        // 2. A failed save, with a canary value sitting in a dirty row.
        let goodFileURL = try encryptedFixture(sampleYAML, key: key)
        struct WriteBoom: Error {}
        let saveVM = SecretDocumentViewModel(
            fileURL: goodFileURL, keyStore: store,
            writeFile: { _, _ in throw WriteBoom() })
        await saveVM.load()
        let hostID = try row(saveVM, "db", "host").id
        saveVM.update(rowID: hostID, to: canary)

        let saveOutcome = await saveVM.save()
        guard case .failed(let saveMessage) = saveOutcome else {
            Issue.record("expected the injected write failure to fail the save")
            return
        }
        #expect(!saveMessage.contains(canary), Comment(rawValue: saveMessage))
    }

    // MARK: A demonstration for the report — real fixture, printed, edited,
    // saved, and independently verified with the real `sops` CLI.

    @Test("MANUAL DEMONSTRATION: load, print, edit, save, verify with the real sops CLI")
    func manualRoundTripDemonstration() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        print("=== encrypted fixture written to \(fileURL.path) ===")
        print(try String(contentsOf: fileURL, encoding: .utf8))

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)

        await vm.load()
        print("=== loadState after load(): \(vm.loadState) ===")
        print("=== rows after load() ===")
        for r in vm.rows {
            print("  \(r.path.joined(separator: ".")) = \(r.value) (\(r.kind), encrypted=\(r.isEncrypted))")
        }

        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "db.internal.example")
        print("=== isDirty after editing db.host: \(vm.isDirty) ===")

        let outcome = await vm.save()
        print("=== save() outcome: \(outcome), isDirty now: \(vm.isDirty) ===")

        let decrypted = try cliDecrypt(fileURL, key: key)
        print("=== real `sops --decrypt` on the saved file ===")
        print(decrypted)

        #expect(outcome == .saved)
        #expect(decrypted.contains("host: db.internal.example"))
        #expect(decrypted.contains("port: 5432"))
        #expect(decrypted.contains("# top of file"))
    }
}
