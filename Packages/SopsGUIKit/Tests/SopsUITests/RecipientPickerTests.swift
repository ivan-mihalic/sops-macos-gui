import AppKit
import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixture plumbing
//
// Real temporary project roots, real `age-keygen` keys, and the real
// in-process bridge throughout — the same discipline `NewSecretFileModelTests
// .swift`/`NewSecretFileSheetTests.swift` (Tasks 2 and 4, same test target)
// already stand on, duplicated here rather than shared because those files'
// own helpers are `private` to them.

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

private func scratchDirectory(_ label: String = "recipient-picker") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A `.sops.yaml` with one age-only creation rule naming `recipient`, for a
/// path that never matches `secret.yaml` — sets up `.noRuleMatched` rather
/// than `.noConfig` while still leaving the config genuinely present, so a
/// write attempt against it exercises `.absent`'s refusal honestly.
private func nonMatchingConfig(_ recipient: String) -> String {
    """
    creation_rules:
      - path_regex: only-this-one-file\\.yaml$
        age: \(recipient)
    """ + "\n"
}

@MainActor
private func makeKeyStore(importing key: String? = nil) throws -> SessionKeyStore {
    let store = SessionKeyStore()
    if let key {
        try store.importKey(key)
    }
    return store
}

// MARK: - .noConfig: propose, write, and an independent second opinion

@Suite("NewSecretFileModel.proposeConfig()/.writeProposedConfig(_:) — .noConfig")
@MainActor
struct ProposeAndWriteConfigTests {

    /// The test named in the brief: a real temp root with no `.sops.yaml`,
    /// two chosen recipients, `propose` verifies, the write succeeds, and —
    /// independently, through a completely different type going through the
    /// bridge a second time — `CreationPlanResolver.plan` agrees the file is
    /// now governed by exactly that set. `verified == true` alone would only
    /// prove this type's own opinion of itself; this is the second opinion
    /// the self-review demands.
    @Test("two recipients propose verified, write succeeds, and CreationPlanResolver independently agrees")
    func twoRecipientsProposeWriteAndResolverAgrees() async throws {
        let first = try AgeKeyPair.generate()
        let second = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // A configured session key so `readiness` reaches the plan switch at
        // all — an empty key store is checked first, unconditionally, the
        // same as every other path through this model.
        let keyStore = try makeKeyStore(importing: first.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secrets/prod.yaml"

        await model.resolvePlan()
        #expect(model.plan == .noConfig)
        #expect(model.readiness == .needsRecipients)

        model.manuallyChosenRecipients = [first.public, second.public]

        let proposed = try #require(await model.proposeConfig())
        #expect(proposed.verified)
        #expect(!proposed.text.isEmpty)
        #expect(proposed.reason.isEmpty)

        let outcome = model.writeProposedConfig(proposed)
        #expect(outcome == .written)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".sops.yaml").path))

        // Independent second opinion: a fresh call into
        // `CreationPlanResolver`, not this model, reading the file that was
        // actually written.
        let plan = try CreationPlanResolver.plan(
            forTarget: root.appendingPathComponent("secrets/prod.yaml"), in: root)
        guard case .governedByRule(let recipients, let encryptedRegex) = plan else {
            Issue.record("expected .governedByRule, got \(plan)")
            return
        }
        #expect(Set(recipients) == Set([first.public, second.public]))
        #expect(encryptedRegex.isEmpty)

        // And the model's own `readiness`, once it re-resolves against the
        // file that now actually exists, agrees too — not just a second
        // type's opinion but this model's own, recomputed from scratch.
        await model.resolvePlan()
        #expect(model.readiness == .ready(recipients: recipients))
    }

    /// "Prázdný výběr → tlačítko neaktivní": both the view's own pure gate
    /// and the model's own guard agree an empty selection proposes nothing.
    @Test("an empty selection disables the propose control and proposeConfig() itself returns nil")
    func emptySelectionDisablesProposeAndReturnsNil() async throws {
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        #expect(!RecipientPicker.canPropose(recipients: model.manuallyChosenRecipients))

        let proposed = await model.proposeConfig()
        #expect(proposed == nil)
    }

    /// "existující .sops.yaml → .absent zápis odmítne": `writeProposedConfig`
    /// must not clobber a `.sops.yaml` that appeared after the proposal was
    /// built — `AtomicFileWriter.write(_:to:expecting: .absent)`'s own
    /// contract, exercised here through the model rather than the writer
    /// directly. The existing file's content is untouched, proving this is
    /// a real refusal and not a silent partial write.
    @Test("writeProposedConfig refuses when .sops.yaml already exists, leaving it untouched")
    func writeRefusesWhenConfigAlreadyExists() async throws {
        let key = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let existingConfig = nonMatchingConfig(other.public)
        try existingConfig.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noRuleMatched)

        // Build a proposal by hand — `proposeConfig()` itself is not even
        // offered by the view for `.noRuleMatched` (see `RecipientPicker`'s
        // own doc comment, "Two different jobs behind one control"), but
        // `writeProposedConfig(_:)` must still refuse to overwrite a real
        // `.sops.yaml` regardless of how the proposal was produced.
        let proposed = try SopsConfigGenerator.propose(
            forTarget: root.appendingPathComponent("secret.yaml"), in: root, recipients: [key.public])
        #expect(proposed.verified, "precondition: the proposal itself is fine, only the write should refuse")

        let outcome = model.writeProposedConfig(proposed)
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }

