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

/// A flat document with `keyCount` distinct top-level keys — a stand-in for
/// a real service's secrets file, used only to measure `load()`/`save()`
/// against a realistic key count (see `bridgeCallDoesNotBlockMainActor`).
private func flatYAML(keyCount: Int) -> String {
    (0..<keyCount).map { "key\($0): value-\($0)-abcdefghijkl" }.joined(separator: "\n") + "\n"
}

/// Counts ticks from a `Task` running on `@MainActor`, used to prove the
/// main actor stayed free to run other work while `load()`/`save()` were in
/// flight — a direct test of "the bridge call does not block the main
/// actor," not just a wall-clock timing that could pass for the wrong
/// reason (e.g. a fast machine masking a real block).
private actor TickCounter {
    private(set) var count = 0
    func tick() { count += 1 }
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

    // MARK: Review round 1 — save() must never claim .saved for a document
    // this type never opened.

    @Test("save() on a freshly constructed view model fails rather than claiming saved")
    func saveOnFreshViewModelFails() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        // load() was never called at all.
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        #expect(vm.loadState == .idle)
        #expect(!vm.isDirty, "isDirty is false here for the wrong reason: nothing was ever loaded")

        let outcome = await vm.save()

        guard case .failed = outcome else {
            Issue.record("expected .failed for a document that was never loaded, got \(outcome)")
            return
        }
        // And nothing was written — the file must still be exactly what
        // encryptedFixture produced.
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(onDisk.contains("sops:"))
        #expect(decrypted.contains("host: localhost"))
    }

    @Test("save() right after needsKey fails rather than claiming saved")
    func saveAfterNeedsKeyFails() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let emptyStore = SessionKeyStore()

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: emptyStore)
        await vm.load()
        #expect(vm.loadState == .needsKey)
        #expect(!vm.isDirty)

        let outcome = await vm.save()

        guard case .failed = outcome else {
            Issue.record("expected .failed after .needsKey, got \(outcome)")
            return
        }
    }

    @Test("save() right after a failed load fails rather than claiming saved")
    func saveAfterFailedLoadFails() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: owner)
        let store = SessionKeyStore()
        try store.importKey(stranger.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        guard case .failed = vm.loadState else {
            Issue.record("expected the wrong key to fail the load")
            return
        }
        #expect(!vm.isDirty)

        let outcome = await vm.save()

        guard case .failed = outcome else {
            Issue.record("expected .failed after a failed load, got \(outcome)")
            return
        }
    }

    @Test(
        "a successful load followed by a failed reload never leaves the document presenting as an empty editable form, and a subsequent save() still refuses"
    )
    func loadGoodThenLoadBadThenSaveNeverPresentsEmptyOrSaves() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: owner)
        let store = SessionKeyStore()
        try store.importKey(owner.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)

        // First load succeeds with the owner's key.
        await vm.load()
        #expect(vm.loadState == .loaded)
        #expect(!vm.rows.isEmpty)

        // Swap in a key that cannot decrypt this file and reload the same
        // instance — the scenario a "reload from disk" or "file changed
        // externally" action would trigger.
        store.forget()
        try store.importKey(stranger.private)
        await vm.load()

        guard case .failed = vm.loadState else {
            Issue.record("expected the reload with the wrong key to fail, got \(vm.loadState)")
            return
        }
        // The never-an-empty-form property: a failed reload must not leave
        // the previous load's rows sitting around looking like a live,
        // savable document.
        #expect(vm.rows.isEmpty)
        #expect(!vm.isDirty)

        // A save from here must refuse, not silently write nothing (or
        // worse, the stale in-memory state) over the file.
        let outcome = await vm.save()
        guard case .failed = outcome else {
            Issue.record("expected .failed after a failed reload, got \(outcome)")
            return
        }

        // And the file on disk must still be exactly what the owner's key
        // originally produced — untouched by either the failed reload or
        // the refused save.
        let decrypted = try cliDecrypt(fileURL, key: owner)
        #expect(decrypted.contains("host: localhost"))
    }

    // MARK: Review round 1 — the bridge call must not block the main actor

    /// Reproduces the reviewer's measurement directly: a `TickCounter`
    /// running on `@MainActor` alongside `load()`/`save()` proves the main
    /// actor stayed free to run other work while the bridge call was in
    /// flight, and prints the wall-clock timings this report's verification
    /// section quotes.
    @Test(
        "load() and save() do not block the main actor, at realistic file sizes",
        arguments: [3_000, 8_000])
    func bridgeCallDoesNotBlockMainActor(keyCount: Int) async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(flatYAML(keyCount: keyCount), key: key)
        let fileSize = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? -1

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)

        let ticks = TickCounter()
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                await ticks.tick()
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        }
        defer { heartbeat.cancel() }

        let loadStart = ContinuousClock.now
        await vm.load()
        let loadElapsed = loadStart.duration(to: .now)
        #expect(vm.loadState == .loaded)

        let firstRowID = try #require(vm.rows.first).id
        vm.update(rowID: firstRowID, to: "changed-value")
        #expect(vm.isDirty)

        let saveStart = ContinuousClock.now
        let outcome = await vm.save()
        let saveElapsed = saveStart.duration(to: .now)
        #expect(outcome == .saved)

        heartbeat.cancel()
        let finalTicks = await ticks.count

        print("=== PERFORMANCE: \(keyCount) keys, \(fileSize) bytes on disk ===")
        print("  load(): \(loadElapsed)")
        print("  save(): \(saveElapsed)")
        print("  MainActor heartbeat ticks during load()+save(): \(finalTicks)")

        // >0, not a larger threshold: under this machine's own heavy
        // unrelated contention (other processes' CPU load, not this test
        // suite's own parallelism), the *absolute* tick count is not
        // reproducible enough to gate on — a tighter bound flaked under
        // real observed load average >1.5x this machine's core count, from
        // processes unrelated to this test. Zero ticks is still the
        // meaningful line: it is what `Task.detached`'s cooperative-pool
        // starvation actually produced (measured 10-20s stalls, vs. ~0.1-0.4s
        // off the pool) before this was fixed to a dedicated `Thread` — see
        // `runOffCooperativePool`'s doc comment. Any tick at all means the
        // main actor got scheduled at least once while the bridge call was
        // in flight, which a genuine block cannot produce.
        #expect(
            finalTicks > 0,
            Comment(
                rawValue: "the main actor should have been scheduled at least once during "
                    + "load()/save(); got \(finalTicks) heartbeat ticks, which reads as a block"))
    }
}

