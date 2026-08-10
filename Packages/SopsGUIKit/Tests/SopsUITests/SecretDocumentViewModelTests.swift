import Foundation
import ScratchCleanup
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
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
    ScratchDirectoryRegistry.shared.register(dir)
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

/// Adds a key to an existing encrypted document with the real `sops set`,
/// which is one of the things that actually happens to a file while this app
/// has it open (`git pull`, `sops updatekeys`, a second instance of the app,
/// or literally this). Used as the *external writer* in the concurrent-write
/// tests: a hand-rolled append would break the document's MAC and would prove
/// something else entirely.
private func cliSet(_ url: URL, key: AgeKeyPair, path: String, value: String) throws {
    let dir = try scratchDirectory("cli-set")
    let keysURL = dir.appendingPathComponent("keys.txt")
    try (key.private + "\n").write(to: keysURL, atomically: true, encoding: .utf8)
    try run(
        try toolPath("sops"), ["set", url.path, path, value],
        environment: ["SOPS_AGE_KEY_FILE": keysURL.path])
}

/// A flat document with `keyCount` distinct top-level keys — a stand-in for
/// a real service's secrets file, used only to measure `load()`/`save()`
/// against a realistic key count (see `bridgeCallDoesNotBlockMainActor`).
private func flatYAML(keyCount: Int) -> String {
    (0..<keyCount).map { "key\($0): value-\($0)-abcdefghijkl" }.joined(separator: "\n") + "\n"
}

/// Counts ticks from a `Task` running on `@MainActor`. Kept for the number it
/// prints, which is the one the M2 report quotes — **not** as the assertion.
/// See `MainThreadOccupancy` for why a tick count cannot carry this property.
private actor TickCounter {
    private(set) var count = 0
    func tick() { count += 1 }
}

// MARK: - Measuring whether the main actor was blocked

/// How much of a window's wall-clock time the **main thread spent computing**.
///
/// # Why not the heartbeat
///
/// The obvious instrument — start a `@MainActor` task ticking every 2ms and
/// check it ticked — was here first, asserting `ticks > 0`, and it certified
/// nothing. Measured:
///
/// | run | load+save | ticks | rate |
/// |---|---|---|---|
/// | `--no-parallel`, 3000 keys | 0.21s | 61 | ~290/s |
/// | `--no-parallel`, 8000 keys | 0.64s | 193 | ~290/s |
/// | `--filter SecretDocumentViewModel` (parallel) | ~3.8s | 3 | ~0.8/s |
///
/// So in the full suite the assertion passed while the main actor was 99.85%
/// unavailable — 0.15% of the scheduling the test exists to require. And the
/// first tick is structural: the heartbeat's first `tick()` runs at the first
/// suspension of `await vm.load()`, before any bridge work, so `> 0` is close
/// to guaranteed however badly things go.
///
/// Raising the bar does not fix it, and neither does a ratio against a
/// baseline taken in the same run. The starvation is real but it is the
/// *harness's*: 38 `@MainActor` tests in this file each run `sops` through a
/// synchronous `Process` from a main-actor test body, in parallel. When the
/// main actor is saturated by other tests, nothing measured from the main
/// actor can distinguish "this call blocked it" from "everything else did" —
/// both the subject window and any control window collapse to the same two or
/// three ticks.
///
/// # What this measures instead
///
/// The property is "the bridge call does not block the main actor". Its
/// mechanical form is "the bridge call does not run its work *on the main
/// thread*", and that is directly observable from outside: `thread_info` on
/// the main thread reports the CPU time that thread itself has burned.
///
/// Encrypting and decrypting a few thousand keys is CPU-bound work of a few
/// hundred milliseconds. If the bridge runs it on the main actor, the main
/// thread's own CPU clock advances by roughly the duration of the call and the
/// fraction below approaches 1. If it runs off the main actor — a dedicated
/// `Thread`, as `runOffCooperativePool` does today — the main thread burns
/// almost nothing and the fraction is near 0.
///
/// This is immune to exactly the contention the tick count was not. The other
/// 37 tests saturate the main actor by *blocking* it in `waitUntilExit` and
/// `readDataToEndOfFile`, which consume wall-clock time but no CPU; the sops
/// work itself happens in a child process, charged to that process. Suite
/// parallelism can therefore stretch the denominator, which only makes the
/// fraction smaller — it cannot manufacture main-thread CPU that a
/// correctly-offloaded bridge did not spend.
///
/// `mainActorInstrumentDiscriminates` pins both ends of that claim with a
/// deliberate on-main-thread burn and a deliberate off-main-thread one, so the
/// instrument's own sensitivity is a test rather than an assertion of mine.
private struct MainThreadOccupancy {
    let wallSeconds: Double
    let cpuSeconds: Double

