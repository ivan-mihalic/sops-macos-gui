import Foundation
import Testing
@testable import SopsHealth
@testable import SopsUI

private func finding(_ id: String, _ status: HealthStatus) -> HealthFinding {
    HealthFinding(id: id, title: id, status: status, detail: "")
}

@Suite("OnboardingSummaryState.compute")
struct OnboardingSummaryStateComputeTests {

    @Test("an in-flight scan never reports a verdict, even with stale findings still sitting around")
    func inFlightNeverAsserts() {
        #expect(OnboardingSummaryState.compute(isRunning: true, findings: []) == .checking)
        #expect(OnboardingSummaryState.compute(isRunning: true, findings: [finding("a", .ok)]) == .checking)
    }

    // This is the trap: HealthReport.worstStatus(in: []) == .ok, so handing an
    // empty array straight to the user would read as "everything checks out."
    @Test("an empty finding set never reports an all-clear, even when isRunning is already false")
    func emptyFindingsNeverAssertsOK() {
        #expect(OnboardingSummaryState.compute(isRunning: false, findings: []) == .checking)
    }

    @Test("a settled scan reports the worst finding, once findings actually exist")
    func settledReportsWorst() {
        #expect(OnboardingSummaryState.compute(isRunning: false, findings: [finding("a", .ok)]) == .verdict(.ok))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, findings: [finding("a", .ok), finding("b", .warning)]) == .verdict(.warning))
        #expect(OnboardingSummaryState.compute(isRunning: false, findings: [finding("a", .problem)]) == .verdict(.problem))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, findings: [finding("a", .skipped(reason: "x"))]) == .verdict(.skipped(reason: "x")))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, findings: [finding("a", .unknown(reason: "y"))]) == .verdict(.unknown(reason: "y")))
    }
}

/// Blocks a check's `run()` until the test opens it — used to hold a real
/// `HealthViewModel.refresh()` genuinely mid-flight so the summary's *actual*
/// inputs (`isRunning`, `findings`), not just the pure function in isolation,
/// are probed for a premature verdict. Mirrors the pattern already used in
/// HealthViewModelTests to prove refresh() coalescing.
private actor SummaryGate {
    private var isOpen = false
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    private var arrivedContinuation: CheckedContinuation<Void, Never>?

    func waitUntilOpen() async {
        hasArrived = true
        arrivedContinuation?.resume()
        arrivedContinuation = nil
        if isOpen { return }
        await withCheckedContinuation { openContinuation = $0 }
    }

    func waitUntilArrived() async {
        if hasArrived { return }
        await withCheckedContinuation { arrivedContinuation = $0 }
    }

    func open() {
        isOpen = true
        openContinuation?.resume()
        openContinuation = nil
    }
}

private struct GatedOKCheck: HealthCheck {
    let id = "gated"
    let category = HealthCategory.tools
    let gate: SummaryGate
    func run() async -> [HealthFinding] {
        await gate.waitUntilOpen()
        return [HealthFinding(id: "tool.gated", title: "Gated", status: .ok, detail: "done")]
    }
}

@Suite("OnboardingWizard summary, held open mid-scan")
@MainActor
struct OnboardingSummaryMidScanTests {

    // Reproduces the reviewer's exact scenario: a user clicks Continue through
    // every step faster than the scan completes, landing on .summary while the
    // report is still running. Against the pre-fix code (health.headlineStatus
    // switched on directly) this would assert .verdict(.ok) here, because
    // HealthReport.worstStatus(in: []) == .ok for the still-empty findings
    // array — exactly the false all-clear this test exists to catch.
    @Test("holding the report open mid-run and driving state to .summary never yields an all-clear")
    func heldOpenMidRunNeverAllClears() async {
        let gate = SummaryGate()
        let health = HealthViewModel(report: HealthReport(checks: [GatedOKCheck(gate: gate)]))
        let state = OnboardingState(defaults: UserDefaults(suiteName: "onboarding-summary-" + UUID().uuidString)!)

        for _ in OnboardingStep.allCases.dropFirst() { state.advance() }
        #expect(state.step == .summary)

        async let refresh: Void = health.refresh()

        // Wait for the check to genuinely be reached, not merely scheduled.
        await gate.waitUntilArrived()
        #expect(health.isRunning == true)
        #expect(health.findings.isEmpty)

        let midRun = OnboardingSummaryState.compute(isRunning: health.isRunning, findings: health.findings)
        #expect(midRun == .checking)
        #expect(midRun != .verdict(.ok), "the summary must never assert an all-clear before the scan has a result")

        await gate.open()
        await refresh

        let settled = OnboardingSummaryState.compute(isRunning: health.isRunning, findings: health.findings)
        #expect(settled == .verdict(.ok))
    }
}
