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
        #expect(OnboardingSummaryState.compute(isRunning: true, hasCompletedRefresh: false, findings: []) == .checking)
        #expect(OnboardingSummaryState.compute(
            isRunning: true, hasCompletedRefresh: true, findings: [finding("a", .ok)]) == .checking)
    }

    // This is the trap the *previous* fix round left open: gating on
    // `findings.isEmpty` instead of a real "has this ever settled" signal
    // meant a report that genuinely completes with zero findings — a
    // supported construction (`HealthReport(checks: [])`) — got stuck on
    // `.checking` forever. `hasCompletedRefresh` is the real signal; a
    // completed run with no findings must report `.ok`, not spin forever.
    @Test("a completed run with zero findings reports .ok, not a stuck checking state")
    func emptyCompletedReportReportsOK() {
        #expect(OnboardingSummaryState.compute(isRunning: false, hasCompletedRefresh: true, findings: []) == .verdict(.ok))
    }

    // Belt and suspenders: before a run has ever completed, an empty finding
    // list must not be read as a verdict either.
    @Test("no completed run yet never reports a verdict, even when isRunning is already false")
    func neverCompletedNeverAssertsOK() {
        #expect(OnboardingSummaryState.compute(isRunning: false, hasCompletedRefresh: false, findings: []) == .checking)
    }

    @Test("a settled scan reports the worst finding, once findings actually exist")
    func settledReportsWorst() {
        #expect(OnboardingSummaryState.compute(
            isRunning: false, hasCompletedRefresh: true, findings: [finding("a", .ok)]) == .verdict(.ok))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, hasCompletedRefresh: true,
            findings: [finding("a", .ok), finding("b", .warning)]) == .verdict(.warning))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, hasCompletedRefresh: true, findings: [finding("a", .problem)]) == .verdict(.problem))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, hasCompletedRefresh: true,
            findings: [finding("a", .skipped(reason: "x"))]) == .verdict(.skipped(reason: "x")))
        #expect(OnboardingSummaryState.compute(
            isRunning: false, hasCompletedRefresh: true,
            findings: [finding("a", .unknown(reason: "y"))]) == .verdict(.unknown(reason: "y")))
    }
}

@Suite("HealthViewModel.hasCompletedRefresh, via the real refresh() path")
@MainActor
struct HealthViewModelHasCompletedRefreshTests {

    // Reproduces the reviewer's exact construction: an empty report, refreshed
    // through the real HealthViewModel — not a hand-built compute() call —
    // to prove the flag genuinely reflects refresh() having run, not just
    // that the test asserted it directly.
    @Test("an empty report reports .ok after refresh, never a stuck checking state")
    func emptyReportSettlesToOK() async {
        let health = HealthViewModel(report: HealthReport(checks: []))
        #expect(health.hasCompletedRefresh == false)
        #expect(health.isRunning == false)
        #expect(health.findings.isEmpty)

        await health.refresh()

        #expect(health.hasCompletedRefresh == true)
        #expect(health.isRunning == false)
        #expect(health.findings.isEmpty)
        #expect(OnboardingSummaryState.compute(
            isRunning: health.isRunning, hasCompletedRefresh: health.hasCompletedRefresh,
            findings: health.findings) == .verdict(.ok))
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

        let midRun = OnboardingSummaryState.compute(
            isRunning: health.isRunning, hasCompletedRefresh: health.hasCompletedRefresh, findings: health.findings)
        #expect(midRun == .checking)
        #expect(midRun != .verdict(.ok), "the summary must never assert an all-clear before the scan has a result")

        await gate.open()
        await refresh

        let settled = OnboardingSummaryState.compute(
            isRunning: health.isRunning, hasCompletedRefresh: health.hasCompletedRefresh, findings: health.findings)
        #expect(settled == .verdict(.ok))
    }
}
