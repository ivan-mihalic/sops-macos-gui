import Foundation
import ScratchCleanup
import Testing
import SopsEngine
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
}
