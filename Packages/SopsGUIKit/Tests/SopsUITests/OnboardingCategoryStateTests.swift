import Foundation
import Testing
@testable import SopsHealth
@testable import SopsUI

private func finding(_ id: String, _ status: HealthStatus) -> HealthFinding {
    HealthFinding(id: id, title: id, status: status, detail: "")
}

/// I3. Task 14 gated the wizard's *summary* against asserting a verdict before
/// the scan settled. The four category steps in front of it were not gated at
/// all: they rendered `List(health.findings(in: category))`, which mid-scan is
/// an empty array, so a user clicking Continue faster than the ~0.4s scan saw
/// "Tools", "Engine", "Security" and "Projects" each with nothing under them.
/// Blank space under a category heading reads as "nothing wrong here" — the
/// same implied all-clear that made the summary a Critical.
@Suite("OnboardingCategoryState.compute")
struct OnboardingCategoryStateTests {

    @Test("an in-flight scan shows progress, never an empty list that reads as an all-clear")
    func inFlightIsChecking() {
        #expect(OnboardingCategoryState.compute(
            isRunning: true, hasCompletedRefresh: false, findingsInCategory: []) == .checking)
        // Stale findings from a previous run must not be presented as the
        // current one either.
        #expect(OnboardingCategoryState.compute(
            isRunning: true, hasCompletedRefresh: true,
            findingsInCategory: [finding("tool.sops", .ok)]) == .checking)
    }

    @Test("before any run has completed the step never presents results")
    func neverCompletedIsChecking() {
        #expect(OnboardingCategoryState.compute(
            isRunning: false, hasCompletedRefresh: false, findingsInCategory: []) == .checking)
        #expect(OnboardingCategoryState.compute(
            isRunning: false, hasCompletedRefresh: false,
            findingsInCategory: [finding("tool.sops", .ok)]) == .checking)
    }

    @Test("a completed run with nothing in this category says so rather than showing blank space")
    func completedButEmptyIsStated() {
        #expect(OnboardingCategoryState.compute(
            isRunning: false, hasCompletedRefresh: true, findingsInCategory: []) == .empty)
    }

    @Test("a completed run shows exactly the findings it was given, in order")
    func completedShowsFindings() {
        let findings = [finding("tool.sops", .ok), finding("tool.git", .warning)]
        #expect(OnboardingCategoryState.compute(
            isRunning: false, hasCompletedRefresh: true,
            findingsInCategory: findings) == .findings(findings))
    }

    /// The gate must be load-bearing on both inputs independently — the
    /// review found that Task 14's integration test masked one half of the
    /// summary's gate because it only ever exercised a first run.
    @Test("both halves of the gate matter on their own")
    func bothGateInputsAreLoadBearing() {
        // isRunning alone: a second scan in flight, with a completed first run
        // behind it. This is the path `restart()` makes reachable.
        #expect(OnboardingCategoryState.compute(
            isRunning: true, hasCompletedRefresh: true, findingsInCategory: []) == .checking)
        // hasCompletedRefresh alone: nothing scheduled yet, so isRunning is
        // still false but no run has ever produced anything.
        #expect(OnboardingCategoryState.compute(
            isRunning: false, hasCompletedRefresh: false, findingsInCategory: []) == .checking)
    }
}

/// The wizard drives its verdict from every finding, but only ever *showed*
/// findings whose id prefix matched one of the four categories. A finding with
/// an unrecognised prefix therefore set the headline while appearing on no
/// step at all. `HealthPanel` has had an "Other" section for this since Task
/// 12; the wizard now renders `uncategorizedFindings` on the summary step.
@Suite("wizard covers every finding")
@MainActor
struct WizardFindingCoverageTests {

    private struct OrphanCheck: HealthCheck {
        let id = "orphan"
        let category = HealthCategory.tools
        func run() async -> [HealthFinding] {
            [HealthFinding(id: "mystery.thing", title: "Mystery", status: .problem, detail: "drives the verdict")]
        }
    }

