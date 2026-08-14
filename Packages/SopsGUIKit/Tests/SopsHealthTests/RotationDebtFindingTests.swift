import Foundation
import Testing
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// An in-memory `RotationDebtSource`, standing in for
/// `SopsProjects.RotationDebtLedger` — a real file-backed implementation is
/// exercised by `SopsProjectsTests/RotationDebtLedgerTests.swift` and by
/// `SopsUITests`' `RecipientAccessTests`/`ProjectAccessTests`. This module
/// cannot depend on `SopsProjects` (see `RotationDebtSource`'s own doc
/// comment), so what belongs here is proving `ProjectHealthCheck` calls the
/// seam correctly, not proving the seam's real persistence.
private final class RecordingRotationDebt: RotationDebtSource, @unchecked Sendable {
    private(set) var entries: [RotationDebtEntry] = []
    private(set) var recordCallCount = 0

    func rotationDebt(in project: URL) -> [RotationDebtEntry] { entries }

    func record(path: String, reason: RotationDebtReason, in project: URL) {
        recordCallCount += 1
        guard !entries.contains(where: { $0.path == path && $0.reason == reason }) else { return }
        entries.append(RotationDebtEntry(path: path, reason: reason))
    }
}

private func rotationDebtFinding(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix("rotation-debt") }!
}

private func leakFinding(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix("gitignore") }!
}

private func run(_ root: URL, rotationDebt: any RotationDebtSource) async -> [HealthFinding] {
    await ProjectHealthCheck(
        source: Projects(projects: [InspectedProject(name: "demo", rootPath: root.path)]),
        rotationDebt: rotationDebt
    ).run()
}

@Suite("ProjectHealthCheck rotation debt (ticket #3)")
struct RotationDebtFindingTests {

    @Test("a project with no recorded debt reports ok")
    func noDebtIsOK() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write(
            "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n", to: root, at: ".sops.yaml")

        let finding = rotationDebtFinding(await run(root, rotationDebt: NoRotationDebt()))
        #expect(finding.status == .ok)
    }

    /// The core of ticket #3: a debt this app already knows about must show
    /// up in the health report regardless of what the current scan finds —
    /// it is read straight from the ledger, not re-derived.
    @Test("a debt recorded earlier is reported even though nothing in this scan would have found it")
    func recordedDebtSurvivesIndependentlyOfTheCurrentScan() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        let key = try ProjectFixture.ageKeyPair()
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        // A perfectly healthy, fully re-wrapped file — nothing about this
        // scan would flag anything on its own.
        try ProjectFixture.write(
            try ProjectFixture.encrypted("db: hunter2\n", to: [key.public]), to: root, at: "secrets.yaml")

        let debt = RecordingRotationDebt()
        debt.record(path: "secrets.yaml", reason: .recipientRemoved, in: root)

        let finding = rotationDebtFinding(await run(root, rotationDebt: debt))
        #expect(finding.status == .problem)
        #expect(finding.detail.contains("secrets.yaml"))
        // Honest about what this app does and does not know.
        #expect(finding.remediation?.explanation.contains("cannot verify") == true)
    }

    @Test("recording is idempotent across repeated health check runs")
    func repeatedRunsDoNotDuplicateEntries() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write(
            "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: ".env")
        try ProjectFixture.gitAdd(root, ".env")

        let debt = RecordingRotationDebt()
        _ = await run(root, rotationDebt: debt)
        _ = await run(root, rotationDebt: debt)

        #expect(debt.entries.count == 1)
    }

    /// Ticket #3, claim 3's acceptance criterion, exercised end to end
    /// through the real health check (not just the ledger unit test):
    /// a tracked plaintext secret records a debt, and un-tracking the file
    /// — the exact action that makes `gitignoreFinding` stop mentioning it
    /// — does not make the rotation-debt finding stop either.
    @Test("un-tracking a plaintext secret does not clear its recorded rotation debt")
    func untrackingDoesNotClearRecordedDebt() async throws {
        let root = try ProjectFixture.makeDirectory()
        let git = try ProjectFixture.gitInit(root)
        try ProjectFixture.write(
            "creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: ".env")
        try ProjectFixture.gitAdd(root, ".env")

        let debt = RecordingRotationDebt()
        let firstRun = await run(root, rotationDebt: debt)
        #expect(leakFinding(firstRun).status == .problem)
        #expect(rotationDebtFinding(firstRun).status == .problem)

        // Un-track and delete the file — the condition `gitignoreFinding`
        // reads goes away entirely.
        _ = try ProjectFixture.run(git, ["-C", root.path, "rm", "--cached", "-q", "--", ".env"])
        try FileManager.default.removeItem(at: root.appendingPathComponent(".env"))

        let secondRun = await run(root, rotationDebt: debt)
        #expect(leakFinding(secondRun).status == .ok, "the file is gone, so the leak finding should clear")
        #expect(rotationDebtFinding(secondRun).status == .problem, "but the debt this app already recorded must not")
        #expect(rotationDebtFinding(secondRun).detail.contains(".env"))
    }
}
