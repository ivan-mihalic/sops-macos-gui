import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

/// SOPS-39 Task 8. What the Access *page* — the destination the sidebar's
/// Access row navigates to, not a sheet — actually shows about a real
/// project: the anchor names its `.sops.yaml` gives its keys, which creation
/// rule governs the selected file, and which file has drifted from the rule
/// that governs it.
///
/// Read off the accessibility tree rather than off the model, for the reason
/// `AccessibilityTreeTests` gives at length: a fact that is correct in a
/// model and absent from the view is exactly the class of defect a
/// model-only assertion cannot see. The rewrap half is driven through the
/// model instead — `.sheet(item:)` content is not rendered by `AXProbe`, so
/// pressing the button in a probe would prove nothing about what the sheet
/// then does.
@Suite("SOPS-39 Task 8 — the Access page")
@MainActor
struct ProjectAccessPageTests {

    @Test("the page names keys by anchor, highlights the selected file's rule and flags the drifted file")
    func pageShowsNamedKeysAndDrift() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()

        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: f.prod, onFilesApplied: {})
        }
        let flat = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")

        // The anchor names, not the age keys: a project that took the trouble
        // to name its keys should not be rendered as three `age1…` strings.
        #expect(flat.contains("studio") && flat.contains("laptop") && flat.contains("vps"))
        #expect(flat.contains(String(format: LocalizedKey.accessRulesNeedsRewrap.text, 1)))
        #expect(flat.contains(String(format: LocalizedKey.accessRulesEncryptedForOf.text, 2, 3)))
        #expect(flat.contains(LocalizedKey.accessRewrapBanner.text))
        #expect(flat.contains("secrets/prod.sops.env") && flat.contains("secrets/local.sops.env"))
    }

    @Test("Rewrap re-encrypts the drifted file for its rule's recipients and the inventory reports in sync")
    func rewrapClosesTheDrift() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()

        let wanted = try #require(model.inventory?.rules[0].recipients.map(\.recipient))
        model.discardStagedChanges()
        for r in wanted where !model.stagedRecipients.contains(r) { _ = model.stageAdd(r) }

        let refusal = await model.applyToFiles()
        #expect(refusal == nil && model.updatedFileCount == 1)

        await model.load()
        #expect(model.inventory?.filesNeedingRewrap.isEmpty == true)
        #expect(
            try SopsBridge.recipients(
                in: String(contentsOf: f.prod, encoding: .utf8), format: .dotenv
            ).count == 3)
    }
}
