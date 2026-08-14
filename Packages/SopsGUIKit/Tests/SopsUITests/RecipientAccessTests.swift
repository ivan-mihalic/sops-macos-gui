import Foundation
import ScratchCleanup
import Testing
import SopsEngine
import SopsHealth
import SopsProjects
@testable import SopsUI

// MARK: - Fixture plumbing
//
// Encrypted fixtures go through the real in-process bridge
// (`SopsBridge.encryptYAML`), not a hand-written string — the same discipline
// `RecipientManagementTests` (Task 1) established for this exact surface.
// Only key generation shells out, because there is no in-process keygen.

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

private func scratchDirectory(_ label: String = "recipient-access") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Writes `encrypted` to a fresh scratch file and returns its URL.
private func fixtureFile(_ encrypted: String) throws -> URL {
    let dir = try scratchDirectory()
    let url = dir.appendingPathComponent("secret.yaml")
    try encrypted.write(to: url, atomically: true, encoding: .utf8)
    return url
}

/// Modifies `url` with the real `sops set` CLI — a genuine second writer
/// (`git pull`, `sops updatekeys`, a second instance of this app, or
/// literally this), the same real-external-writer technique
/// `SecretDocumentViewModelTests.cliSet` uses to prove the identical
/// second-writer guard on the editor's own save path.
private func cliSet(_ url: URL, key: AgeKeyPair, path: String, value: String) throws {
    let dir = try scratchDirectory("cli-set")
    let keysURL = dir.appendingPathComponent("keys.txt")
    try (key.private + "\n").write(to: keysURL, atomically: true, encoding: .utf8)
    try run(
        try toolPath("sops"), ["set", url.path, path, value],
        environment: ["SOPS_AGE_KEY_FILE": keysURL.path])
}

// sops's own YAML emitter normalizes indentation to 4 spaces regardless of
// what was encrypted, so a round-trip fixture must already be in that shape
// or a byte-equality check against the re-decrypted text fails on
// indentation alone, not on anything this model got wrong — the same
// canonical form `Tests/SopsEngineTests/CompatibilityTests.swift` uses for
// exactly this reason.
private let plainYAML = "database:\n    password: correct-horse-battery-staple\n"

@Suite("RecipientAccessModel — staged edits never touch disk")
@MainActor
struct RecipientAccessStagingTests {