    /// 0 = the main thread did nothing while this ran; 1 = it was computing
    /// the whole time.
    var fraction: Double { cpuSeconds / max(wallSeconds, 1e-9) }

    var description: String {
        String(format: "%.3fs wall, %.3fs main-thread CPU (%.1f%%)",
               wallSeconds, cpuSeconds, fraction * 100)
    }
}

/// Anything at or above this is read as "the work ran on the main actor".
/// A genuine block measures ~1.0 (`mainActorInstrumentDiscriminates`'s positive
/// control); correct offloading measures a few percent. There is nothing near
/// the middle, so the exact number is not load-bearing — it is set well clear
/// of both.
private let blockedMainThreadFraction = 0.5

/// Whether this binary was built with a sanitizer that instruments every memory
/// access.
///
/// `RTLD_DEFAULT` is `(void *)-2` on Darwin; `__tsan_init` exists only in a
/// ThreadSanitizer build.
///
/// This matters because the occupancy assertion below is a **wall-clock ratio**,
/// and TSan changes the thing it measures. Measured on this machine, same test,
/// same input:
///
///     plain        save() occupancy: 30.1%  7.5%  22.1%  6.7%  22.2%  6.9%  — 6/6 pass
///     TSan         save() occupancy: 53.8% 20.3%  56.0% 20.3%  21.6% 30.4%  — 3/3 runs fail
///
/// So `swift test --sanitize=thread` could not come back green, and this
/// project uses exactly that command to prove its concurrency correctness — it
/// is how the real data race in `ProjectScanner`'s concurrent map was found. A
/// red TSan run that is *expected* to be red is a TSan run nobody reads, which
/// is precisely where the next real race would hide.
///
/// Only the two ratio assertions are skipped. Everything else in the test — that
/// load and save actually succeed, that the edit lands, that the instrument
/// reports at all — still runs under the sanitizer, which is where the race
/// detection value is anyway.
private let isRunningUnderThreadSanitizer: Bool = {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__tsan_init") != nil
}()

/// The main thread's own accumulated CPU time, user + system.
///
/// `@MainActor` is what makes `mach_thread_self()` the right thread: the main
/// actor's executor is the main thread, so a call from main-actor-isolated
/// code is a call from it.
@MainActor
private func mainThreadCPUSeconds() -> Double {
    var info = thread_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let thread = mach_thread_self()
    defer { mach_port_deallocate(mach_task_self_, thread) }

    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
        }
    }
    guard status == KERN_SUCCESS else { return .nan }

    func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }
    return seconds(info.user_time) + seconds(info.system_time)
}

@MainActor
private func measuringMainThread<T>(
    _ body: () async throws -> T
) async rethrows -> (value: T, occupancy: MainThreadOccupancy) {
    let cpuStart = mainThreadCPUSeconds()
    let clockStart = ContinuousClock.now
    let value = try await body()
    let elapsed = clockStart.duration(to: .now)
    let cpu = mainThreadCPUSeconds() - cpuStart

    let wall = Double(elapsed.components.seconds)
        + Double(elapsed.components.attoseconds) / 1e18
    return (value, MainThreadOccupancy(wallSeconds: wall, cpuSeconds: cpu))
}

/// A sink the optimiser cannot discard, so `burnMainThreadCPU` really burns.
nonisolated(unsafe) private var cpuBurnSink: UInt64 = 0

