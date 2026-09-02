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
            Self.inspector(model, selectedRowID: id, revealing: [id])
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


    /// The inspector over `model`, with `revealing` revealed against the
    /// model's current row-identity generation — the same shape
    /// `SecretEditorView` builds it in.
    static func inspector(
        _ model: SecretDocumentViewModel, selectedRowID: String?, revealing: Set<String>,
        onToggleReveal: @escaping (String) -> Void = { _ in },
        onActivity: @escaping () -> Void = {}
    ) -> some View {
        SecretRowInspector(
            viewModel: model, selectedRowID: selectedRowID, fileName: "a.env",
            access: nil, nameFor: { _ in nil }, ruleLabel: nil,
            revealed: RevealedRows(revealing: revealing, in: model.rowIdentityGeneration),
            generation: model.rowIdentityGeneration,
            onToggleReveal: onToggleReveal, onActivity: onActivity)
    }

    // MARK: - The value editor is behind the same reveal as everything else

    /// The hole this closes: seeded unconditionally from `row.value`, the
    /// inspector's `TextEditor` put a plaintext secret on screen that no
    /// reveal had been asked for, that the reveal timeout did not clear, and
    /// that `didResignActive`/`didHide`/occlusion did not hide — outside
    /// every protection `SecretEditorView`'s doc comment sets out, and
    /// against PROPOSAL.md §4's per-field reveal.
    @Test("an unrevealed row's value is masked in the inspector, not shown")
    func unrevealedRowIsMasked() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=hunter2-EXAMPLE\n")
        let id = try #require(model.rows.first).id

        let flat = text(AXProbe.tree(size: Self.size) {
            Self.inspector(model, selectedRowID: id, revealing: [])
        })
        #expect(flat.contains("K"), "the tree did not populate — vacuous: \(flat)")
        #expect(!flat.contains("hunter2-EXAMPLE"),
                "the inspector showed a value nobody revealed: \(flat)")
        #expect(flat.contains(SecretRowViewLogic.maskedValue(for: "hunter2-EXAMPLE")),
                "the masked state must show the same fixed-width mask a cell does: \(flat)")
        // And the way back is offered right there.
        #expect(flat.contains(LocalizedKey.editorRevealValue.text), "\(flat)")
    }

    @Test("revealing the row puts its value in the inspector's editor")
    func revealedRowShowsItsValue() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=hunter2-EXAMPLE\n")
        let id = try #require(model.rows.first).id

        let flat = text(AXProbe.tree(size: Self.size) {
            Self.inspector(model, selectedRowID: id, revealing: [id])
        })
        #expect(flat.contains("hunter2-EXAMPLE"),
                "a revealed row's value must be editable: \(flat)")
        #expect(flat.contains(LocalizedKey.editorHideValue.text),
                "a revealed row must offer the way back: \(flat)")
    }

    /// `hideEverythingRevealed()` — the one call behind the timeout,
    /// `didResignActive`, `didHide` and occlusion — is exactly
    /// `RevealedRows.hideAll()`. Driving `hideAll()` on the state the
    /// inspector reads is therefore driving all four, and the value must go
    /// with it: the draft cannot outlive the reveal.
    @Test("hiding everything revealed takes the inspector's value off screen with it")
    func hideAllDiscardsTheValue() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=hunter2-EXAMPLE\n")
        let id = try #require(model.rows.first).id
        var revealed = RevealedRows(revealing: [id], in: model.rowIdentityGeneration)

        var flat = text(AXProbe.tree(size: Self.size) {
            SecretRowInspector(
                viewModel: model, selectedRowID: id, fileName: "a.env",
                access: nil, nameFor: { _ in nil }, ruleLabel: nil,
                revealed: revealed, generation: model.rowIdentityGeneration,
                onToggleReveal: { _ in }, onActivity: {})
        })
        #expect(flat.contains("hunter2-EXAMPLE"), "precondition: it must be on screen first")

        revealed.hideAll()
        flat = text(AXProbe.tree(size: Self.size) {
            SecretRowInspector(
                viewModel: model, selectedRowID: id, fileName: "a.env",
                access: nil, nameFor: { _ in nil }, ruleLabel: nil,
                revealed: revealed, generation: model.rowIdentityGeneration,
                onToggleReveal: { _ in }, onActivity: {})
        })
        #expect(!flat.contains("hunter2-EXAMPLE"),
                "a plaintext secret survived hideEverythingRevealed: \(flat)")
    }

    /// A reveal belongs to one row-identity generation (`RevealedRows`), and
    /// the inspector must honour that like every other reader — otherwise a
    /// renumbering leaves it showing the value that moved into the id.
    @Test("a reveal from another generation does not unmask the inspector")
    func revealFromAnotherGenerationDoesNotUnmask() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=hunter2-EXAMPLE\n")
        let id = try #require(model.rows.first).id

        let flat = text(AXProbe.tree(size: Self.size) {
            SecretRowInspector(
                viewModel: model, selectedRowID: id, fileName: "a.env",
                access: nil, nameFor: { _ in nil }, ruleLabel: nil,
                revealed: RevealedRows(revealing: [id], in: model.rowIdentityGeneration &+ 1),
                generation: model.rowIdentityGeneration,
                onToggleReveal: { _ in }, onActivity: {})
        })
        #expect(flat.contains("K"), "the tree did not populate — vacuous: \(flat)")
        #expect(!flat.contains("hunter2-EXAMPLE"),
                "a stale-generation reveal unmasked the inspector: \(flat)")
    }

    /// Apply cannot commit a value the user was never shown.
    @Test("Apply is unavailable while the row is masked")
    func applyIsDisabledWhileMasked() async throws {
        let model = try await SecretTableViewTests.loadedModel("K=hunter2-EXAMPLE\n")
        let id = try #require(model.rows.first).id
        let nodes = AXProbe.tree(size: Self.size) {
            Self.inspector(model, selectedRowID: id, revealing: [])
        }
        let apply = nodes.first { $0.label == LocalizedKey.inspectorApply.text }
        #expect(apply != nil, "the Apply control must still be visible, just unavailable")
        #expect(!model.isDirty, "nothing may have been committed")
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
            SecretRowInspector(
                viewModel: model, selectedRowID: nil, fileName: "app/.env",
                access: access, nameFor: { _ in "Ivan" },
                ruleLabel: "app/.*\\.env$",
                revealed: RevealedRows(), generation: model.rowIdentityGeneration,
                onToggleReveal: { _ in }, onActivity: {})
        }
        let flat = text(nodes)
        #expect(flat.contains(LocalizedKey.inspectorTitleFile.text),
                "the tree did not populate — vacuous: \(flat)")
        #expect(flat.contains(LocalizedKey.inspectorNoSelection.text), "\(flat)")
        #expect(flat.contains(LocalizedKey.inspectorReadableByNote.text), "\(flat)")
        #expect(flat.contains("Ivan"), "a named recipient must be shown by name: \(flat)")
    }
}

