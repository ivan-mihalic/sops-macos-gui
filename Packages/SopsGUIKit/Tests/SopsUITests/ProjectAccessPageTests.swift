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

    @Test("a file no rule governs is listed under its own heading, with the keys it is wrapped for")
    func ungovernedFilesAreListed() async throws {
        let f = try await AccessPageFixture.momentakShaped(includeUngoverned: true)
        _ = try #require(f.stray)
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()
        // The premise: this really is ungoverned, not merely absent from the
        // rule cards for some other reason. Found by relative path — see
        // `AccessPageFixture` on why `url ==` does not hold here.
        #expect(
            model.inventory?.files.first { $0.relativePath == "stray.env" }?.status
                == .ungoverned)

        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: f.prod, onFilesApplied: {})
        }
        let flat = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")

        #expect(flat.contains(LocalizedKey.accessUngoverned.text))
        #expect(flat.contains("stray.env"))
        // And who can read it — the question a file outside every rule
        // actually raises.
        #expect(flat.contains("studio"))
    }

    @Test("opening Access before any file was selected still offers the plan's own rule for editing")
    func noSelectedFileFallsBackToThePlansTarget() async throws {
        // Inline recipients on the catch-all rule: with anchors it would be
        // read-only for a reason that has nothing to do with what is under
        // test, and the add control would be absent either way.
        let f = try await AccessPageFixture.momentakShaped(inlineCatchAllRecipients: true)
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore)
        await model.load()
        // No `targetFile` was given, so the plan picked the first file in
        // path order — the rule the model stages against.
        let target = try #require(model.plan?.targetFile)
        #expect(model.inventory?.files.first { $0.url == target }?.ruleIndex != nil,
                "the plan's own target must be a file the inventory knows")

        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: nil, onFilesApplied: {})
        }
        let flat = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")

        // The add button and the per-chip remove control are the visible
        // consequences of a rule being editable, and neither appeared
        // anywhere at all before this fell back to the plan's own target.
        //
        // Not the text field's placeholder: an empty `TextField` vends no
        // label of its own to the accessibility tree, so asserting on it
        // would fail for a reason that has nothing to do with editability.
        #expect(flat.contains(LocalizedKey.actionAdd.text))
        #expect(flat.contains(LocalizedKey.accessRemoveRecipient.text))
    }

    @Test("a recipient the rule already names is refused out loud, not swallowed")
    func duplicateRecipientIsExplained() {
        // The refusal the page routes to its alert. Pinned as a pure
        // function because a `.alert`'s own body is not reachable from a
        // unit test — the same documented limitation
        // `WorkspaceSwitchDecisionTests` states for a `.confirmationDialog`,
        // and the reason the string a dialog is *handed* is the last thing
        // that can be pinned.
        #expect(ProjectAccessPage.explanation(for: .duplicate) == .accessAddDuplicate)
        #expect(ProjectAccessPage.explanation(for: .empty) == nil)
        #expect(ProjectAccessPage.explanation(for: .notLoaded) == nil)
    }

    /// SOPS-39 task 9. The one edit an anchored rule supports, end to end:
    /// the button is offered on a read-only rule, and picking a key writes
    /// `.sops.yaml` — which is the moment a file that was in sync becomes
    /// drifted, because a config edit re-encrypts nothing.
    @Test("adding a named key to an anchored rule writes the alias and drifts the file it governs")
    func addingANamedKeyToAnAnchoredRule() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()

        // The premise: rule 1 goes through aliases, so it is read-only and
        // `local.sops.env` currently agrees with it. One file drifts today.
        let before = try #require(model.inventory)
        #expect(before.rules[1].usesAnchors)
        #expect(before.files.first { $0.relativePath == "secrets/local.sops.env" }?.status == .inSync)
        #expect(before.filesNeedingRewrap.count == 1)

        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: f.prod, onFilesApplied: {})
        }
        let flat = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
        // Offered next to the read-only sentence — the sheet's own content is
        // not reachable from a probe (`.sheet` is not rendered), so the pick
        // itself is driven through the model below.
        #expect(flat.contains(LocalizedKey.accessRulesAnchoredReadOnly.text))
        #expect(flat.contains(LocalizedKey.accessRulesAddNamed.text))

        let outcome = await model.addAliasToRule(ruleIndex: 1, anchor: "vps")
        #expect(outcome == .written)

        // The alias, by name, in the file — not the literal key behind it.
        let config = try String(
            contentsOf: f.root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(config.contains("*vps"))
        #expect(config.contains("# Production secrets: everyone, including the deploy host."))

        let after = try #require(model.inventory)
        #expect(after.rules[1].recipients.map(\.name) == ["studio", "laptop", "vps"])
        // `local.sops.env` is now behind its own rule, and the banner says so
        // for both files. Nothing was re-encrypted — that is the whole point
        // of the note under the picker.
        #expect(after.files.first { $0.relativePath == "secrets/local.sops.env" }.map {
            if case .ruleDiffers = $0.status { return true } else { return false }
        } == true)
        #expect(after.filesNeedingRewrap.count == 2)
    }

    @Test("the bridge's refusal to add a key twice reaches the page as a failure")
    func addingADuplicateNamedKeyIsRefused() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()
        if case .failed = await model.addAliasToRule(ruleIndex: 1, anchor: "studio") {
        } else {
            Issue.record("a key the rule already names must be refused")
        }
    }

    /// The fingerprint guard, exercised: `.sops.yaml` changed on disk after
    /// the plan read it, so the write is refused rather than clobbering
    /// whatever the other writer put there.
    @Test("a config that changed since the page read it is not overwritten")
    func staleConfigIsRefused() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()

        let configURL = f.root.appendingPathComponent(".sops.yaml")
        let mine = try String(contentsOf: configURL, encoding: .utf8)
        try (mine + "\n# someone else was here\n").write(
            to: configURL, atomically: true, encoding: .utf8)

        if case .failed = await model.addAliasToRule(ruleIndex: 1, anchor: "vps") {
        } else {
            Issue.record("a stale config must not be overwritten")
        }
        let onDisk = try String(contentsOf: configURL, encoding: .utf8)
        // Untouched: the other writer's line is still the last one, and the
        // catch-all rule still names two keys rather than three.
        #expect(onDisk.hasSuffix("# someone else was here\n"))
        #expect(onDisk == mine + "\n# someone else was here\n")
    }

    // MARK: - Final SOPS-39 review fixes

    /// I1. The page wrote `.sops.yaml` on one click for three commits: the
    /// confirmation `ProjectAccessView` raised — and the two disclosures it
    /// carried — went out with that view in task 10.
    ///
    /// Read as source text, not through `AXProbe`: a `confirmationDialog`'s
    /// own body is not rendered by the probe (the same limitation the deleted
    /// tests worked around by exposing the message string), so what can be
    /// checked is that the button opens the dialog rather than writing, and
    /// that the dialog is handed the two sentences. What those sentences
    /// *say* is `LocalizationTests`'
    /// `configUpdateConfirmationDisclosesReformatting` and
    /// `configUpdateRemovalSentenceDisclaimsRevocation`.
    ///
    /// Comments stripped first, for the reason
    /// `ScrollOverflowFadeCoverageTests` records at length: this suite has
    /// lost source-text guards to a commented-out call three separate times.
    @Test("the Update .sops.yaml button opens a confirmation rather than writing")
    func configWriteIsConfirmedFirst() throws {
        let source = OuterSidebarWiringTests.strippingComments(try Self.pageSource())

        #expect(source.contains(".confirmationDialog("),
                "the page must confirm before writing .sops.yaml")
        #expect(source.contains("projectAccessUpdateConfigConfirmTitle"))
        #expect(source.contains("projectAccessUpdateConfigConfirmMessage"))
        #expect(source.contains("projectAccessConfigLoses"),
                "the confirmation must carry the revocation disclaimer")
        // The button stages the confirmation; nothing on that path writes.
        #expect(
            source.contains(
                """
                Button(LocalizedKey.projectAccessUpdateConfigButton.text) {
                                    confirmingConfigUpdate = true
                """),
            "the Update button must open the dialog, not call applyConfig()")
        // And exactly one caller of `applyConfig()` — the dialog's own
        // confirm button. A second call site would be a way around it.
        #expect(source.components(separatedBy: "await applyConfig()").count - 1 == 1,
                "applyConfig() must be reachable only from the confirmation")
    }

    /// I3. Both `.sops.yaml` writes open drift for every file their rule
    /// governs, and the tree draws that drift as a status dot it recomputes
    /// only when told to — so a write that does not call `onFilesApplied()`
    /// leaves the sidebar showing the state from before it.
    @Test("both config writes ask the tree to rescan")
    func configWritesRefreshTheTree() throws {
        let source = OuterSidebarWiringTests.strippingComments(try Self.pageSource())
        for name in ["applyConfig", "addNamedKey"] {
            let function = try #require(
                source.range(of: "private func \(name)(").map { String(source[$0.lowerBound...]) },
                "\(name) is gone or renamed")
            let scope = String(function.prefix(900))
            #expect(scope.contains("case .written:"), "\(name) no longer separates .written")
            let written = try #require(scope.range(of: "case .written:"))
            let next = try #require(scope.range(of: "case .", range: written.upperBound..<scope.endIndex))
            #expect(scope[written.upperBound..<next.lowerBound].contains("onFilesApplied()"),
                    "\(name)'s .written branch must rescan the tree")
        }
    }

    /// I3, behaviourally: after a config write the project's inventory really
    /// does report drift, so a tree that rescans shows a dot and one that
    /// does not shows none. The write is `addAliasToRule` because it is the
    /// one this fixture's anchored rule supports.
    @Test("a config write leaves the project's files drifted from their rule")
    func aConfigWriteOpensDrift() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.local)
        await model.load()
        let before = try #require(model.inventory).filesNeedingRewrap.count

        guard case .written = await model.addAliasToRule(ruleIndex: 1, anchor: "vps") else {
            Issue.record("adding an unnamed anchor to the catch-all rule must be written")
            return
        }
        await model.load()
        #expect(try #require(model.inventory).filesNeedingRewrap.count > before,
                "the rule now wants a key its files do not have")
    }

    /// I2. `addAliasToRule` set `configWritten` and *then* called `load()`,
    /// which resets it — so the commit reminder never appeared after an alias
    /// write, the one path in this feature that writes `.sops.yaml` without
    /// going through `applyConfig()`. Writing the team's config and never
    /// asking for a commit is exactly what `CommitRemindersTests` exists to
    /// prevent.
    @Test("an alias write leaves the commit reminder showing")
    func aliasWriteAsksForACommit() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()
        #expect(model.configWritten == false, "nothing has been written yet")

        guard case .written = await model.addAliasToRule(ruleIndex: 1, anchor: "vps") else {
            Issue.record("the alias write must succeed for this to say anything")
            return
        }
        #expect(model.configWritten, "the commit reminder must survive the reload")

        // And it reaches the page, which is where the user reads it.
        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: f.prod, onFilesApplied: {})
        }
        let flat = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
        #expect(flat.contains(LocalizedKey.projectAccessConfigWritten.text))
    }

    // MARK: - T8: a project with nothing to organise

    /// The page is built out of creation rules and encrypted files, so a
    /// project with neither drew a title, two notes and nothing else — which
    /// reads as a screen that failed to load. Each of the three ways that
    /// happens now says which one it is.
    @Test("a project with no .sops.yaml explains itself instead of rendering nothing")
    func emptyProjectWithoutConfigExplains() async throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("access-empty-noconfig")
        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore(), targetFile: nil)
        await model.load()

        let flat = Self.probe(model)
        #expect(flat.contains(LocalizedKey.newFileInfoNoConfig.text))
        #expect(!flat.contains(LocalizedKey.accessEmptyNoFiles.text),
                "a project with no config must not be described as one that has one")
    }

    @Test("a project with a config but no encrypted files says so")
    func emptyProjectWithConfigExplains() async throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("access-empty-nofiles")
        try "creation_rules: []\n".write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore(), targetFile: nil)
        await model.load()

        let flat = Self.probe(model)
        #expect(flat.contains(LocalizedKey.accessEmptyNoFiles.text))
    }

    /// A `.sops.yaml` that exists and cannot be read: the bridge's own reason
    /// is fixed text naming the file and the parse failure, never a key or a
    /// value, and the only next step this app can offer is the file itself —
    /// it never edits `.sops.yaml` by hand.
    @Test("an unreadable .sops.yaml shows the reason and a way to open the file")
    func configErrorIsExplainedAndActionable() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        try "keys: [\n  - &broken\ncreation_rules:\n".write(
            to: f.root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()
        // The reason lands on the *plan*: a config that exists and cannot be
        // read leaves `plan.inventory` as `AccessInventory.empty`, whose own
        // `configError` is nil. Reading only the inventory's is what made
        // this state render as a blank page.
        let error = try #require(model.plan?.configError, "the fixture must not parse")

        let flat = Self.probe(model)
        #expect(flat.contains(LocalizedKey.projectAccessConfigErrorTitle.text))
        #expect(flat.contains(error))
        #expect(flat.contains(LocalizedKey.accessRulesRevealConfig.text),
                "a config this app cannot read must still offer the file itself")
    }

    private static func probe(_ model: ProjectAccessModel) -> String {
        AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: nil, onFilesApplied: {})
        }
        .map { $0.label + " " + $0.value + " " + $0.help }
        .joined(separator: "\n")
    }

    /// `Tests/SopsUITests/…` → package root → the page's own source, the same
    /// way `ScrollOverflowFadeCoverageTests` reaches the views it greps.
    private static func pageSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SopsUI/Projects/ProjectAccessPage.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

}