/// Occupies whatever thread calls it, computing, for `duration`.
private func burnCPU(for duration: Duration) {
    let deadline = ContinuousClock.now + duration
    var accumulator: UInt64 = 0
    while ContinuousClock.now < deadline {
        accumulator = accumulator &+ 1
    }
    cpuBurnSink = cpuBurnSink &+ accumulator
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

    // MARK: A second writer

    @Test("a save refuses when something else changed the file after it was loaded")
    func externalChangeIsRefusedNotClobbered() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "db.internal")

        // Something else writes the same file while it is open here. This is
        // the real `sops set`, not a simulation of one.
        try cliSet(fileURL, key: key, path: "[\"added_elsewhere\"]", value: "\"from-another-writer\"")

        let outcome = await vm.save()

        guard case .failed(let message) = outcome else {
            Issue.record("expected the save to refuse, got \(outcome)")
            return
        }
        #expect(
            message.lowercased().contains("changed"),
            Comment(rawValue: "the message has to tell the user what happened: \(message)"))

        // The other writer's key is still in the file. This is the assertion
        // the whole finding is about: before this change the save reported
        // success and `added_elsewhere` was gone.
        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(
            decrypted.contains("added_elsewhere"),
            "the external writer's key must still be on disk")
        #expect(
            !decrypted.contains("db.internal"),
            "the refused save must not have landed either")

        // And the user's own edit is still where they left it, unsaved.
        #expect(vm.isDirty)
        #expect(try row(vm, "db", "host").value == "db.internal")
    }

    @Test("a save is allowed again once the document is reloaded from the changed file")
    func reloadingClearsTheRefusal() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        try cliSet(fileURL, key: key, path: "[\"added_elsewhere\"]", value: "\"from-another-writer\"")

        // Reload is the remediation the refusal points at, so it has to
        // actually work — a refusal the user cannot clear is a stuck editor.
        await vm.load()
        #expect(vm.loadState == .loaded)
        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "db.internal")

        let outcome = await vm.save()

        #expect(outcome == .saved)
        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(decrypted.contains("db.internal"))
        #expect(decrypted.contains("added_elsewhere"), "the other writer's key survives the save")
    }

    @Test("two saves in a row both land: the first one's own write is not read as a foreign change")
    func consecutiveSavesBothLand() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()

        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "first")
        #expect(await vm.save() == .saved)

        // The whole point of tracking the fingerprint the *writer* produced
        // rather than re-reading the file afterwards: this second save must
        // not mistake the first save's own bytes for a second writer's.
        vm.update(rowID: hostID, to: "second")
        #expect(await vm.save() == .saved)

        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(decrypted.contains("host: second"))
    }

    /// The one test that tells the two candidate implementations apart.
    ///
    /// After a save, the baseline fingerprint can come from the receipt the
    /// writer produced, or from a fresh `stat` of the file. In the quiet case
    /// those are identical, so no ordinary test can distinguish them. They
    /// differ exactly when a second writer lands *immediately after* this
    /// app's own write: re-`stat`ing adopts that writer's file as this
    /// document's baseline and the next save deletes their work — the original
    /// hole, one write later. Taking the receipt's value leaves the baseline
    /// describing the bytes this app actually wrote, so the next save refuses.
    ///
    /// The `writeFile` injection here is what makes that ordering
    /// deterministic instead of a race.
    @Test("a writer that lands right after this app's own save is still caught")
    func writerLandingImmediatelyAfterTheSaveIsCaught() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let store = SessionKeyStore()
        try store.importKey(key.private)

        let vm = SecretDocumentViewModel(
            fileURL: fileURL, keyStore: store,
            writeFile: { contents, url, expecting in
                let receipt = try AtomicFileWriter.write(contents, to: url, expecting: expecting)
                // The other writer gets in between this save finishing and
                // the next one starting.
                try cliSet(url, key: key, path: "[\"added_elsewhere\"]", value: "\"squeezed-in\"")
                return receipt.fingerprint
            })
        await vm.load()

        let hostID = try row(vm, "db", "host").id
        vm.update(rowID: hostID, to: "first")
        #expect(await vm.save() == .saved)

        vm.update(rowID: hostID, to: "second")
        let outcome = await vm.save()

        guard case .failed = outcome else {
            Issue.record("expected the second save to refuse, got \(outcome)")
            return
        }
        let decrypted = try cliDecrypt(fileURL, key: key)
        #expect(decrypted.contains("added_elsewhere"), "the other writer's key must survive")
        #expect(!decrypted.contains("host: second"))
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
            writeFile: { _, _, _ in throw WriteBoom() })
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
            writeFile: { contents, url, _ in
                writeWasCalled = true
                try contents.write(to: url, atomically: true, encoding: .utf8)
                return FileFingerprint.of(url)
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
            writeFile: { _, _, _ in throw WriteBoom() })
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

    /// The property: `load()` and `save()` must do the bridge's CPU work
    /// somewhere other than the main actor, so a window stays responsive while
    /// a large document is decrypted or re-encrypted.
    ///
    /// Asserted on how much CPU the **main thread itself** burned during the
    /// call — see `MainThreadOccupancy` for why, and for what the heartbeat
    /// this replaced was actually certifying (0.15% of the scheduling it
    /// demanded). The heartbeat is still counted and printed, because the M2
    /// report quotes those numbers; nothing depends on them.
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

        let (_, loading) = await measuringMainThread { await vm.load() }
        #expect(vm.loadState == .loaded)

        let firstRowID = try #require(vm.rows.first).id
        vm.update(rowID: firstRowID, to: "changed-value")
        #expect(vm.isDirty)

        let (outcome, saving) = await measuringMainThread { await vm.save() }
        #expect(outcome == .saved)

        heartbeat.cancel()
        let finalTicks = await ticks.count

        print("=== PERFORMANCE: \(keyCount) keys, \(fileSize) bytes on disk ===")
        print("  load(): \(loading.description)")
        print("  save(): \(saving.description)")
        print("  MainActor heartbeat ticks during load()+save(): \(finalTicks)")

        // The assertion. A bridge call moved back onto the main actor drives
        // these to ~1.0 — the work is CPU-bound and there is nowhere else for
        // it to be charged. Correct offloading leaves only the row-building
        // this type genuinely does on the main actor, a few percent of the
        // call. `mainActorInstrumentDiscriminates` proves the instrument can
        // tell those apart; `blockedMainThreadFraction` sits between them with
        // room on both sides.
        //
        // Not asserted under a sanitizer — see `isRunningUnderThreadSanitizer`
        // for the measurements. The numbers are still printed above, so a TSan
        // run is not silent about them, it just does not fail on a ratio the
        // instrumentation itself moved.
        guard !isRunningUnderThreadSanitizer else {
            print("  (occupancy not asserted: this binary is instrumented, which changes the ratio)")
            return
        }
        #expect(loading.fraction < blockedMainThreadFraction, Comment(rawValue:
            "load() spent \(loading.description) — the main thread did the bridge's work itself, "
            + "so a window would have been frozen for the whole call"))
        #expect(saving.fraction < blockedMainThreadFraction, Comment(rawValue:
            "save() spent \(saving.description) — the main thread did the bridge's work itself, "
            + "so a window would have been frozen for the whole call"))
    }

    /// The instrument's own test, and the reason the assertion above is worth
    /// anything: an occupancy measurement that cannot tell a blocked main
    /// thread from a busy machine would be the tick counter all over again.
    ///
    /// Neither control touches `SecretDocumentViewModel` — they are a known
    /// block and a known non-block of the same size, so this stays true
    /// whatever the view model does next.
    @Test("the main-actor instrument tells a blocked main actor from a busy machine")
    func mainActorInstrumentDiscriminates() async throws {
        let burn = Duration.milliseconds(300)

        // Positive control: the work happens on the main actor. This is what a
        // bridge call reverted to `runOffCooperativePool { … }()` — or to any
        // synchronous call — looks like from here.
        let (_, blocked) = await measuringMainThread { burnCPU(for: burn) }
        // Not `> 0.8`. That was an absolute claim about *this machine's
        // scheduling*, and the whole suite runs in one process under the
        // open-source toolchain: with 99 suites in flight the main thread is
        // descheduled often enough that a genuinely blocking call measured
        // 0.55, and the test that exists to prove the instrument is not
        // measuring machine load failed because it was measuring machine load.
        // Measured, in a full `swift test` run.
        //
        // What this test is named for is *discrimination*, and that is what is
        // asserted below: the two controls must land on opposite sides of the
        // threshold and far apart. The floor here only catches an instrument
        // that has stopped reporting main-thread CPU at all.
        #expect(blocked.fraction > blockedMainThreadFraction, Comment(rawValue:
            "the instrument did not see a main thread that was busy for the entire window: "
            + blocked.description))

        // Negative control: identical work, identical duration, off the main
        // actor. Suite parallelism can only stretch the wall time here, which
        // pushes the fraction further down — it cannot invent main-thread CPU.
        let (_, offloaded) = await measuringMainThread {
            await Task.detached { burnCPU(for: burn) }.value
        }
        #expect(offloaded.fraction < blockedMainThreadFraction, Comment(rawValue:
            "the instrument reported a block for work that ran on a detached task, so it is "
            + "measuring machine load rather than main-thread occupancy: " + offloaded.description))

        print("=== INSTRUMENT: on main actor \(blocked.description); off main actor \(offloaded.description) ===")

        // The claim this test is named for: the two controls are on opposite
        // sides of the threshold the test above uses, and far enough apart that
        // no amount of machine load could swap them.
        #expect(offloaded.fraction < blocked.fraction / 2, Comment(rawValue:
            "blocked and offloaded work were not distinguishable: "
            + blocked.description + " vs " + offloaded.description))
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