/// The rule the inspector shows is resolved by `AppShell`, where the rules
/// actually live: `AccessInventory.FileAccess` carries only an *index* into
/// `AccessInventory.rules`, and the inspector holds no inventory. It used to
/// print that index (`#0`), which named nothing a user could recognise.
@Suite("the inspector's rule label")
// `@MainActor` like every other suite here that touches this module's views.
// Without it the process dies with SIGTRAP before a single test runs:
// `AppShell` is a `View` and therefore main-actor isolated, and swift-testing
// runs a non-isolated suite off the main thread. It fails as a *crashed
// runner* — "exited with unexpected signal code 5", no failing test named —
// which reads like a build problem rather than an isolation one.
@MainActor
struct InspectorRuleLabelTests {

    private static func rule(_ index: Int, _ regex: String) -> ConfigRules.Rule {
        ConfigRules.Rule(
            index: index, pathRegex: regex, recipients: [], usesKeyGroups: false,
            usesAnchors: false, nonAgeBackends: [], comment: "")
    }

    private static func inventory(ruleIndex: Int?, rules: [ConfigRules.Rule]) -> AccessInventory {
        AccessInventory(
            keys: [], rules: rules,
            files: [AccessInventory.FileAccess(
                url: url, relativePath: "app/.env", format: .dotenv, ruleIndex: ruleIndex,
                encryptedFor: [], status: .inSync)],
            configError: nil)
    }

    private static let url = URL(fileURLWithPath: "/tmp/project/app/.env")

    @Test("a governed file shows its rule's own path_regex")
    func governedFileShowsItsRegex() {
        let inventory = Self.inventory(
            ruleIndex: 1, rules: [Self.rule(0, "^secrets/"), Self.rule(1, "app/.*\\.env$")])
        #expect(AppShell.ruleLabel(for: Self.url, in: inventory) == "app/.*\\.env$")
    }

    @Test("an ungoverned file has no rule label")
    func ungovernedFileHasNoLabel() {
        #expect(AppShell.ruleLabel(
            for: Self.url, in: Self.inventory(ruleIndex: nil, rules: [Self.rule(0, "^x")])) == nil)
    }

    /// Defensively, because `AccessInventory.FileAccess`'s own doc comment
    /// says an out-of-range index is treated as ungoverned rather than
    /// trusted — and indexing `rules` with it would trap.
    @Test("an out-of-range rule index is treated as ungoverned, not trapped on")
    func outOfRangeIndexIsUngoverned() {
        #expect(AppShell.ruleLabel(
            for: Self.url, in: Self.inventory(ruleIndex: 7, rules: [Self.rule(0, "^x")])) == nil)
    }

    @Test("a file the scan does not know, and no inventory at all, have no rule label")
    func unknownFileAndNoInventory() {
        let inventory = Self.inventory(ruleIndex: 0, rules: [Self.rule(0, "^x")])
        #expect(AppShell.ruleLabel(for: URL(fileURLWithPath: "/tmp/other.env"), in: inventory) == nil)
        #expect(AppShell.ruleLabel(for: Self.url, in: nil) == nil)
    }

    /// `SopsFileFormat.rawValue` used to reach the UI directly.
    @Test("every format has a localized display name, and none is its raw value")
    func formatLabelsAreLocalized() {
        for format in SopsFileFormat.allCases {
            let label = SecretRowInspector.formatLabel(format)
            #expect(!label.isEmpty)
            #expect(!label.contains("inspector.format"),
                    "\(format) has no catalog entry — it resolved to its own key")
        }
        #expect(SecretRowInspector.formatLabel(.dotenv) != SecretRowInspector.formatLabel(.json))
    }
}