// A document with a list of scalars, a nested map and an empty map — the
// three shapes adding and removing behave differently in.
private let structuralYAML = """
    service: api
    ports:
        - 8080
        - 8443
        - 9090
    db:
        host: localhost
        password: hunter2
    empty_map: {}

    """

@Suite("SecretDocumentViewModel — adding and removing rows")
@MainActor
struct SecretDocumentStructuralTests {

    private func loaded(_ yaml: String) async throws -> (SecretDocumentViewModel, AgeKeyPair, URL) {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(yaml, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        #expect(vm.loadState == .loaded)
        return (vm, key, fileURL)
    }

    private func row(_ vm: SecretDocumentViewModel, _ path: String...) throws -> SecretRow {
        guard let found = vm.rows.first(where: { $0.path == path }) else {
            throw FixtureError("no row at \(path); present: \(vm.rows.map { $0.path.joined(separator: ".") })")
        }
        return found
    }

    private func paths(_ vm: SecretDocumentViewModel) -> [String] {
        vm.rows.map { $0.path.joined(separator: ".") }
    }

    // MARK: The dirty-flag property the brief names explicitly

    @Test("adding a row and then removing it again leaves the document clean")
    func addThenRemoveIsClean() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)
        let before = vm.rows

        let destination = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        guard case .added(let id) = vm.addRow(in: destination, key: "replica", kind: .string, value: "r")
        else {
            Issue.record("the addition was refused")
            return
        }
        #expect(vm.isDirty)
        #expect(paths(vm).contains("db.replica"))

