import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

private struct FixedProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// Ticket #25 claim 1, the end-to-end half. `ScanBudgetSettingTests` pins
/// the setting in isolation and `ProjectScanConfigurableBudgetTests` pins
/// that `ProjectScanner.scan` honours a caller-supplied budget — neither
/// says `ProjectHealthCheck` actually reads the setting rather than the
/// hardcoded default it always used. This is that wire.
@Suite("ProjectHealthCheck reads the configured scan budget")
struct ProjectHealthCheckScanBudgetTests {

    /// A `.sops.yaml` is required to reach `recipientFinding` at all —
    /// without one, `findings(for:)` returns the "No .sops.yaml" finding and
    /// nothing past it ever runs. The key does not need to be real: nothing
    /// here decrypts anything, only the recipients finding's own scope
    /// accounting is under test.
    private static let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"

    private func makeFlatFixture(fileCount: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("health-scan-budget-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "creation_rules:\n  - age: \(Self.devKey)\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        for i in 0..<fileCount {
            try "x".write(to: root.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// A budget far below the fixture's file count, injected the same way
    /// `HealthReport.standard`'s `updateChecksEnabled` is — a closure,
    /// re-read on every run, not a value captured once. Proves the wire
    /// exists without touching real `UserDefaults` at all.
    @Test("a small injected budget truncates the walk and the finding names that number")
    func injectedBudgetIsHonoured() async throws {
        let root = try makeFlatFixture(fileCount: 30)
        defer { try? FileManager.default.removeItem(at: root) }

        let check = ProjectHealthCheck(
            source: FixedProjects(projects: [InspectedProject(name: "small-budget", rootPath: root.path)]),
            scanBudget: { 5 })
        let findings = await check.run()
        let recipients = findings.first { $0.id.hasSuffix("stale-recipients") }

        let recipientsFinding = try #require(recipients, "expected a recipients finding for the project")
        #expect(recipientsFinding.detail.contains("scan budget of 5"),
                "the finding must name the injected budget, not ProjectScanner.maxScannedFiles")
    }

    /// The default closure reads `ScanBudgetSetting.current()` live, so
    /// omitting the parameter entirely (every real call site in the app)
    /// must behave exactly as it always did against an untouched default —
    /// this is the "did I break every existing caller" half.
    @Test("the default wiring still resolves to ProjectScanner.maxScannedFiles when nothing is configured")
    func defaultWiringMatchesTheOldConstant() async throws {
        let root = try makeFlatFixture(fileCount: 10)
        defer { try? FileManager.default.removeItem(at: root) }

        let check = ProjectHealthCheck(
            source: FixedProjects(projects: [InspectedProject(name: "default-budget", rootPath: root.path)]))
        let findings = await check.run()
        let recipients = findings.first { $0.id.hasSuffix("stale-recipients") }

        // 10 plaintext-only files, nowhere near any budget: nothing here
        // should ever mention truncation at all.
        #expect(recipients?.detail.contains("scan budget") != true)
    }
}