    @Test("a finding that belongs to no category still reaches the user, and still drives the verdict")
    func orphanFindingIsVisibleAndCounted() async {
        let health = HealthViewModel(report: HealthReport(checks: [OrphanCheck()]))
        await health.refresh()

        // It appears on none of the four steps...
        for category in HealthCategory.allCases {
            #expect(health.findings(in: category).isEmpty)
        }
        // ...so the wizard must have somewhere else to put it.
        #expect(health.uncategorizedFindings.map(\.id) == ["mystery.thing"])
        // And it must not be able to set the verdict invisibly.
        #expect(OnboardingSummaryState.compute(
            isRunning: health.isRunning, hasCompletedRefresh: health.hasCompletedRefresh,
            findings: health.findings) == .verdict(.problem))
    }

    /// Every finding a real report produces must land in exactly one bucket —
    /// one of the four categories, or Other. Nothing may be counted twice, and
    /// nothing may vanish.
    @Test("every finding of the real report lands in exactly one bucket")
    func realReportPartitionsCleanly() async {
        let health = HealthViewModel(report: .standard(updateChecksEnabled: { false }))
        await health.refresh()

        var bucketed: [String] = health.uncategorizedFindings.map(\.id)
        for category in HealthCategory.allCases {
            bucketed += health.findings(in: category).map(\.id)
        }

        #expect(Set(bucketed) == Set(health.findings.map(\.id)))
        #expect(bucketed.count == health.findings.count, "a finding appears in more than one bucket")
    }
}

/// I1's other half: the toggle that `updateChecksEnabled` reads.
@Suite("UpdateCheckConsent")
struct UpdateCheckConsentTests {

    private func scratchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "update-consent-" + UUID().uuidString)!
    }

    /// The only network request this app makes is gated on this. An unwritten
    /// key must read as "no".
    @Test("consent is off until the user turns it on")
    func defaultsToOff() {
        #expect(UpdateCheckConsent.isEnabled(in: scratchDefaults()) == false)
    }

    @Test("the toggle round-trips through UserDefaults")
    func roundTrips() {
        let defaults = scratchDefaults()
        UpdateCheckConsent.setEnabled(true, in: defaults)
        #expect(UpdateCheckConsent.isEnabled(in: defaults) == true)
        UpdateCheckConsent.setEnabled(false, in: defaults)
        #expect(UpdateCheckConsent.isEnabled(in: defaults) == false)
    }

    /// The report reads the flag on every run rather than capturing it once —
    /// otherwise flipping the toggle would do nothing until the app restarted,
    /// which is how the old hardcoded constant behaved.
    @Test("the report observes a consent change without being rebuilt")
    func reportReadsConsentLive() async {
        // The suite name, not the UserDefaults object, crosses into the
        // closure: UserDefaults is not Sendable, and the production closure
        // reaches for `.standard` from inside itself for the same reason.
        let suiteName = "update-consent-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        let report = HealthReport.standard(
            updateChecksEnabled: { UpdateCheckConsent.isEnabled(in: UserDefaults(suiteName: suiteName)!) })

        func engineReasons() async -> [String] {
            await report.run().filter { $0.id.hasPrefix("engine.") }.compactMap {
                if case .unknown(let reason) = $0.status { return reason }
                return nil
            }
        }

        let whileOff = await engineReasons()
        #expect(whileOff.allSatisfy { $0.lowercased().contains("turned off") })
        #expect(whileOff.count == 2)

        UpdateCheckConsent.setEnabled(true, in: defaults)

        // The same report object, not a new one. With consent on it either
        // reaches GitHub (no unknown reason at all) or fails the lookup — but
        // it must never still be blaming the setting.
        let whileOn = await engineReasons()
        #expect(whileOn.allSatisfy { !$0.lowercased().contains("turned off") })
    }
}