/// Task 10's writer, exercised through the app's *real* save path — no
/// injected `writeFile`.
///
/// This suite exists because a writer nobody calls is not the task. Each test
/// here is chosen so that the placeholder `String.write(to:atomically:)` this
/// replaced would fail it, which is what makes them evidence of the wiring
/// rather than a second copy of `AtomicFileWriterTests`.
@Suite("SecretDocumentViewModel — the default save path is the atomic writer")
@MainActor
struct SecretDocumentViewModelAtomicSaveTests {

    private func row(_ vm: SecretDocumentViewModel, _ path: String...) throws -> SecretRow {
        guard let found = vm.rows.first(where: { $0.path == path }) else {
            throw FixtureError("no row at \(path); present: \(vm.rows.map { $0.path.joined(separator: ".") })")
        }
        return found
    }

    /// Open the document *through a symlink* and save. The link must still be
    /// a link and its target must hold the new ciphertext.
    ///
    /// The old default (`String.write(to:atomically:encoding:)`) replaces the
    /// link with a regular file and leaves the target on the old contents —
    /// verified directly on this machine — so this test failing red is the
    /// signal that the default writer went back to being the placeholder.
    @Test("saving through a symlink updates the target and leaves the link a link")
    func saveThroughSymlinkKeepsTheLink() async throws {
        let key = try AgeKeyPair.generate()
        let target = try encryptedFixture(sampleYAML, key: key)
        let linkDirectory = try scratchDirectory("symlinked-project")
        let link = linkDirectory.appendingPathComponent("secrets.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: link, keyStore: store)
        await vm.load()
        #expect(vm.loadState == .loaded)
        vm.update(rowID: try row(vm, "db", "host").id, to: "db.internal")

        #expect(await vm.save() == .saved)

        let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
        #expect(type == .typeSymbolicLink, "the save replaced the symlink with a regular file")
        let stillPointsAt = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        #expect(stillPointsAt == target.path)
        // The real file — the one everything else on the machine sees —
        // actually changed.
        #expect(try cliDecrypt(target, key: key).contains("db.internal"))
    }

    @Test("saving preserves the document's POSIX permissions")
    func savePreservesPermissions() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        vm.update(rowID: try row(vm, "db", "host").id, to: "db.internal")
        #expect(await vm.save() == .saved)

        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let resulting = (attributes[.posixPermissions] as? NSNumber)?.intValue
        #expect(resulting == 0o600, "the save widened or narrowed the file's permissions")
    }