    @Test("adding and removing a recipient in memory writes nothing to disk")
    func stagingIsInMemoryOnly() async throws {
        let owner = try AgeKeyPair.generate()
        let kept = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()

        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public, kept.public])
        let fileURL = try fixtureFile(encrypted)
        let bytesBeforeStaging = try String(contentsOf: fileURL, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)

        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()
        #expect(model.loadState == .loaded)
        #expect(Set(model.currentRecipients) == Set([owner.public, kept.public]))

        model.stageAdd(added.public)
        model.stageRemove(owner.public)

        // Staged state is visible on the model...
        #expect(Set(model.stagedRecipients) == Set([kept.public, added.public]))
        #expect(model.isDirty)
        let removalEntry = model.entries.first { $0.ageRecipient == owner.public }
        #expect(removalEntry?.status == .pendingRemoval)
        let additionEntry = model.entries.first { $0.ageRecipient == added.public }
        #expect(additionEntry?.status == .pendingAddition)

        // ...but the file on disk, and the recipients a fresh read of it
        // reports, are exactly what they were before any staging happened.
        let bytesAfterStaging = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(bytesAfterStaging == bytesBeforeStaging)
        #expect(try SopsBridge.recipients(in: bytesAfterStaging) == [owner.public, kept.public])
    }

    @Test("discarding staged changes returns to the loaded baseline")
    func discardRestoresBaseline() async throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        let stranger = try AgeKeyPair.generate()
        model.stageAdd(stranger.public)
        model.stageRemove(owner.public)
        #expect(model.isDirty)

        model.discardStagedChanges()
        #expect(!model.isDirty)
        #expect(model.stagedRecipients == model.currentRecipients)
    }

    @Test("adding a recipient already staged is refused as a duplicate")
    func refusesDuplicateStagedRecipient() async throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        #expect(model.stageAdd(owner.public) == .duplicate)
        #expect(model.stageAdd("   ") == .empty)
    }

    @Test("stageAdd before any load is refused as not loaded")
    func stageAddBeforeLoadIsRefused() {
        let keyStore = SessionKeyStore()
        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/never-loaded.yaml"), projectURL: nil, keyStore: keyStore)
        #expect(model.stageAdd("age1anything") == .notLoaded)
    }

    /// Finding I2: `stageRemove` deletes in place and `stageAdd` appends, so
    /// undoing a removal by re-adding the same recipient — exactly what
    /// `RecipientAccessRow`'s toggle button does for a `.pendingRemoval`
    /// row — reorders `stagedRecipients` without changing what is staged.
    /// An array-equality `isDirty` read that reorder as a real change: with
    /// `currentRecipients == [owner, kept]`, `stageRemove(owner)` →
    /// `[kept]`, then the undo `stageAdd(owner)` → `[kept, owner]` — same
    /// members, different order, `!=` as arrays. That enabled Apply for a
    /// no-op and would have performed a real `updateRecipients` rewrap and
    /// disk write (new MAC, new `lastmodified`) for a set that never
    /// changed, with no confirmation dialog either — `pendingRemovals` is
    /// empty for `.unchanged` entries, so the destructive-removal gate never
    /// fires.
    @Test("removing a recipient and then re-adding it — the row toggle's undo — leaves the document clean")
    func removeThenReAddViaUndoIsNotDirty() async throws {
        let owner = try AgeKeyPair.generate()
        let kept = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public, kept.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()
        #expect(model.currentRecipients == [owner.public, kept.public])

        model.stageRemove(owner.public)
        model.stageAdd(owner.public)

        #expect(
            !model.isDirty,
            "same membership, only reordered by this type's own add/remove pair — not a change")
        #expect(model.pendingRemovals.isEmpty)
        #expect(model.entries.allSatisfy { $0.status == .unchanged })

        // Offered this no-op, Apply must not touch the bridge or the file —
        // the same guarantee `applyIsANoOpWhenNothingIsStagedAndSkipsBothSeams`
        // pins with call-counted seams below.
        let outcome = await model.apply()
        #expect(outcome == .applied)
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(onDisk == encrypted, "a same-membership reorder must never trigger a real rewrap or write")
    }
}

@Suite("RecipientAccessModel — pendingRemovals is the destructive-dialog gate")
@MainActor
struct RecipientAccessPendingRemovalsTests {

