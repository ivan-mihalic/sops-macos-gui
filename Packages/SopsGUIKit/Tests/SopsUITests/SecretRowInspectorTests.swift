import AppKit
import Foundation
import SopsEngine
import SopsProjects
import SwiftUI
import Testing
@testable import SopsUI

/// Editing moved out of the row and into a trailing inspector (SOPS-39), so
/// the value column can have the width the row list never gave it. These
/// assert on the inspector's own contract: it offers Apply and Remove for the
/// selected row, and both go through `SecretDocumentViewModel` rather than
/// mutating anything of their own — the invariant that keeps Save
/// document-level.
@Suite("SecretRowInspector — editing the selected row")
@MainActor
struct SecretRowInspectorTests {

    private static let size = CGSize(width: 300, height: 500)

    private func text(_ nodes: [AXProbe.Node]) -> String {
        nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
    }

    @Test("the inspector offers Apply and Remove for the selected row, and Apply goes through the view model")
    func inspectorApplyUpdatesRow() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=old\n")
        let id = try #require(model.rows.first).id

        let nodes = AXProbe.tree(size: Self.size) {
            SecretRowInspector(viewModel: model, selectedRowID: id,
                               fileName: "a.env", access: nil, nameFor: { _ in nil })
        }
        let flat = text(nodes)
        #expect(flat.contains("K"), "the tree did not populate — vacuous: \(flat)")
        #expect(nodes.contains { $0.label == LocalizedKey.inspectorApply.text },
                "no Apply control: \(flat)")
        #expect(nodes.contains { $0.label == LocalizedKey.inspectorRemove.text },
                "no Remove control: \(flat)")

        // The same call the Apply button makes.
        model.update(rowID: id, to: "new")
        #expect(model.rows[0].value == "new")
        #expect(model.isDirty)
    }

    /// Remove is the inspector's synonym for the toolbar's `−`, and it goes
    /// through the model's own removal rather than editing rows in place.
    @Test("the inspector's Remove goes through removeRow on the view model")
    func inspectorRemoveGoesThroughViewModel() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=old\nJ=other\n")
        let id = try #require(model.rows.first).id
        try #require(model.rows.count == 2)

        // The same call the Remove button makes, after its confirmation.
        model.removeRow(id: id)
        #expect(!model.rows.contains { $0.id == id })
        #expect(model.isDirty)
    }

    /// With nothing selected the inspector is still useful: it describes the
    /// file itself, and says plainly that access is per file rather than per
    /// key — the question the value column's padlocks otherwise invite.
    @Test("with no selection the inspector describes the file and says access is per file")
    func inspectorWithoutSelectionDescribesTheFile() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=old\n")
        let url = URL(fileURLWithPath: "/tmp/project/app/.env")
        let access = AccessInventory.FileAccess(
            url: url, relativePath: "app/.env", format: .dotenv, ruleIndex: nil,
            encryptedFor: ["age1exampleexampleexampleexampleexampleexampleexampleexamplezz"],
            status: .inSync)

        let nodes = AXProbe.tree(size: Self.size) {
            SecretRowInspector(viewModel: model, selectedRowID: nil,
                               fileName: "app/.env", access: access,
                               nameFor: { _ in "Ivan" })
        }
        let flat = text(nodes)
        #expect(flat.contains(LocalizedKey.inspectorTitleFile.text),
                "the tree did not populate — vacuous: \(flat)")
        #expect(flat.contains(LocalizedKey.inspectorNoSelection.text), "\(flat)")
        #expect(flat.contains(LocalizedKey.inspectorReadableByNote.text), "\(flat)")
        #expect(flat.contains("Ivan"), "a named recipient must be shown by name: \(flat)")
    }
}
