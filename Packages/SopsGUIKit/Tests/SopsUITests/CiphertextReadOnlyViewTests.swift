import AppKit
import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing
@testable import SopsUI

/// `SecretDocumentViewModelTests` (Task 1) proves the *model* reaches
/// `LoadState.readOnlyCiphertext` with the right `reason`/`rawCiphertext`/
/// `recipients`. That is half the story — `FileListViewWiringTests`' own
/// header names the exact failure mode this half exists to catch: a view
/// that throws a value away leaves the whole suite green while a user sees
/// nothing. These render `SecretEditorView` over a real `.readOnlyCiphertext`
/// document and assert on the accessibility tree, the closest this project
/// gets to "the user saw it" without launching the app (`AXProbe`, shared
/// with `AccessibilityTreeTests`/`FileListViewWiringTests`).
@Suite("CiphertextReadOnlyView — the real read-only ciphertext view")
@MainActor
struct CiphertextReadOnlyViewTests {

    private static let plaintext = "database:\n    password: hunter2-EXAMPLE\n"
    private static let size = CGSize(width: 760, height: 560)

    /// A real wrong-key `.readOnlyCiphertext` document: the owner's key
    /// encrypts it, a stranger's key is the only one imported into the
    /// session. Mirrors `SecretDocumentViewModelTests
    /// .wrongKeyReportsReadOnlyCiphertextWithNoRows` — the same real bridge
    /// call, not a hand-written fixture.
    private func readOnlyModel() async throws -> (model: SecretDocumentViewModel, owner: AgeKeyPairForTests) {
        let owner = try AgeKeyPairForTests.generate()
        let stranger = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(Self.plaintext, format: .yaml, recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(stranger.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/read-only-ciphertext.yaml"),
            format: .yaml,
            keyStore: store, readFile: { _ in encrypted })
        await model.load()
        try #require(model.loadState != .loaded, "precondition: a stranger's key must not decrypt this file")
        return (model, owner)
    }

    private func text(_ nodes: [AXProbe.Node]) -> String {
        nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
    }

    // MARK: - The real view, not the placeholder

    @Test("the editor renders the real read-only ciphertext view, not the .failed placeholder")
    func rendersTheRealView() async throws {
        let (model, owner) = try await readOnlyModel()
        guard case .readOnlyCiphertext(_, let rawCiphertext, let recipients) = model.loadState else {
            Issue.record("expected .readOnlyCiphertext, got \(model.loadState)")
            return
        }

        let nodes = AXProbe.tree(size: Self.size) {
            SecretEditorView(viewModel: model, fileName: "wrong-key.secrets.yaml",
                              unsavedChanges: UnsavedChangesTracker())
        }
        let shown = text(nodes)

        #expect(shown.contains(LocalizedKey.editorReadOnlyCiphertextTitle.text),
                "the tree did not populate — this test would be vacuous: \(shown)")
        // The one property this whole task exists to fix: Task 1's
        // placeholder reused `.failed`'s exact title. The real view must not.
        #expect(!shown.contains(LocalizedKey.editorLoadFailedTitle.text),
                "still showing the .failed placeholder's title, not the real view")
        #expect(shown.contains("none of the keys"), "the wrong-key reason must still be shown: \(shown)")
        // The raw on-disk bytes — `ENC[` is sops's own ciphertext tag, so its
        // presence proves the *ciphertext*, not some other text, is on screen.
        #expect(shown.contains("ENC["), "the raw ciphertext was not rendered: \(shown)")
        #expect(!rawCiphertext.isEmpty, "precondition: the model actually carried ciphertext")
        // No project was supplied, so the recipient renders as its raw key.
        #expect(shown.contains(owner.public), "the file's own recipient must be named: \(shown)")
        #expect(recipients == [owner.public], "precondition: the model carried the owner's recipient")
    }

    /// There is no path from this state back to `SecretDocumentViewModel
    /// .save()`/`addRow`/`removeRow` — the toolbar's Save/Add/Remove buttons
    /// render (as they do for every `LoadState`, `.failed`/`.needsKey`
    /// included — see `SecretEditorView.toolbar`) but stay disabled the same
    /// way they already do there, because every one of those three already
    /// guards on `loadState == .loaded` (Task 9's own invariant, unchanged by
    /// this task). What matters — and what this task's brief calls out by
    /// name — is that the *model itself* refuses each one too, so a future
    /// bug in the toolbar's `.disabled(...)` expression could not open a
    /// path to mutating a document that was never decrypted.
    @Test("the model refuses every mutation over a read-only ciphertext document")
    func modelRefusesEveryMutation() async throws {
        let (model, _) = try await readOnlyModel()
        try #require(model.rows.isEmpty, "precondition: nothing to select, add into or remove")

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

        // A no-op, not a crash — there is nothing in `rows` to remove.
        model.removeRow(id: "does-not-exist")
        #expect(model.rows.isEmpty)
        #expect(!model.isDirty)
    }

    // MARK: - Recipients: labelled where the registry knows them

    @Test("a recipient the registry has a label for is shown by name, not just its raw key")
    func labelledRecipientShowsItsName() async throws {
        let owner = try AgeKeyPairForTests.generate()
        let stranger = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(Self.plaintext, format: .yaml, recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(stranger.private)

        let projectRoot = try Self.scratchProject("labelled-recipient")
        try RecipientRegistry.save(
            [RecipientRecord(label: "Production Server", kind: .server, ageRecipient: owner.public)],
            in: projectRoot)

        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/labelled.yaml"),
            format: .yaml, keyStore: store, readFile: { _ in encrypted })
        await model.load()
        try #require(model.loadState != .loaded)

        let nodes = AXProbe.tree(size: Self.size) {
            SecretEditorView(
                viewModel: model, fileName: "labelled.yaml", unsavedChanges: UnsavedChangesTracker(),
                recipientAccess: SecretEditorView.RecipientAccessContext(
                    fileURL: URL(fileURLWithPath: "/dev/null/labelled.yaml"), keyStore: store,
                    projectURL: projectRoot, format: .yaml))
        }
        let shown = text(nodes)
        #expect(shown.contains("Production Server"),
                "the registry named this recipient and the view never said so: \(shown)")
        // Still names the raw key too — see `RecipientAccessRow`'s own
        // idiom, which this view mirrors: the public key stays visible
        // beneath a label, never hidden behind it.
        #expect(shown.contains(owner.public), "the raw key must still be shown beneath the label: \(shown)")
    }

    /// The negative case: an unregistered recipient (no project at all) must
    /// fall back to its raw key, never an invented name — mirrors
    /// `Fixtures.startHereGovernedFixture`'s own unlabeled-recipient case one
    /// screen over.
    @Test("a recipient the registry has no record for shows only its raw key")
    func unregisteredRecipientShowsOnlyItsRawKey() async throws {
        let (model, owner) = try await readOnlyModel()
        let nodes = AXProbe.tree(size: Self.size) {
            SecretEditorView(viewModel: model, fileName: "wrong-key.secrets.yaml",
                              unsavedChanges: UnsavedChangesTracker())
        }
        let shown = text(nodes)
        #expect(shown.contains(owner.public))
        #expect(!shown.contains("Production Server"))
    }

    /// `LoadState.readOnlyCiphertext`'s `recipients == []` case — the file's
    /// own metadata could not be read, not "this file has no recipients".
    /// Reproduced the same way `SecretDocumentViewModelTests
    /// .recipientsReadFailureDegradesToEmptyList` proves the model side:
    /// corrupting only the `recipient:` string (never the `enc:` blob) makes
    /// `SopsBridge.recipients` fail while decrypt still classifies as
    /// `.noMatchingIdentity`.
    @Test("an unreadable recipient list states that fact, never an empty list read as \"none\"")
    func unreadableRecipientsShowTheStatedFact() async throws {
        let owner = try AgeKeyPairForTests.generate()
        let stranger = try AgeKeyPairForTests.generate()
        var encrypted = try SopsBridge.encrypt(Self.plaintext, format: .yaml, recipients: [owner.public])
        try #require(encrypted.contains(owner.public),
                     "fixture does not contain the owner's recipient string")
        encrypted = encrypted.replacingOccurrences(
            of: owner.public, with: "age1thisisnotarealrecipientvalueatallxx")

        let store = SessionKeyStore()
        try store.importKey(stranger.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/unreadable-recipients.yaml"),
            format: .yaml, keyStore: store, readFile: { _ in encrypted })
        await model.load()
        guard case .readOnlyCiphertext(_, _, let recipients) = model.loadState else {
            Issue.record("expected .readOnlyCiphertext, got \(model.loadState)")
            return
        }
        try #require(recipients == [], "precondition: the corrupted recipient string made this unreadable")

        let nodes = AXProbe.tree(size: Self.size) {
            SecretEditorView(viewModel: model, fileName: "unreadable-recipients.yaml",
                              unsavedChanges: UnsavedChangesTracker())
        }
        let shown = text(nodes)
        #expect(shown.contains(LocalizedKey.editorReadOnlyCiphertextRecipientsUnknown.text),
                "an unreadable recipient list must say so: \(shown)")
        #expect(!shown.contains(owner.public),
                "the owner's real key was replaced by the fixture and must not appear")
    }

    // MARK: - The Access button: disabled, with an honest reason

    /// This state never decrypts by construction (`CiphertextReadOnlyView`'s
    /// own doc comment), so this is defense in depth rather than a live
    /// hazard — the same discipline `AccessibilityTreeTests
    /// .maskedValuesNeverReachTheAccessibilityTree` applies to the masked
    /// editor, applied here to guard against a future regression that wired
    /// a decrypted value into this view by mistake.
    @Test("the plaintext behind a read-only ciphertext document never reaches the accessibility tree")
    func plaintextNeverReachesTheTree() async throws {
        let (model, _) = try await readOnlyModel()
        let nodes = AXProbe.tree(size: Self.size) {
            SecretEditorView(viewModel: model, fileName: "wrong-key.secrets.yaml",
                              unsavedChanges: UnsavedChangesTracker())
        }
        for node in nodes {
            #expect(!node.value.contains("hunter2-EXAMPLE"), "the plaintext password leaked into \(node.value)")
            #expect(!node.label.contains("hunter2-EXAMPLE"))
            #expect(!node.help.contains("hunter2-EXAMPLE"))
        }
    }

    // MARK: - Fixtures

    private static func scratchProject(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ciphertext-readonly-\(label)-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