    @Test("pendingRemovals reports exactly the entries staged for removal, nothing more")
    func reportsExactlyStagedRemovals() async throws {
        let owner = try AgeKeyPair.generate()
        let kept = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(
            plainYAML, recipients: [owner.public, kept.public, removed.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        // Nothing staged yet: nothing pending removal.
        #expect(model.pendingRemovals.isEmpty)

        model.stageAdd(added.public)
        model.stageRemove(removed.public)

        #expect(model.pendingRemovals.map(\.ageRecipient) == [removed.public])
        #expect(model.pendingRemovals.allSatisfy { $0.status == .pendingRemoval })

        // Undoing the removal clears the gate again.
        model.stageAdd(removed.public)
        #expect(model.pendingRemovals.isEmpty)
    }
}

@Suite("RecipientAccessModel — apply calls the rewrap bridge and only that")
@MainActor
struct RecipientAccessApplyTests {

    @Test("apply rewraps to exactly the staged set and persists atomically")
    func applyRewrapsAndPersists() async throws {
        let owner = try AgeKeyPair.generate()
        let kept = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()

        let encrypted = try SopsBridge.encryptYAML(
            plainYAML, recipients: [owner.public, kept.public, removed.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        model.stageAdd(added.public)
        model.stageRemove(removed.public)

        let outcome = await model.apply()
        #expect(outcome == .applied)
        #expect(!model.isDirty)
        #expect(Set(model.currentRecipients) == Set([owner.public, kept.public, added.public]))

        // The bridge actually rewrapped the data key: the new file decrypts
        // for every recipient in the new set and not for the removed one.
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(try SopsBridge.decryptYAML(onDisk, agePrivateKey: owner.private) == plainYAML)
        #expect(try SopsBridge.decryptYAML(onDisk, agePrivateKey: kept.private) == plainYAML)
        #expect(try SopsBridge.decryptYAML(onDisk, agePrivateKey: added.private) == plainYAML)
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.decryptYAML(onDisk, agePrivateKey: removed.private)
        }

        // A fresh read reports exactly the applied set, proving this is real
        // metadata on disk and not just in-memory bookkeeping.
        let reloaded = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await reloaded.load()
        #expect(Set(reloaded.currentRecipients) == Set([owner.public, kept.public, added.public]))
    }

    @Test("removing every recipient is refused before the bridge or disk is touched")
    func refusesEmptyRecipientSet() async throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let fileURL = try fixtureFile(encrypted)
        let bytesBefore = try String(contentsOf: fileURL, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        model.stageRemove(owner.public)
        #expect(model.stagedRecipients.isEmpty)

        let outcome = await model.apply()
        #expect(outcome == .refusedEmptyRecipients)

        let bytesAfter = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(bytesAfter == bytesBefore)
        #expect(try SopsBridge.recipients(in: bytesAfter) == [owner.public])
    }

    @Test("reading recipients needs no session key, but apply does and explains why")
    func readingNeedsNoKeyApplyDoes() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let fileURL = try fixtureFile(encrypted)
        let bytesBefore = try String(contentsOf: fileURL, encoding: .utf8)

        // No key imported at all.
        let keyStore = SessionKeyStore()
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        #expect(model.loadState == .loaded)
        #expect(model.currentRecipients == [owner.public])
        #expect(!model.keyConfigured)

        model.stageAdd(added.public)
        let outcome = await model.apply()
        #expect(outcome == .refusedNoKey)

        let bytesAfter = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(bytesAfter == bytesBefore)
    }
}

@Suite("RecipientAccessModel — registry label fallback")
@MainActor
struct RecipientAccessRegistryTests {

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipient-access-project-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    @Test("a recipient present in the registry shows its label; an unknown one shows its public key")
    func labelsKnownRecipientsAndFallsBackForUnknownOnes() async throws {
        let known = try AgeKeyPair.generate()
        let unknown = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [known.public, unknown.public])
        let fileURL = try fixtureFile(encrypted)

        let project = try makeProject()
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Laptop", kind: .device, ageRecipient: known.public), in: project)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(known.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()

        let knownEntry = model.entries.first { $0.ageRecipient == known.public }
        #expect(knownEntry?.label == "Laptop")
        let unknownEntry = model.entries.first { $0.ageRecipient == unknown.public }
        // The unknown recipient must never be hidden — it is identified by
        // its raw public key rather than dropped from the list.
        #expect(unknownEntry != nil)
        #expect(unknownEntry?.label == nil)
    }

    /// #27 item 5, exercised through this model's real default `loadRegistry`
    /// rather than an injected seam — the same property `ProjectAccessTests
    /// .corruptRegistrySurfacesAQuarantineNotice` proves for the sibling
    /// model.
    @Test("a corrupt registry surfaces a quarantine notice, and recipients still show unlabelled")
    func corruptRegistrySurfacesAQuarantineNotice() async throws {
        let known = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [known.public])
        let fileURL = try fixtureFile(encrypted)

        let project = try makeProject()
        let registryDirectory = project.appendingPathComponent(".sops-gui", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data(#"{"records": "not an array"}"#.utf8)
            .write(to: registryDirectory.appendingPathComponent("recipients.json"))

        let keyStore = SessionKeyStore()
        try keyStore.importKey(known.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()

        #expect(model.registryQuarantineNotice != nil)
        #expect(model.entries.first?.ageRecipient == known.public)
        #expect(model.entries.first?.label == nil)
        #expect(!FileManager.default.fileExists(
            atPath: registryDirectory.appendingPathComponent("recipients.json").path))
    }

    @Test("a file with no project still shows every recipient by public key")
    func noProjectMeansNoLabelsButNothingHidden() async throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()

        #expect(model.entries.count == 1)
        #expect(model.entries.first?.label == nil)
        #expect(model.entries.first?.ageRecipient == owner.public)
    }

    // MARK: - Rotation debt (ticket #3)

