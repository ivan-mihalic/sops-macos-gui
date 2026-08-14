import Testing
@testable import SopsHealth

/// This suite exercises the tools/engine/security/projects checks, not the
/// key-store or app-update status — so it deliberately opts into the stub
/// providers `HealthReport.standard` no longer supplies by default (ticket
/// #15: a caller that wants them has to name them, which is exactly the
/// point).
private func standardReport(updateChecksEnabled: @escaping @Sendable () -> Bool) -> HealthReport {
    .standard(updateChecksEnabled: updateChecksEnabled,
              keyStore: UnshippedKeyStore(), appUpdates: UnshippedAppUpdates())
}

@Suite("standard report")
struct StandardReportTests {

    @Test("covers all four categories from PROPOSAL §6")
    func coversEveryCategory() async {
        let findings = await standardReport(updateChecksEnabled: { false }).run()
        let prefixes = Set(findings.map { $0.id.split(separator: ".").first.map(String.init) ?? "" })
        #expect(prefixes.isSuperset(of: ["tool", "engine", "security", "project"]))
    }

    /// Rewritten. The previous version of this test iterated the report and
    /// put its only expectation inside `if case .problem`, so on a machine
    /// that produces no problems — this one — it asserted nothing at all and
    /// passed vacuously. Deleting the whole network-consent gate left it
    /// green.
    ///
    /// What it should have been checking is the property in its own name: with
    /// consent off, the two engine findings must come back `.unknown` naming
    /// the consent setting, no network request may have been made, and no
    /// `.problem` anywhere may be blamed on the network.
    @Test("with update checks off, the engine findings say so and nothing blames the network")
    func worksOffline() async {
        let findings = await standardReport(updateChecksEnabled: { false }).run()

        let engine = findings.filter { $0.id.hasPrefix("engine.") }
        #expect(engine.count == 2, "expected one finding per embedded component, got \(engine.count)")
        for finding in engine {
            guard case .unknown(let reason) = finding.status else {
                Issue.record("\(finding.id) should be unknown with consent off, got \(finding.status)")
                continue
            }
            // The app knows why: its own setting. It must not hedge.
            #expect(reason.lowercased().contains("turned off"),
                    "\(finding.id) does not name the consent setting: \(reason)")
            #expect(!reason.lowercased().contains("can't tell"))
            #expect(finding.remediation?.explanation.lowercased().contains("settings") == true)
        }

        for finding in findings where finding.status == .problem {
            #expect(!finding.detail.lowercased().contains("github"),
                    "\(finding.id) blames the network for a problem: \(finding.detail)")
        }
    }

    /// The consent gate must be load-bearing in both directions, or "off" is
    /// indistinguishable from "the feature does not exist". This asserts the
    /// *reason text differs*, which is what a user actually reads, without
    /// requiring the network to be up: with consent on and no network, the
    /// reason names the failed lookup instead of the setting.
    @Test("turning consent on changes what the engine findings say about why")
    func consentIsLoadBearing() async {
        let off = await standardReport(updateChecksEnabled: { false }).run()
            .filter { $0.id.hasPrefix("engine.") }
        let on = await standardReport(updateChecksEnabled: { true }).run()
            .filter { $0.id.hasPrefix("engine.") }

        func reason(_ finding: HealthFinding) -> String? {
            if case .unknown(let reason) = finding.status { return reason }
            return nil
        }

        for finding in off {
            #expect(reason(finding)?.lowercased().contains("turned off") == true)
        }
        // With consent on this either reaches GitHub (a verdict, so no
        // "turned off" reason) or fails to (a reason naming the lookup).
        // Neither may claim the setting is off, because it is not.
        for finding in on {
            #expect(reason(finding)?.lowercased().contains("turned off") != true,
                    "\(finding.id) claims checks are off when they are on")
        }
    }

    @Test("every finding has a non-empty title and a stable id")
    func findingsAreWellFormed() async {
        let findings = await standardReport(updateChecksEnabled: { false }).run()
        #expect(!findings.isEmpty)
        #expect(Set(findings.map(\.id)).count == findings.count, "ids must be unique")
        for finding in findings {
            #expect(!finding.title.isEmpty)
            #expect(!finding.id.isEmpty)
        }
    }

    /// Every informational status must state why — PROPOSAL.md §6 Behaviour
    /// says so in as many words, and a reason-less `.skipped` is how a check
    /// that quietly did nothing looks identical to one that had nothing to do.
    @Test("every skipped or unknown finding carries a non-empty reason")
    func informationalStatusesAlwaysSayWhy() async {
        for finding in await standardReport(updateChecksEnabled: { false }).run() {
            switch finding.status {
            case .skipped(let reason), .unknown(let reason):
                #expect(!reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "\(finding.id) is \(finding.status) with no reason")
            case .ok, .warning, .problem:
                break
            }
        }
    }
}
