import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

/// SOPS-39 task 8. `RewrapCoordinator` is the one place in this app that
/// builds `ProjectAccessModel`s of its own, and the one operation that spans
/// creation rules — so it is also the one place a project-wide "fix the
/// drift" button could quietly re-wrap one rule's files for another rule's
/// keys, or give up halfway and report success.
///
/// Driven through the model rather than through the page: the rewrap sheet's
/// content is not rendered by `AXProbe`, and what matters here is the bytes
/// on disk and the run's own bookkeeping, not the layout that shows it.
@Suite("SOPS-39 task 8 — the rewrap coordinator")
@MainActor
struct RewrapCoordinatorTests {

    @Test("only the drifted rule's files are touched; a rule already in sync is left alone")
    func rewrapsOnlyDriftedRules() async throws {
        let f = try await AccessPageFixture.momentakShaped()
        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()
        let inventory = try #require(model.inventory)

        let coordinator = RewrapCoordinator(projectRoot: f.root, keyStore: f.keyStore)
        await coordinator.rewrap(inventory)

        #expect(!coordinator.isRunning)
        #expect(coordinator.skipped.isEmpty)
        // `local.sops.env` was in sync, and its rule is therefore never even
        // loaded — the coordinator visits rules that have drifted files, not
        // every rule in the config.
        #expect(coordinator.results.map { $0.url.lastPathComponent } == ["prod.sops.env"])
        #expect(coordinator.updatedCount == 1)

        // Measured on disk, not on the coordinator: what a rewrap claims and
        // what a reader can now open are different assertions.
        #expect(
            try SopsBridge.recipients(
                in: String(contentsOf: f.prod, encoding: .utf8), format: .dotenv
            ).count == 3)
        #expect(
            try SopsBridge.recipients(
                in: String(contentsOf: f.local, encoding: .utf8), format: .dotenv
            ).count == 2)

        await model.load()
        #expect(model.inventory?.filesNeedingRewrap.isEmpty == true)
    }

    /// The regression this suite exists for. Two rules have drifted; the
    /// **first** of them declares no age recipient at all, so re-wrapping its
    /// files can only be refused — and the second rule's file must still be
    /// re-wrapped afterwards.
    ///
    /// ⚠️ Ablation: replace `skipped.append(…); continue` in
    /// `RewrapCoordinator.rewrap(_:)` with a `return` and this test goes red
    /// on `results` — `prod` is never reached. A coordinator that stops at
    /// the first refusal leaves a project half-rewrapped with nothing on
    /// screen saying which half.
    @Test("a rule that cannot be staged is skipped by name, and the rest of the run still happens")
    func aRefusedRuleIsSkippedAndTheRunContinues() async throws {
        let f = try await AccessPageFixture.momentakShaped(includeRefusingRule: true)
        let legacy = try #require(f.legacy)

        let model = ProjectAccessModel(projectRoot: f.root, keyStore: f.keyStore, targetFile: f.prod)
        await model.load()
        let inventory = try #require(model.inventory)
        // Both drifted, and the refusing rule is first — so a run that gave
        // up on the first refusal would produce an empty `results`.
        // By relative path, never by `url ==` — see `AccessPageFixture`'s
        // note on the `/var` versus `/private/var` spellings.
        #expect(
            Set(inventory.filesNeedingRewrap.map(\.relativePath))
                == ["legacy/old.sops.env", "secrets/prod.sops.env"])
        let legacyRuleIndex = try #require(
            inventory.files.first { $0.relativePath == "legacy/old.sops.env" }?.ruleIndex)
        let prodRuleIndex = try #require(
            inventory.files.first { $0.relativePath == "secrets/prod.sops.env" }?.ruleIndex)
        #expect(legacyRuleIndex < prodRuleIndex)

        let coordinator = RewrapCoordinator(projectRoot: f.root, keyStore: f.keyStore)
        await coordinator.rewrap(inventory)

        #expect(!coordinator.isRunning)
        #expect(coordinator.skipped.count == 1)
        #expect(coordinator.results.map { $0.url.lastPathComponent } == ["prod.sops.env"])
        #expect(coordinator.updatedCount == 1)
        #expect(coordinator.failedCount == 0)

        // The refused rule's file is untouched — not re-wrapped for an empty
        // recipient set, which would have made it unreadable by everyone.
        #expect(
            try SopsBridge.recipients(
                in: String(contentsOf: legacy, encoding: .utf8), format: .dotenv
            ) == [f.studio.public])
        #expect(
            try SopsBridge.recipients(
                in: String(contentsOf: f.prod, encoding: .utf8), format: .dotenv
            ).count == 3)
    }
}