        vm.removeRow(id: id)

        #expect(!vm.isDirty, "undoing an addition must leave the document clean, not merely 'touched'")
        #expect(vm.rows == before, "the row list must be exactly what it was before the addition")
    }

    @Test("removing a key and adding it back is accepted on screen and by the save")
    func removeAndReAddSurvivesTheSave() async throws {
        // The natural gesture for "rename in place" or "change this key's
        // type". The editor used to accept it and the save used to refuse it
        // with a message contradicting the screen — the two layers now agree,
        // and this asserts the agreement end to end rather than either half.
        let (vm, key, fileURL) = try await loaded(structuralYAML)
        let hostID = try row(vm, "db", "host").id

        vm.removeRow(id: hostID)
        #expect(vm.isDirty)
        #expect(!paths(vm).contains("db.host"))

        let destination = vm.addDestination(forSelectedRowID: try row(vm, "db", "password").id)
        #expect(vm.refusalForAdding("host", in: destination) == nil,
                "the sheet must not refuse a name the save will accept")
        if case .refused(let reason) = vm.addRow(
            in: destination, key: "host", kind: .int, value: "5432") {
            Issue.record("re-adding a removed key was refused: \(reason)")
        }
        #expect(vm.isDirty)

        #expect(await vm.save() == .saved)

        // One key, the new type, and it moved to the end of its map — which
        // is exactly what the editor showed while the change was pending.
        #expect(paths(vm).filter { $0 == "db.host" }.count == 1)
        #expect(try row(vm, "db", "host").kind == .int)
        #expect(try row(vm, "db", "host").value == "5432")
        let after = try cliDecrypt(fileURL, key: key)
        #expect(after.contains("host: 5432"))
        #expect(!after.contains("host: localhost"))
    }

    // MARK: Where a new row goes

    @Test("the add destination follows the selection, and knows a list from a map")
    func addDestinationFollowsSelection() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)

        let root = vm.addDestination(forSelectedRowID: nil)
        #expect(root.parent.isEmpty)
        #expect(!root.isList)

        let inMap = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        #expect(inMap.parent == ["db"])
        #expect(!inMap.isList)

        let inList = vm.addDestination(forSelectedRowID: try row(vm, "ports", "1").id)
        #expect(inList.parent == ["ports"])
        #expect(inList.isList, "a list entry's container must be reported as a list, not inferred from its path")

        // An empty container is added *into*, or `foo: {}` would be a dead end.
        let intoEmpty = vm.addDestination(forSelectedRowID: try row(vm, "empty_map").id)
        #expect(intoEmpty.parent == ["empty_map"])
        #expect(!intoEmpty.isList)
    }

    @Test("a key added to a map appears at the end of that map, not at the end of the file")
    func addedKeyAppearsInItsOwnContainer() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)
        let destination = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        _ = vm.addRow(in: destination, key: "replica", kind: .string, value: "r")

        #expect(paths(vm) == ["service", "ports.0", "ports.1", "ports.2", "db.host", "db.password", "db.replica", "empty_map"])
    }

    @Test("a list entry is appended and takes the next index")
    func listEntryIsAppended() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)
        let destination = vm.addDestination(forSelectedRowID: try row(vm, "ports", "0").id)
        _ = vm.addRow(in: destination, key: "", kind: .int, value: "9443")
        _ = vm.addRow(in: destination, key: "", kind: .int, value: "9999")

        #expect(paths(vm).filter { $0.hasPrefix("ports.") } == ["ports.0", "ports.1", "ports.2", "ports.3", "ports.4"])
        #expect(try row(vm, "ports", "3").value == "9443")
        #expect(try row(vm, "ports", "4").value == "9999")
    }

    @Test("adding into an empty map replaces its empty-container row")
    func addingIntoAnEmptyMapReplacesItsRow() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)
        let destination = vm.addDestination(forSelectedRowID: try row(vm, "empty_map").id)
        _ = vm.addRow(in: destination, key: "first", kind: .string, value: "one")

        #expect(!paths(vm).contains("empty_map"), "a map with something in it is not an empty map")
        #expect(paths(vm).contains("empty_map.first"))
    }

    // MARK: Refusals

    @Test("a duplicate key is refused, including one that names a whole subtree")
    func duplicateKeyIsRefused() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)

        let inDB = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        #expect(vm.addRow(in: inDB, key: "host", kind: .string, value: "x")
            == .refused(.duplicateKey))
        #expect(vm.refusalForAdding("host", in: inDB) == .duplicateKey)

        // `db` has no row of its own — it is a subtree — and adding a second
        // `db` at the root must still be refused.
        let atRoot = vm.addDestination(forSelectedRowID: nil)
        #expect(vm.addRow(in: atRoot, key: "db", kind: .string, value: "x")
            == .refused(.duplicateKey))
        #expect(!vm.isDirty, "a refused addition must not dirty the document")
    }

    @Test("a map key with no name is refused")
    func emptyKeyIsRefused() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)
        let atRoot = vm.addDestination(forSelectedRowID: nil)
        #expect(vm.addRow(in: atRoot, key: "  ", kind: .string, value: "x") == .refused(.emptyKey))
    }

    @Test("adding to a document that was never loaded is refused")
    func addingWithoutADocumentIsRefused() async throws {
        let vm = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/nowhere/none.yaml"), keyStore: SessionKeyStore())
        let destination = vm.addDestination(forSelectedRowID: nil)
        #expect(vm.addRow(in: destination, key: "k", kind: .string, value: "v") == .refused(.notLoaded))
    }

    @Test("removing a row that is not there does nothing")
    func removingAnUnknownRowIsANoOp() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)
        let before = vm.rows
        vm.removeRow(id: "not-a-row")
        #expect(vm.rows == before)
        #expect(!vm.isDirty)
    }

    // MARK: Saving

    @Test("one save that adds, removes and edits changes exactly those three things")
    func addRemoveAndEditInOneSave() async throws {
        let (vm, key, fileURL) = try await loaded(structuralYAML)
        let before = try cliDecrypt(fileURL, key: key)

        vm.update(rowID: try row(vm, "service").id, to: "api-v2")
        vm.removeRow(id: try row(vm, "db", "password").id)
        let destination = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        _ = vm.addRow(in: destination, key: "replica", kind: .string, value: "replica.internal")

        #expect(await vm.save() == .saved)
        #expect(!vm.isDirty)

        let after = try cliDecrypt(fileURL, key: key)
        #expect(!after.contains("password"))
        #expect(after.contains("replica: replica.internal"))
        #expect(after.contains("service: api-v2"))
        // Untouched content survives verbatim.
        #expect(after.contains("host: localhost"))
        #expect(after.contains("- 8080"))
        #expect(after.contains("empty_map: {}"))
        #expect(before.contains("password: hunter2"))
    }

    @Test("after a save that removes a list entry, the rows match the file's new numbering")
    func rowsAreResyncedAfterAStructuralSave() async throws {
        let (vm, key, fileURL) = try await loaded(structuralYAML)

        vm.removeRow(id: try row(vm, "ports", "1").id)
        #expect(await vm.save() == .saved)

        // The whole point: `ports.1` is now 9090, not 8443. Holding the old
        // paths would send the next edit to the wrong element.
        #expect(paths(vm).filter { $0.hasPrefix("ports.") } == ["ports.0", "ports.1"])
        #expect(try row(vm, "ports", "0").value == "8080")
        #expect(try row(vm, "ports", "1").value == "9090")

        // And a follow-up edit lands where the editor says it does.
        vm.update(rowID: try row(vm, "ports", "1").id, to: "9091")
        #expect(await vm.save() == .saved)
        let after = try cliDecrypt(fileURL, key: key)
        #expect(after.contains("- 9091"))
        #expect(!after.contains("- 8443"))
        #expect(after.contains("- 8080"))
    }

    @Test("an added value is encrypted by the file's own rules, and reported as such after saving")
    func addedValuesFollowTheFilesRules() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(
            structuralYAML, key: key, extraArgs: ["--encrypted-regex", "^(password|token)$"])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()

        let destination = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        _ = vm.addRow(in: destination, key: "token", kind: .string, value: "t-123")
        _ = vm.addRow(in: destination, key: "region", kind: .string, value: "eu")

        // Before the save the editor makes no claim either way.
        #expect(try row(vm, "db", "token").isPendingAdd)
        #expect(try row(vm, "db", "region").isPendingAdd)

        #expect(await vm.save() == .saved)

        #expect(try row(vm, "db", "token").isEncrypted)
        #expect(try !row(vm, "db", "region").isEncrypted)
        #expect(try !row(vm, "db", "token").isPendingAdd)

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!onDisk.contains("t-123"))
        #expect(onDisk.contains("region: eu"))
    }

    @Test("a batch the bridge refuses fails the save and leaves every pending change intact")
    func anAmbiguousBatchIsRefusedAndNothingIsLost() async throws {
        let (vm, key, fileURL) = try await loaded(structuralYAML)
        let originalOnDisk = try String(contentsOf: fileURL, encoding: .utf8)

        // Removing ports.1 renumbers ports.2, which this same save edits.
        vm.removeRow(id: try row(vm, "ports", "1").id)
        vm.update(rowID: try row(vm, "ports", "2").id, to: "9091")

        let outcome = await vm.save()
        guard case .failed(let message) = outcome else {
            Issue.record("an ambiguous batch was accepted: \(outcome)")
            return
        }
        #expect(message.contains("ports"), Comment(rawValue: message))
        #expect(!message.contains("hunter2"), "a refusal must never carry a value")

        #expect(vm.isDirty, "a refused save must leave the user's work exactly where they left it")
        #expect(try row(vm, "ports", "2").value == "9091")
        #expect(!paths(vm).contains("ports.1"), "the pending removal is still pending")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == originalOnDisk,
                "a refused save must not touch the file")
        #expect(try cliDecrypt(fileURL, key: key).contains("- 8443"),
                "the file the CLI sees is untouched too")
    }

    @Test("saving with nothing pending writes nothing at all")
    func aCleanSaveIsANoOp() async throws {
        let (vm, _, fileURL) = try await loaded(structuralYAML)
        let before = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(await vm.save() == .saved)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == before)
    }
}