    @Test("removing a recipient and applying records that this file now owes a rotation")
    func applyingARemovalRecordsRotationDebt() async throws {
        let owner = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public, removed.public])
        let project = try makeProject()
        let fileURL = project.appendingPathComponent("secrets/app.yaml")
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encrypted.write(to: fileURL, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()
        model.stageRemove(removed.public)

        let outcome = await model.apply()
        #expect(outcome == .applied)

        let debt = try RotationDebtLedger.load(in: project)
        #expect(debt.count == 1)
        #expect(debt.first?.path == "secrets/app.yaml")
        #expect(debt.first?.reason == .recipientRemoved)
    }

    @Test("adding a recipient without removing one records no rotation debt")
    func applyingAnAdditionOnlyRecordsNoRotationDebt() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let project = try makeProject()
        let fileURL = project.appendingPathComponent("app.yaml")
        try encrypted.write(to: fileURL, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)

        let outcome = await model.apply()
        #expect(outcome == .applied)

        #expect(try RotationDebtLedger.load(in: project).isEmpty)
    }

    @Test("a loaded panel shows the rotation debt already recorded for this exact file")
    func loadShowsExistingRotationDebt() async throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let project = try makeProject()
        let fileURL = project.appendingPathComponent("app.yaml")
        try encrypted.write(to: fileURL, atomically: true, encoding: .utf8)
        try RotationDebtLedger.record(path: "app.yaml", reason: .recipientRemoved, in: project)
        // A debt recorded for a *different* file must not bleed into this one.
        try RotationDebtLedger.record(path: "other.yaml", reason: .recipientRemoved, in: project)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()

        #expect(model.rotationDebtEntries.map(\.path) == ["app.yaml"])
    }

    @Test("acknowledging a rotation debt clears it from the panel and the ledger")
    func acknowledgeClearsDebt() async throws {
        let owner = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let project = try makeProject()
        let fileURL = project.appendingPathComponent("app.yaml")
        try encrypted.write(to: fileURL, atomically: true, encoding: .utf8)
        try RotationDebtLedger.record(path: "app.yaml", reason: .recipientRemoved, in: project)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()
        let id = try #require(model.rotationDebtEntries.first?.id)

        model.acknowledgeRotationDebt(id)

        #expect(model.rotationDebtEntries.isEmpty)
        #expect(try RotationDebtLedger.load(in: project).isEmpty)
    }

    @Test("applying a removal makes the new rotation debt show up immediately, without reloading")
    func applyRefreshesRotationDebtWithoutAReload() async throws {
        let owner = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public, removed.public])
        let project = try makeProject()
        let fileURL = project.appendingPathComponent("app.yaml")
        try encrypted.write(to: fileURL, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: project, keyStore: keyStore)
        await model.load()
        #expect(model.rotationDebtEntries.isEmpty)
        model.stageRemove(removed.public)

        #expect(await model.apply() == .applied)

        #expect(model.rotationDebtEntries.map(\.path) == ["app.yaml"])
    }

    @Test("a file opened without a project records no rotation debt anywhere")
    func removalWithoutAProjectRecordsNothing() async throws {
        let owner = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public, removed.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()
        model.stageRemove(removed.public)

        let outcome = await model.apply()
        #expect(outcome == .applied)
        // Nothing to assert against a ledger — there is no project to hold
        // one. This test's job is only to prove `apply()` does not crash or
        // throw when `projectURL` is nil.
    }
}

// MARK: - Seam injection
//
// Every test above drives `RecipientAccessModel` through its default
// `readFile`/`fingerprintFile`/`writeFile`/`loadRegistry`/`rewrapRecipients`
// seams against real files and the real bridge. None of them substitutes a
// seam — so "apply calls only `updateRecipients`" was, until here, provable
// only by inference (decrypting the result). This suite injects each seam
// directly: `rewrapRecipients` to prove exactly what apply() calls and with
// what arguments, `writeFile` to prove a write/second-writer failure leaves
// state untouched without needing a real disk race, `readFile` to prove a
// read failure surfaces correctly without filesystem permission tricks, and
// `loadRegistry` to prove labels come from whatever is injected rather than
// a real `.sops-gui/recipients.json`. `SaveFailureKeepsChangesTests`
// established this fake-`/dev/null`-URL-plus-injected-`readFile` shape for
// `SecretDocumentViewModel`; this mirrors it here.

@Suite("RecipientAccessModel — seam injection proves apply's one bridge call and its failure handling")
@MainActor
struct RecipientAccessSeamTests {

