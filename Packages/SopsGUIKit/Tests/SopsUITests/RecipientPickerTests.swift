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

// MARK: - propose/write, an independent second opinion, and the subject that gates staleness

@Suite("NewSecretFileModel.proposeConfig()/.writeProposedConfig()")
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

        let outcome = model.writeProposedConfig()
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
    /// contract. The existing file's content is untouched, proving this is
    /// a real refusal and not a silent partial write.
    ///
    /// Driven through the real model pipeline, not a hand-built
    /// `ProposedConfig` — `writeProposedConfig()` no longer accepts one
    /// (see that method's own doc comment, "Forgeability"), so there is no
    /// other way to reach it any more. `proposeConfig()` itself does not
    /// check whether a real `.sops.yaml` already exists — `SopsConfigGenerator
    /// .propose` verifies against an independent staged probe file, entirely
    /// unaware of the real path — so this comes back `verified: true` even
    /// though writing it would clobber the real file; `writeProposedConfig()`
    /// is the guard that actually has to catch this.
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

        // `RecipientPicker` itself never offers propose/write for
        // `.noRuleMatched` (see that type's own doc comment, "Two different
        // jobs behind one control") — but the model API underneath it must
        // still refuse to overwrite a real `.sops.yaml` regardless of which
        // `CreationPlan` is current, since nothing about `writeProposedConfig()`
        // reads `plan` at all.
        model.manuallyChosenRecipients = [key.public]
        let proposed = try #require(await model.proposeConfig())
        #expect(proposed.verified, "precondition: the proposal itself is fine, only the write should refuse")

        let outcome = model.writeProposedConfig()
        guard case .refused = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }

        let onDisk = try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(onDisk == existingConfig, "the existing .sops.yaml must be untouched by the refused write")
    }

    /// The forgery Minor 2 named directly: before this fix, any caller could
    /// build `ProposedConfig(verified: true)` by hand and hand it to
    /// `writeProposedConfig(_:)`. There is no longer a parameter to forge —
    /// this test instead earns an unverified proposal honestly, the same
    /// way `SopsConfigGeneratorTests.noProbeFileSurvivesBridgeFailure` does,
    /// and proves the model refuses to write it.
    @Test("writeProposedConfig refuses an unverified proposal without ever touching the filesystem")
    func writeRefusesAnUnverifiedProposal() async throws {
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        model.manuallyChosenRecipients = ["not-a-valid-age-recipient"]
        let proposed = try #require(await model.proposeConfig())
        #expect(!proposed.verified, "precondition: an invalid recipient must not verify")

        let outcome = model.writeProposedConfig()
        guard case .refused(let message) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(message.detail == proposed.reason)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sops.yaml").path))
    }

    // MARK: - The Important finding: a stale proposal must not be writable

    /// The review's "Scenario A", proven at the model layer rather than
    /// through the view: propose for two recipients, then remove one — the
    /// exact effect the remove button has on `manuallyChosenRecipients`, no
    /// matter which mutation site a future change forgets to also clear
    /// `@State` for. `writeProposedConfig()` must refuse regardless, because
    /// it reads back `lastProposal` gated on the *current* selection, never
    /// a caller-held value.
    @Test("write refuses once a recipient has been removed since propose")
    func writeRefusesAfterARecipientIsRemovedSincePropose() async throws {
        let first = try AgeKeyPair.generate()
        let second = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: first.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        model.manuallyChosenRecipients = [first.public, second.public]
        let proposed = try #require(await model.proposeConfig())
        #expect(proposed.verified)

        // The user's on-screen selection now denies `second` — writing the
        // proposal built a moment ago would grant them access anyway.
        model.manuallyChosenRecipients.removeAll { $0 == second.public }

        let outcome = model.writeProposedConfig()
        guard case .refused = outcome else {
            Issue.record(
                "expected .refused — the proposal named a selection that no longer exists, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sops.yaml").path))
    }

    /// The other direction of the same finding — adding a recipient after
    /// proposing, mirroring what the known-recipients "Add" button and the
    /// free-text field both do. A genuinely *new* third recipient, not the
    /// one just proposed for: appending back the exact set already on file
    /// would reconstruct the identical `ProposalSubject` and legitimately
    /// make the original proposal writable again — that is correct
    /// behavior, not a bug, and a version of this test that did that instead
    /// pinned nothing.
    @Test("write refuses once a recipient has been added since propose")
    func writeRefusesAfterARecipientIsAddedSincePropose() async throws {
        let first = try AgeKeyPair.generate()
        let second = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: first.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        model.manuallyChosenRecipients = [first.public]
        let proposed = try #require(await model.proposeConfig())
        #expect(proposed.verified)

        model.manuallyChosenRecipients.append(second.public)

        let outcome = model.writeProposedConfig()
        guard case .refused = outcome else {
            Issue.record(
                "expected .refused — the proposal named a selection that has since grown, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sops.yaml").path))
    }

    /// The review's "Scenario B": the name changes after a propose while
    /// `plan` is still `.noConfig` — the exact identity `RecipientPicker`'s
    /// own gate (`model.plan == .noConfig`) keeps rendering, so a view keyed
    /// only on that would show no visible change at all. `resolvePlan()`'s
    /// own reset of `manuallyChosenRecipients` already makes the
    /// `ProposalSubject` mismatch (empty recipients cannot match a proposal
    /// built for a non-empty set) — this test is what proves that actually
    /// reaches `writeProposedConfig()`'s refusal, not just the property
    /// being empty in isolation.
    @Test("write refuses after the name changes since propose, even though plan is still .noConfig")
    func writeRefusesAfterNameChangesSincePropose() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "a.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig)

        model.manuallyChosenRecipients = [owner.public]
        let proposed = try #require(await model.proposeConfig())
        #expect(proposed.verified)

        model.relativeName = "b.yaml"
        await model.resolvePlan()
        #expect(model.plan == .noConfig, "precondition: the view's own gate sees no change here")
        #expect(model.manuallyChosenRecipients.isEmpty)

        let outcome = model.writeProposedConfig()
        guard case .refused = outcome else {
            Issue.record("expected .refused — the proposal was built for a.yaml, not b.yaml, got \(outcome)")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sops.yaml").path))
    }

    /// The same finding, one layer further out: a fresh, in-flight
    /// `proposeConfig()` call for a *changed* selection must not leave the
    /// *previous* selection's proposal writable while it is still running.
    /// `RecipientPicker.propose()` clears its own `@State` up front for
    /// exactly this window; this test pins the model-level guarantee that
    /// holds regardless of whether that clearing happens.
    @Test("the previous proposal is not writable once a new one is in flight for a different selection")
    func previousProposalNotWritableWhileANewOneIsInFlight() async throws {
        let first = try AgeKeyPair.generate()
        let second = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: first.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        model.manuallyChosenRecipients = [first.public]
        _ = try #require(await model.proposeConfig())

        // Selection changes before a second propose is even started —
        // `writeProposedConfig()` must already refuse the first proposal.
        model.manuallyChosenRecipients = [second.public]
        guard case .refused = model.writeProposedConfig() else {
            Issue.record("the first proposal must not be writable once the selection has moved on")
            return
        }
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

/// The second of the two mutation sites the review named directly (the
/// remove button, `CanAddTests` above's sibling for the free-text field, and
/// this one). Extracted to a pure function specifically so it has a test
/// distinct from "the structural fix makes staleness impossible regardless
/// of provenance" — this pins that the known-recipients row's own effect on
/// the selection is correct, not only that a wrong effect couldn't have been
/// written anyway.
@Suite("RecipientPicker.addingKnownRecipient — the known-recipients row's own effect")
struct AddingKnownRecipientTests {

    @Test("appends to an empty selection")
    func appendsToEmpty() {
        #expect(RecipientPicker.addingKnownRecipient("age1abc", to: []) == ["age1abc"])
    }

    @Test("appends after existing recipients, preserving their order")
    func appendsAfterExisting() {
        #expect(RecipientPicker.addingKnownRecipient("age1abc", to: ["age1xyz"]) == ["age1xyz", "age1abc"])
    }

    @Test("does not duplicate a recipient already present")
    func doesNotDuplicate() {
        #expect(RecipientPicker.addingKnownRecipient("age1abc", to: ["age1abc"]) == ["age1abc"])
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

    /// Pins the render side of the second mutation site the review named:
    /// a real registry entry shows up under "Known recipients" by its real
    /// label, and stops showing once it has been chosen — proving the
    /// section actually reads `RecipientRegistry`, not a placeholder that
    /// happens to compile. `AddingKnownRecipientTests` covers the row's own
    /// effect on the selection; this covers that the row is real to begin
    /// with.
    @Test("a registry entry appears under Known Recipients by its real label, and drops off once chosen")
    func knownRecipientsSectionShowsRegistryLabels() async throws {
        let recipient = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try RecipientRegistry.save(
            [RecipientRecord(label: "Ops Laptop", kind: .device, ageRecipient: recipient.public)], in: root)
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
        #expect(values.contains("Ops Laptop"), "the registry label must render under Known Recipients")

        // Chosen through the model, mirroring what tapping the row's own
        // "Add" button does (`RecipientPicker.addingKnownRecipient(_:to:)`).
        // The label is still shown once afterward — as the chosen
        // recipient's own row, via `displayName(for:)` — but no longer
        // twice: it must have left the "Known Recipients" section it was in
        // before. `settle(until:)` waits for exactly that final count,
        // rather than for the label to vanish entirely, which it never does.
        model.manuallyChosenRecipients = [recipient.public]
        await host.settle(until: { host.nodes().map(\.value).filter { $0 == "Ops Laptop" }.count == 1 })

        let labelCountAfter = host.nodes().map(\.value).filter { $0 == "Ops Laptop" }.count
        #expect(labelCountAfter == 1, "the recipient must appear as chosen, not still offered as \"known\" too")
    }
}