@Suite("SecretDocumentViewModel — the two ways a save can be undermined")
@MainActor
struct SecretDocumentSaveIntegrityTests {

    private func loaded(_ yaml: String) async throws -> (SecretDocumentViewModel, AgeKeyPair, URL) {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(yaml, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        #expect(vm.loadState == .loaded)
        return (vm, key, fileURL)
    }

    private func row(_ vm: SecretDocumentViewModel, _ path: String...) throws -> SecretRow {
        guard let found = vm.rows.first(where: { $0.path == path }) else {
            throw FixtureError("no row at \(path); present: \(vm.rows.map { $0.path.joined(separator: ".") })")
        }
        return found
    }

    // MARK: A key that would destroy the file

    @Test("a new key named as YAML's merge key is refused, on screen and by the bridge")
    func theMergeKeyNameIsRefused() async throws {
        let (vm, key, fileURL) = try await loaded(structuralYAML)
        let before = try String(contentsOf: fileURL, encoding: .utf8)

        let destination = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        #expect(vm.refusalForAdding("<<", in: destination) == .reservedKey)
        #expect(vm.addRow(in: destination, key: "<<", kind: .string, value: "anything")
            == .refused(.reservedKey))
        #expect(!vm.isDirty)
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == before)

        // And the file is still readable by the standard tool, which is the
        // property the refusal exists to protect.
        #expect(try cliDecrypt(fileURL, key: key).contains("host: localhost"))
    }

    @Test("a top-level key named sops is refused; a nested one is not")
    func theSopsMetadataNameIsRefusedOnlyAtTheRoot() async throws {
        let (vm, _, _) = try await loaded(structuralYAML)

        let root = vm.addDestination(forSelectedRowID: nil)
        #expect(vm.refusalForAdding("sops", in: root) == .reservedKey)

        let inDB = vm.addDestination(forSelectedRowID: try row(vm, "db", "host").id)
        #expect(vm.refusalForAdding("sops", in: inDB) == nil)
        if case .refused(let reason) = vm.addRow(in: inDB, key: "sops", kind: .string, value: "fine") {
            Issue.record("a nested key named sops was refused: \(reason)")
        }
        #expect(await vm.save() == .saved)
        #expect(try row(vm, "db", "sops").value == "fine")
    }

    // MARK: Editing while a save is in flight

    @Test("changes attempted during a save are refused, not swallowed")
    func editingDuringASaveIsRefused() async throws {
        // A big enough document that the encrypt genuinely takes time, so the
        // window this tests is the real one and not a scheduling accident.
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(flatYAML(keyCount: 3_000), key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()

        let firstID = try #require(vm.rows.first).id
        vm.update(rowID: firstID, to: "saved-value")
        let rowsBeforeSave = vm.rows

        let saving = Task { await vm.save() }
        // Wait for the save to actually be in flight before interfering.
        while !vm.isSaving { await Task.yield() }

        let secondID = vm.rows[1].id
        vm.update(rowID: secondID, to: "typed-mid-save")
        vm.removeRow(id: vm.rows[2].id)
        let destination = vm.addDestination(forSelectedRowID: nil)
        #expect(vm.addRow(in: destination, key: "added_mid_save", kind: .string, value: "x")
            == .refused(.saveInProgress))
        #expect(await vm.save() == .failed("a save of this document is already in progress"))

        #expect(await saving.value == .saved)
        #expect(!vm.isSaving)

        // Nothing attempted mid-save was adopted: no ghost row claiming to be
        // saved, no swallowed removal, and the value that *was* sent is the
        // only thing that changed.
        #expect(vm.rows.count == rowsBeforeSave.count)
        #expect(!vm.rows.contains { $0.path == ["added_mid_save"] })
        #expect(vm.rows[1].value == rowsBeforeSave[1].value)
        #expect(!vm.isDirty)

        let onDisk = try cliDecrypt(fileURL, key: key)
        #expect(onDisk.contains("saved-value"))
        #expect(!onDisk.contains("typed-mid-save"))
        #expect(!onDisk.contains("added_mid_save"))
    }

    @Test("a removal attempted during a shape-changing save cannot desynchronise the paths")
    func removalDuringAStructuralSaveIsRefused() async throws {
        let (vm, key, fileURL) = try await loaded(structuralYAML)

        vm.removeRow(id: try row(vm, "ports", "0").id)
        let saving = Task { await vm.save() }
        while !vm.isSaving { await Task.yield() }
        // The dangerous one: had this been swallowed, `changedShape` came
        // from the snapshot and the resync would still have run — but a
        // *second* removal adopted silently would leave the in-memory paths
        // off by one against the file.
        if let second = vm.rows.first(where: { $0.path == ["ports", "1"] }) {
            vm.removeRow(id: second.id)
        }
        // Refused, so the row is still there. Without the guard it would
        // disappear from the editor and then be discarded by the reload —
        // a user action silently undone with nothing said.
        #expect(vm.rows.contains { $0.path == ["ports", "1"] },
                "a removal attempted mid-save must be refused, not accepted and then lost")
        #expect(await saving.value == .saved)

        // Two entries left, renumbered by the reload, matching the file.
        #expect(vm.rows.filter { $0.path.first == "ports" }.map(\.value) == ["8443", "9090"])
        let after = try cliDecrypt(fileURL, key: key)
        #expect(after.contains("- 8443"))
        #expect(after.contains("- 9090"))
        #expect(!after.contains("- 8080"))
    }
}
