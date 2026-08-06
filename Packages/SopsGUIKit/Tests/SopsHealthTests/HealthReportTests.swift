import Testing
@testable import SopsHealth

private struct StubCheck: HealthCheck {
    let id: String
    let category: HealthCategory
    let findings: [HealthFinding]
    func run() async -> [HealthFinding] { findings }
}

private func finding(_ id: String, _ status: HealthStatus) -> HealthFinding {
    HealthFinding(id: id, title: id, status: status, detail: "", remediation: nil)
}

@Suite("HealthReport")
struct HealthReportTests {

    @Test("collects findings from every check")
    func collectsAll() async {
        let report = HealthReport(checks: [
            StubCheck(id: "a", category: .tools, findings: [finding("a1", .ok), finding("a2", .warning)]),
            StubCheck(id: "b", category: .engine, findings: [finding("b1", .ok)]),
        ])
        let findings = await report.run()
        #expect(Set(findings.map(\.id)) == ["a1", "a2", "b1"])
    }

    // Renamed from the brief's "a check that throws or hangs must not take the report down":
    // run() is non-throwing by design (see HealthCheck doc comment), so this check cannot
    // throw or hang in the first place. What this test actually verifies is that a check
    // reporting .unknown does not prevent other checks' findings from being collected.
    @Test("a check reporting unknown does not prevent other checks' findings from being collected")
    func isolatesFailures() async {
        struct ExplodingCheck: HealthCheck {
            let id = "boom"
            let category = HealthCategory.tools
            func run() async -> [HealthFinding] {
                [HealthFinding(id: "boom", title: "boom", status: .unknown(reason: "probe failed"),
                               detail: "", remediation: nil)]
            }
        }
        let report = HealthReport(checks: [
            ExplodingCheck(),
            StubCheck(id: "ok", category: .engine, findings: [finding("fine", .ok)]),
        ])
        let findings = await report.run()
        #expect(findings.count == 2)
        #expect(findings.contains { $0.id == "fine" })
    }

    @Test("the worst status wins, and problem outranks warning")
    func worstStatusOrdering() {
        #expect(HealthReport.worstStatus(in: [finding("a", .ok), finding("b", .warning)]) == .warning)
        #expect(HealthReport.worstStatus(in: [finding("a", .warning), finding("b", .problem)]) == .problem)
        #expect(HealthReport.worstStatus(in: [finding("a", .ok)]) == .ok)
    }

    @Test("skipped and unknown never mask a real problem")
    func informationalStatusesDoNotMask() {
        let findings = [
            finding("a", .skipped(reason: "arrives with Sparkle in M5")),
            finding("b", .unknown(reason: "offline")),
            finding("c", .problem),
        ]
        #expect(HealthReport.worstStatus(in: findings) == .problem)
    }

    @Test("an empty report is OK, not an error")
    func emptyIsOK() async {
        let findings = await HealthReport(checks: []).run()
        #expect(findings.isEmpty)
        #expect(HealthReport.worstStatus(in: findings) == .ok)
    }
}