        let onDisk = try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(onDisk == existingConfig, "the existing .sops.yaml must be untouched by the refused write")
    }

    @Test("writeProposedConfig refuses an unverified proposal without ever touching the filesystem")
    func writeRefusesAnUnverifiedProposal() async throws {
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        let unverified = ProposedConfig(text: "", verified: false, reason: "No recipients were given.")
        let outcome = model.writeProposedConfig(unverified)

        guard case .refused(let message) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(message.detail == "No recipients were given.")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sops.yaml").path))
    }
}

// MARK: - .needsRecipients, and the manually-chosen set behaving exactly like a resolved rule

@Suite("NewSecretFileModel — manuallyChosenRecipients feeding create(), for both .noConfig and .noRuleMatched")
@MainActor
struct ManuallyChosenRecipientsCreateTests {

    @Test(".noConfig with nothing chosen is .needsRecipients, not .blocked")
    func noConfigWithNothingChosenIsNeedsRecipients() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        #expect(model.plan == .noConfig)
        #expect(model.readiness == .needsRecipients)
        #expect(model.planError == nil)
    }

    @Test(".noRuleMatched with nothing chosen is .needsRecipients, not .blocked")
    func noRuleMatchedWithNothingChosenIsNeedsRecipients() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try nonMatchingConfig(other.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        #expect(model.plan == .noRuleMatched)
        #expect(model.readiness == .needsRecipients)
    }

    /// `.noRuleMatched`'s whole point: the file gets created for exactly the
    /// manually-chosen set, without ever touching the `.sops.yaml` that
    /// already governs the rest of the project — proven by decrypting the
    /// result and by the config's own bytes being unchanged afterwards.
    @Test("choosing recipients for .noRuleMatched creates a readable file without touching .sops.yaml")
    func manualRecipientsForNoRuleMatchedCreateAReadableFileWithoutTouchingConfig() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let existingConfig = nonMatchingConfig(other.public)
        try existingConfig.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noRuleMatched)

        model.manuallyChosenRecipients = [owner.public]
        #expect(model.readiness == .ready(recipients: [owner.public]))

        let created = await model.create()
        let destination = try #require(created)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(rows.isEmpty)

        let configAfter = try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(configAfter == existingConfig, ".sops.yaml must be untouched by a manual-recipient create()")
    }

    /// The manually-chosen set gets the identical round-trip discovery a
    /// resolved rule's own recipients already earn — `readiness(for:)` is
    /// shared between the two paths, and this is the proof it actually is.
    @Test("manually choosing a recipient that excludes this session's key needs acknowledgement, same as a resolved rule")
    func manualRecipientsExcludingOwnKeyNeedAcknowledgement() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        model.manuallyChosenRecipients = [stranger.public]
        #expect(model.readiness == .ready(recipients: [stranger.public]), "optimistic until create() actually tries")

        let firstAttempt = await model.create()
        #expect(firstAttempt == nil)
        #expect(model.readiness == .needsAcknowledgement)

        model.acknowledgedUnreadable = true
        #expect(model.readiness == .ready(recipients: [stranger.public]))

        let secondAttempt = await model.create()
        let destination = try #require(secondAttempt)
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: stranger.private)
        #expect(rows.isEmpty)
        #expect(throws: (any Error).self) {
            try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        }
    }

    /// `resolvePlan()`'s reset — the same discipline `acknowledgedUnreadable`
    /// already gets, extended to `manuallyChosenRecipients`: a set chosen
    /// for one name must not silently cover a second, different name.
    @Test("manuallyChosenRecipients does not carry over a name change")
    func manuallyChosenRecipientsDoesNotCarryAcrossANameChange() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "a.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        model.manuallyChosenRecipients = [owner.public]
        #expect(model.readiness == .ready(recipients: [owner.public]))

        model.relativeName = "b.yaml"
        await model.resolvePlan()

        #expect(model.manuallyChosenRecipients.isEmpty, "a fresh resolve must not carry the old selection forward")
        #expect(model.readiness == .needsRecipients)
    }
}