    /// A read-only document fails the save with the writer's own message, the
    /// bytes on disk are untouched, and the user's edit is still sitting in
    /// `rows` marked dirty.
    ///
    /// Also pins the message routing: `save()` forwards
    /// `AtomicFileWriter.Error.description` verbatim precisely because it is
    /// built from a path and an `errno` and can never contain a value, and
    /// "not writable" versus "could not create a temporary file next to" send
    /// the user to two different places.
    @Test("a read-only document fails the save and says why, leaving the file alone")
    func readOnlyDocumentFailsTheSave() async throws {
        let key = try AgeKeyPair.generate()
        let fileURL = try encryptedFixture(sampleYAML, key: key)
        let before = try String(contentsOf: fileURL, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: fileURL.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let vm = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await vm.load()
        vm.update(rowID: try row(vm, "db", "host").id, to: "never-lands")

        guard case .failed(let message) = await vm.save() else {
            Issue.record("a read-only file must not report a successful save")
            return
        }
        #expect(message.contains("is not writable"), Comment(rawValue: message))
        #expect(!message.contains("never-lands"), "the error must not carry the edited value")
        #expect(vm.isDirty, "the edit must still be reported as unsaved")
        #expect(try String(contentsOf: fileURL, encoding: .utf8) == before, "the file was modified")
    }
}

/// A document that has all three of the things sops treats differently when it
/// decides what to encrypt: an ordinary value, an empty string, and a null.
/// sops encrypts the first and neither of the other two, which is what makes
/// this the fixture the padlock gets wrong.
private let padlockYAML = """
    filled: an-ordinary-EXAMPLE-value
    blank: ""
    nothing: null

    """

/// What the padlock next to each row claims, against what the file says.
///
/// `SecretRow.isEncrypted` is the app's answer to "is this value protected",
/// rendered as `lock.fill`/`lock.open` with the accessibility labels
/// `editorValueEncrypted`/`editorValueNotEncrypted` (`SecretEditorView`). It is
/// not decoration, and it is the kind of claim that is only worth anything if
/// it is true every time — a padlock that is right nine times out of ten is
/// worse than none, because the tenth is the one the user acts on.
///
/// It was wrong in a reachable, ordinary case. A save that changed no keys used
/// to re-adopt the rows already in memory and carry `isEncrypted` over from
/// before the write. sops does not encrypt an empty string, so `blank: ""`
/// loads as not-encrypted; type a real value into it, save, and the file holds
/// `ENC[…]` while the editor goes on saying, in words, that the value is not
/// encrypted — until a reload.
///
/// Every test here checks the model against **the file itself**, either by
/// reading the ciphertext or by loading it again from scratch. Asserting the
/// model against another part of the model would have passed throughout.
@Suite("SecretDocumentViewModel — what the padlock claims")
@MainActor
struct SecretDocumentPadlockTests {

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