    /// A model over a fake, never-real path — `readFile` supplies the
    /// document, so nothing here ever touches disk unless a test's own
    /// `writeFile` chooses to.
    private func fakeModel(
        recipients: [String],
        readFile: ((URL) throws -> String)? = nil,
        writeFile: @escaping (String, URL, FileFingerprint?) throws -> FileFingerprint? = { _, _, _ in nil },
        rewrapRecipients: @escaping (String, [String], String) async throws -> String = { contents, recipients, key in
            try await RecipientAccessModel.defaultRewrap(contents, recipients, key)
        },
        loadRegistry: @escaping (URL) -> (records: [RecipientRecord], quarantineNotice: String?) = { _ in ([], nil) },
        keyStore: SessionKeyStore
    ) throws -> RecipientAccessModel {
        // Only encrypted when no `readFile` override is supplied — a test
        // that overrides `readFile` to fail before ever touching content
        // (e.g. `readFailureSurfacesAsFailedLoad`) may pass a `recipients`
        // list that is not a real age key at all, since it is never encoded.
        let resolvedReadFile: (URL) throws -> String
        if let readFile {
            resolvedReadFile = readFile
        } else {
            let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: recipients)
            resolvedReadFile = { _ in encrypted }
        }
        return RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/access-seam-\(UUID().uuidString).yaml"),
            projectURL: URL(fileURLWithPath: "/dev/null/never-read-project"),
            keyStore: keyStore,
            readFile: resolvedReadFile,
            writeFile: writeFile,
            loadRegistry: loadRegistry,
            rewrapRecipients: rewrapRecipients)
    }

    @Test("apply calls the rewrap seam exactly once, with exactly the staged recipients")
    func applyCallsTheRewrapSeamExactlyOnceWithTheStagedSet() async throws {
        let owner = try AgeKeyPair.generate()
        let kept = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let removed = try AgeKeyPair.generate()

        var calls: [(contents: String, recipients: [String], key: String)] = []
        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = try fakeModel(
            recipients: [owner.public, kept.public, removed.public],
            rewrapRecipients: { contents, recipients, key in
                // Invoked on `@MainActor` — the default implementation is
                // the only thing that hops off it — so this plain, mutable
                // capture is sound without a lock.
                calls.append((contents, recipients, key))
                return try await RecipientAccessModel.defaultRewrap(contents, recipients, key)
            },
            keyStore: keyStore)
        await model.load()

        model.stageAdd(added.public)
        model.stageRemove(removed.public)
        let outcome = await model.apply()

        #expect(outcome == .applied)
        #expect(calls.count == 1, "apply must call the rewrap seam exactly once")
        #expect(calls.first?.recipients == [owner.public, kept.public, added.public])
        #expect(calls.first?.key == owner.private)
    }

    @Test("apply is a no-op when nothing is staged, and skips both the rewrap and write seams")
    func applyIsANoOpWhenNothingIsStagedAndSkipsBothSeams() async throws {
        let owner = try AgeKeyPair.generate()
        var rewrapCalls = 0
        var writeCalls = 0
        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = try fakeModel(
            recipients: [owner.public],
            writeFile: { _, _, _ in
                writeCalls += 1
                return nil
            },
            rewrapRecipients: { contents, recipients, key in
                rewrapCalls += 1
                return try await RecipientAccessModel.defaultRewrap(contents, recipients, key)
            },
            keyStore: keyStore)
        await model.load()
        try #require(!model.isDirty, "precondition: nothing staged yet")

        let outcome = await model.apply()

        #expect(outcome == .applied)
        #expect(rewrapCalls == 0, "a no-op apply must never call the bridge")
        #expect(writeCalls == 0, "a no-op apply must never write")
    }

    @Test("a bridge/rewrap failure is reported and leaves current and staged recipients untouched")
    func bridgeFailureLeavesRecipientsUntouched() async throws {
        struct RewrapBoom: Swift.Error {}
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        var writeCalls = 0
        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = try fakeModel(
            recipients: [owner.public],
            writeFile: { _, _, _ in
                writeCalls += 1
                return nil
            },
            rewrapRecipients: { _, _, _ in throw RewrapBoom() },
            keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        try #require(model.isDirty)

        let outcome = await model.apply()

        guard case .failed = outcome else {
            Issue.record("expected apply to fail; got \(outcome)")
            return
        }
        #expect(writeCalls == 0, "a bridge failure must never reach the write seam")
        #expect(model.currentRecipients == [owner.public], "the baseline must be untouched by a failed apply")
        #expect(model.stagedRecipients == [owner.public, added.public], "the staged edit must survive a failed apply")
        #expect(model.loadState == .loaded)
    }

    /// Finding I3: `writeFile` throwing `destinationChangedOnDisk` — the
    /// second-writer guard `AtomicFileWriter` itself produces — is a named
    /// global constraint this suite had never actually driven through the
    /// seam. See `aRealConcurrentWriterIsRefusedWithoutClobbering` below for
    /// the same guarantee proven with a genuine external writer instead of
    /// an injected error.
    @Test("a write refused as changed-on-disk is reported and leaves current and staged recipients untouched")
    func writeFailureLeavesRecipientsUntouched() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        var rewrapCalls = 0
        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = try fakeModel(
            recipients: [owner.public],
            writeFile: { _, _, _ in throw AtomicFileWriter.Error.destinationChangedOnDisk(path: "fixture.yaml") },
            rewrapRecipients: { contents, recipients, key in
                rewrapCalls += 1
                return try await RecipientAccessModel.defaultRewrap(contents, recipients, key)
            },
            keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)

        let outcome = await model.apply()

        guard case .failed(let message) = outcome else {
            Issue.record("expected apply to fail; got \(outcome)")
            return
        }
        #expect(rewrapCalls == 1, "the write seam is reached only after a real rewrap — this proves it ran")
        #expect(
            message.lowercased().contains("changed on disk"),
            Comment(rawValue: "the message has to say what happened: \(message)"))
        #expect(model.currentRecipients == [owner.public])
        #expect(model.stagedRecipients == [owner.public, added.public])
        #expect(model.loadState == .loaded)
    }

    @Test("a read failure surfaces as a failed load, not a crash or a silently empty document")
    func readFailureSurfacesAsFailedLoad() async throws {
        struct ReadBoom: Swift.Error {}
        let keyStore = SessionKeyStore()
        let model = try fakeModel(
            recipients: ["age1anything"],  // never reached — readFile throws first
            readFile: { _ in throw ReadBoom() },
            keyStore: keyStore)

        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("expected the load to fail; got \(model.loadState)")
            return
        }
        #expect(message.lowercased().contains("could not be read"))
        #expect(model.currentRecipients.isEmpty)
        #expect(model.entries.isEmpty)
    }

    @Test("a custom loadRegistry seam supplies labels without touching a real registry file")
    func customLoadRegistrySeamSuppliesLabels() async throws {
        let known = try AgeKeyPair.generate()
        var loadRegistryCalls = 0
        let keyStore = SessionKeyStore()
        try keyStore.importKey(known.private)
        let model = try fakeModel(
            recipients: [known.public],
            loadRegistry: { project in
                loadRegistryCalls += 1
                // Deliberately unrelated to `project` — proving the labels
                // came from this closure, not a real
                // `.sops-gui/recipients.json` this test never created.
                return ([RecipientRecord(label: "Injected Label", kind: .device, ageRecipient: known.public)], nil)
            },
            keyStore: keyStore)

        await model.load()

        #expect(loadRegistryCalls == 1)
        #expect(model.entries.first?.label == "Injected Label")
    }

    /// The real-external-writer counterpart to
    /// `writeFailureLeavesRecipientsUntouched` — same refusal, proven with
    /// the actual `sops` CLI landing a write on the file between `load()`
    /// and `apply()`, exactly as `SecretDocumentViewModelTests
    /// .externalChangeIsRefusedNotClobbered` proves it for the editor's own
    /// save path.
    @Test("a real concurrent writer between load and apply is refused, not clobbered")
    func aRealConcurrentWriterIsRefusedWithoutClobbering() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(plainYAML, recipients: [owner.public])
        let fileURL = try fixtureFile(encrypted)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = RecipientAccessModel(fileURL: fileURL, projectURL: nil, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)

        // A real, independent writer — the real `sops` CLI, not a
        // simulation — lands a change on the same file while this model
        // still has it open.
        try cliSet(fileURL, key: owner, path: "[\"added_elsewhere\"]", value: "\"from-another-writer\"")

        let outcome = await model.apply()

        guard case .failed(let message) = outcome else {
            Issue.record("expected apply to refuse; got \(outcome)")
            return
        }
        #expect(
            message.lowercased().contains("changed on disk"),
            Comment(rawValue: "the message has to say what happened: \(message)"))

        // The other writer's key is still there, and the staged addition
        // never landed — the refused apply touched nothing.
        let onDisk = try String(contentsOf: fileURL, encoding: .utf8)
        #expect(try SopsBridge.recipients(in: onDisk) == [owner.public])
        #expect(model.currentRecipients == [owner.public])
        #expect(model.stagedRecipients == [owner.public, added.public], "the staged edit must survive the refusal")
    }
}
