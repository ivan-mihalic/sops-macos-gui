import AppKit
import Foundation
import SopsEngine
import SopsProjects
import SwiftUI
import Testing
@testable import SopsUI

/// The value column used to be a `TextField` inside a `List` row, competing
/// with the key, the type label and two buttons for the same line — SOPS-39
/// measured it at under a third of the window. `SecretTableView` is the
/// replacement: read-only cells in a real `Table`, with editing moved into
/// `SecretRowInspector`.
///
/// These render it through `AXProbe` (the same probe
/// `AccessibilityTreeTests`/`CiphertextReadOnlyViewTests` use) rather than
/// asserting on a screenshot, because the property that matters most here is
/// what reaches the accessibility tree: a masked row must not publish its
/// value through any channel, and a revealed one must.
@Suite("SecretTableView — values as a table")
@MainActor
struct SecretTableViewTests {

    private static let size = CGSize(width: 800, height: 400)

    /// A real, decryptable document: the owner's key encrypts it and the same
    /// key is the one imported into the session, so the model reaches
    /// `.loaded` with real rows. Same shape as
    /// `CiphertextReadOnlyViewTests.readOnlyModel()`, with the owner's key
    /// rather than a stranger's.
    static func loadedModel(_ plaintext: String) async throws -> SecretDocumentViewModel {
        let owner = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(plaintext, format: .dotenv, recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(owner.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/table-fixture.env"),
            format: .dotenv,
            keyStore: store, readFile: { _ in encrypted })
        await model.load()
        try #require(model.loadState == .loaded, "precondition: the owner's own key must decrypt this file")
        return model
    }

    private func text(_ nodes: [AXProbe.Node]) -> String {
        nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
    }

    @Test("the table shows keys and masked values, and reveals one row on request")
    func tableMasksUntilRevealed() async throws {
        let model = try await Self.loadedModel("DATABASE_URL=postgres://x\n")
        let generation = model.rowIdentityGeneration
        var revealed = RevealedRows()

        var nodes = AXProbe.tree(size: Self.size) {
            SecretTableView(rows: model.rows, selection: .constant(nil),
                            revealed: revealed, generation: generation,
                            onToggleReveal: { _ in })
        }
        var flat = text(nodes)
        #expect(flat.contains("DATABASE_URL"), "the tree did not populate — vacuous: \(flat)")
        #expect(!flat.contains("postgres://x"), "a masked row must not publish its value: \(flat)")

        revealed.reveal(model.rows[0].id, in: generation)
        nodes = AXProbe.tree(size: Self.size) {
            SecretTableView(rows: model.rows, selection: .constant(nil),
                            revealed: revealed, generation: generation,
                            onToggleReveal: { _ in })
        }
        flat = text(nodes)
        #expect(flat.contains("postgres://x"), "a revealed row must show its value: \(flat)")
    }

    /// A merge-key row is an inlined YAML anchor — editing it does not change
    /// the shared anchor, so it gets no reveal/copy affordances. Asserted on
    /// the badge label rather than on button absence alone, so the test
    /// cannot pass by the row failing to render at all.
    @Test("a merge-key row renders annotated and without the reveal and copy buttons")
    func mergeKeyRowHasNoActions() async throws {
        let model = try await Self.loadedModel("PLAIN=value\n")
        let generation = model.rowIdentityGeneration
        let merge = SecretRow(path: ["db", "<<", "host"], value: "anchor", kind: .string, isEncrypted: false)
        try #require(SecretRowViewLogic.isMergeKeyRow(merge))

        let nodes = AXProbe.tree(size: Self.size) {
            SecretTableView(rows: [merge], selection: .constant(nil),
                            revealed: RevealedRows(), generation: generation,
                            onToggleReveal: { _ in })
        }
        let flat = text(nodes)
        #expect(flat.contains("db.<<.host"), "the tree did not populate — vacuous: \(flat)")
        #expect(flat.contains(LocalizedKey.editorMergeKeyBadge.text),
                "a merge-key row must say what it is: \(flat)")
        #expect(!flat.contains(LocalizedKey.editorRevealValue.text),
                "a merge-key row must offer no reveal: \(flat)")
        #expect(!flat.contains(LocalizedKey.actionCopy.text),
                "a merge-key row must offer no copy: \(flat)")
    }

    /// The copy button's own action, driven directly — the same shape
    /// `CopyFeedbackTests` uses, because a headless host cannot click.
    @Test("the copy action puts the row's value on the pasteboard")
    func copyPutsValueOnPasteboard() async throws {
        let canary = "table-copy-canary-\(UUID().uuidString)"
        let model = try await Self.loadedModel("TOKEN=\(canary)\n")
        let row = try #require(model.rows.first)
        ClipboardClearing.copy(row.value, clearingAfter: .seconds(30))
        #expect(NSPasteboard.general.string(forType: .string) == canary)
    }
}