    /// Loads the same file again, from scratch, and returns its rows — the
    /// file's own answer, produced by the same bridge call `load()` uses.
    private func rowsAsTheFileHasThem(_ fileURL: URL, key: AgeKeyPair) async throws -> [SecretRow] {
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let fresh = SecretDocumentViewModel(fileURL: fileURL, keyStore: store)
        await fresh.load()
        #expect(fresh.loadState == .loaded, "the saved file could not be read back")
        return fresh.rows
    }

    /// The premise, checked rather than assumed: if sops started encrypting
    /// empty strings, every test below would be testing nothing.
    @Test("the fixture really does load with an empty value reported as unencrypted")
    func fixturePremiseHolds() async throws {
        let (vm, _, _) = try await loaded(padlockYAML)
        #expect(try row(vm, "filled").isEncrypted, "an ordinary value must load as encrypted")
        #expect(try !row(vm, "blank").isEncrypted, "sops does not encrypt an empty string")
        #expect(try !row(vm, "nothing").isEncrypted, "sops does not encrypt a null")
    }

    /// The finding. One edit, no keys added or removed, and the padlock lies.
    @Test("filling in an empty value and saving stops claiming the value is unencrypted")
    func fillingAnEmptyValueUpdatesThePadlock() async throws {
        let (vm, key, fileURL) = try await loaded(padlockYAML)
        vm.update(rowID: try row(vm, "blank").id, to: "now-a-real-EXAMPLE-value")

        #expect(await vm.save() == .saved)

        // The file's answer first, so the expectation below is anchored to
        // something outside the object under test.
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk.contains("blank: ENC["),
                "the fixture did not actually encrypt the new value, so this proves nothing")
        #expect(try row(vm, "blank").isEncrypted,
                "the editor says this value is not encrypted; the file says ENC[…]")
        #expect(try await rowsAsTheFileHasThem(fileURL, key: key).contains {
            $0.path == ["blank"] && $0.isEncrypted
        })
    }

    /// The reverse, and the one that costs more: a closed padlock over a value
    /// that is sitting in the file as plaintext.
    @Test("clearing an encrypted value stops claiming the value is still encrypted")
    func clearingAValueUpdatesThePadlock() async throws {
        let (vm, key, fileURL) = try await loaded(padlockYAML)
        vm.update(rowID: try row(vm, "filled").id, to: "")

        #expect(await vm.save() == .saved)

        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(!onDisk.contains("filled: ENC["),
                "the fixture did not actually leave the value in the clear, so this proves nothing")
        #expect(try !row(vm, "filled").isEncrypted,
                "the editor shows a closed padlock over a value the file holds in the clear")
        #expect(try await rowsAsTheFileHasThem(fileURL, key: key).contains {
            $0.path == ["filled"] && !$0.isEncrypted
        })
    }

    /// The general property the two cases above are instances of, stated once
    /// so a future fast path cannot reintroduce the class of bug by finding a
    /// case neither of them happens to cover: **after any save, every row the
    /// editor is showing is exactly the row a fresh load of that file
    /// produces** — path, value, kind, list membership and padlock.
    @Test("after a save, every row matches what a fresh load of the saved file reports")
    func savedRowsMatchTheFileExactly() async throws {
        let (vm, key, fileURL) = try await loaded(padlockYAML)
        vm.update(rowID: try row(vm, "blank").id, to: "filled-in-EXAMPLE")
        vm.update(rowID: try row(vm, "filled").id, to: "")
        vm.update(rowID: try row(vm, "nothing").id, to: "no-longer-null-EXAMPLE")

        #expect(await vm.save() == .saved)

        let fromFile = try await rowsAsTheFileHasThem(fileURL, key: key)
        // Padlock state only in the message — never a value.
        let onScreen = vm.rows.map { "\($0.path)=\($0.isEncrypted)" }
        let inFile = fromFile.map { "\($0.path)=\($0.isEncrypted)" }
        #expect(vm.rows == fromFile,
                "the editor and the file disagree: \(onScreen) vs \(inFile)")
    }

    /// The same property for a save that *did* change the shape, which always
    /// re-read the file and so was never wrong — pinned so the two branches
    /// cannot drift apart again now that there is only one of them.
    @Test("a shape-changing save matches the file exactly too")
    func structuralSaveRowsMatchTheFileExactly() async throws {
        let (vm, key, fileURL) = try await loaded(padlockYAML)
        let destination = vm.addDestination(forSelectedRowID: nil)
        guard case .added = vm.addRow(
            in: destination, key: "added", kind: .string, value: "added-EXAMPLE-value")
        else {
            Issue.record("the fixture add was refused")
            return
        }
        vm.removeRow(id: try row(vm, "nothing").id)

        #expect(await vm.save() == .saved)

        #expect(vm.rows == (try await rowsAsTheFileHasThem(fileURL, key: key)))
    }
}