// MARK: - RecipientPicker's own pure decisions

@Suite("RecipientPicker.canAdd — the free-text add control's gate")
struct CanAddTests {

    @Test("a blank or whitespace-only entry is refused")
    func blankIsRefused() {
        #expect(RecipientPicker.canAdd("", existing: []) == .empty)
        #expect(RecipientPicker.canAdd("   ", existing: []) == .empty)
    }

    @Test("a recipient already chosen is refused as a duplicate")
    func duplicateIsRefused() {
        #expect(RecipientPicker.canAdd("age1abc", existing: ["age1abc"]) == .duplicate)
    }

    @Test("a new, non-blank recipient is accepted")
    func newRecipientIsAccepted() {
        #expect(RecipientPicker.canAdd("age1abc", existing: []) == nil)
        #expect(RecipientPicker.canAdd("  age1abc  ", existing: []) == nil)
    }
}

@Suite("RecipientPicker.canPropose/.canWrite — the config controls' gates")
struct CanProposeAndWriteTests {

    @Test("canPropose is exactly !recipients.isEmpty")
    func canProposeIsNonEmpty() {
        #expect(!RecipientPicker.canPropose(recipients: []))
        #expect(RecipientPicker.canPropose(recipients: ["age1abc"]))
    }

    @Test("canWrite is true only for a verified, non-nil proposal")
    func canWriteRequiresVerified() {
        #expect(!RecipientPicker.canWrite(nil))
        #expect(!RecipientPicker.canWrite(ProposedConfig(text: "", verified: false, reason: "x")))
        #expect(RecipientPicker.canWrite(ProposedConfig(text: "creation_rules: []\n", verified: true, reason: "")))
    }
}

// MARK: - Rendered through the real sheet

@Suite("RecipientPicker, rendered inside NewSecretFileSheet")
@MainActor
struct RecipientPickerRenderedTests {

    private static let sheetSize = CGSize(width: 640, height: 700)

    @Test("a .noConfig project renders RecipientPicker's title and explanation, not the old placeholder banner")
    func noConfigRendersPicker() async throws {
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        let values = Set(host.nodes().map(\.value))
        #expect(values.contains(LocalizedKey.recipientPickerTitle.text))
        #expect(values.contains(LocalizedKey.recipientPickerExplanationNoConfig.text))
        #expect(values.contains(LocalizedKey.recipientPickerNoneChosen.text))
    }

    /// Picking a recipient through the model (standing in for the user
    /// typing into the picker's own field) flows all the way to the
    /// sheet's own Create button becoming enabled — the wiring this task
    /// exists to close, proven end to end through the real rendered sheet.
    @Test("choosing a recipient in .noRuleMatched enables the sheet's own Create button")
    func choosingARecipientEnablesCreate() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try nonMatchingConfig(other.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noRuleMatched)

        let host = GatingHost(size: Self.sheetSize) {
            AnyView(NewSecretFileSheet(model: model, onCreated: { _ in }))
        }
        defer { host.finish() }
        await host.settleAfterLoad()

        #expect(!NewSecretFileSheet.canCreate(readiness: model.readiness, isCreating: false))

        model.manuallyChosenRecipients = [owner.public]
        await host.settle(until: { model.readiness == .ready(recipients: [owner.public]) })

        #expect(NewSecretFileSheet.canCreate(readiness: model.readiness, isCreating: false))
    }
}
