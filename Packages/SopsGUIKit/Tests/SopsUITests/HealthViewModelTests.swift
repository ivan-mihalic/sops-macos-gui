import Testing
@testable import SopsHealth
@testable import SopsUI

private struct StubCheck: HealthCheck {
    let id: String
    let category: HealthCategory
    let findings: [HealthFinding]
    func run() async -> [HealthFinding] { findings }
}

private func finding(_ id: String, _ status: HealthStatus, _ category: HealthCategory) -> HealthFinding {
    HealthFinding(id: id, title: id, status: status, detail: "")
}

@Suite("HealthViewModel")
@MainActor
struct HealthViewModelTests {

    @Test("starts empty and populates after a refresh")
    func refreshPopulates() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [finding("tool.sops", .ok, .tools)])
        ]))
        #expect(model.findings.isEmpty)
        await model.refresh()
        #expect(model.findings.map(\.id) == ["tool.sops"])
    }

    @Test("the headline status is the worst finding")
    func headlineIsWorst() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [
                finding("a", .ok, .tools), finding("b", .problem, .tools), finding("c", .warning, .tools),
            ])
        ]))
        await model.refresh()
        #expect(model.headlineStatus == .problem)
    }

    @Test("findings are grouped by the category prefix of their id")
    func groupsByCategory() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [finding("tool.sops", .ok, .tools)]),
            StubCheck(id: "e", category: .engine, findings: [finding("engine.sops", .ok, .engine)]),
        ]))
        await model.refresh()
        #expect(model.findings(in: .tools).map(\.id) == ["tool.sops"])
        #expect(model.findings(in: .engine).map(\.id) == ["engine.sops"])
    }

    @Test("re-running replaces the previous results rather than appending")
    func refreshReplaces() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "t", category: .tools, findings: [finding("tool.sops", .ok, .tools)])
        ]))
        await model.refresh()
        await model.refresh()
        #expect(model.findings.count == 1)
    }

    @Test("isRunning is false once a refresh completes")
    func runningFlagResets() async {
        let model = HealthViewModel(report: HealthReport(checks: []))
        await model.refresh()
        #expect(model.isRunning == false)
    }
}
