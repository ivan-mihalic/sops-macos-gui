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

/// Blocks a check's `run()` until the test opens it, and counts how many
/// times `run()` actually executed — used to prove overlapping `refresh()`
/// calls share a single run rather than each triggering their own.
private actor Gate {
    private var isOpen = false
    private var openContinuation: CheckedContinuation<Void, Never>?
    private var hasArrived = false
    private var arrivedContinuation: CheckedContinuation<Void, Never>?
    private(set) var runCount = 0

    func waitUntilOpen() async {
        runCount += 1
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

private struct GatedCheck: HealthCheck {
    let id: String
    let category: HealthCategory
    let gate: Gate
    let findings: [HealthFinding]
    func run() async -> [HealthFinding] {
        await gate.waitUntilOpen()
        return findings
    }
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

    @Test("overlapping refreshes share one run: isRunning stays true until it finishes, and findings are deterministic")
    func concurrentRefreshesAreCoalesced() async {
        let gate = Gate()
        let model = HealthViewModel(report: HealthReport(checks: [
            GatedCheck(id: "t", category: .tools, gate: gate, findings: [finding("tool.sops", .ok, .tools)])
        ]))

        // Two callers race to refresh at once — e.g. a double-click on
        // "Re-run checks", or a click landing while the panel's initial
        // .task-triggered refresh is still in flight.
        async let first: Void = model.refresh()
        async let second: Void = model.refresh()

        // Wait for the underlying check to actually be reached (not merely
        // for the two async lets to be scheduled) before asserting mid-flight
        // state, then release it.
        await gate.waitUntilArrived()
        #expect(model.isRunning == true)

        await gate.open()
        _ = await (first, second)

        #expect(model.isRunning == false)
        #expect(model.findings.map(\.id) == ["tool.sops"])
        // The check itself only ever ran once: the second caller awaited the
        // first's in-flight run instead of starting a redundant one.
        #expect(await gate.runCount == 1)
    }

    @Test("a finding whose id matches no category prefix is reachable via uncategorizedFindings, not silently dropped")
    func uncategorizedFindingsSurfaceOrphans() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "m", category: .tools, findings: [finding("mystery.orphan", .problem, .tools)])
        ]))
        await model.refresh()
        #expect(model.uncategorizedFindings.map(\.id) == ["mystery.orphan"])
        // It still drives the headline even though no category prefix matches.
        #expect(model.headlineStatus == .problem)
        // And it is absent from every category bucket — proving it would
        // vanish from HealthPanel's per-category sections without the fallback.
        for category in HealthCategory.allCases {
            #expect(model.findings(in: category).isEmpty)
        }
    }

    @Test("every finding is reachable through exactly one category bucket or the uncategorized fallback")
    func everyFindingIsAccountedFor() async {
        let model = HealthViewModel(report: HealthReport(checks: [
            StubCheck(id: "m", category: .tools, findings: [
                finding("tool.sops", .ok, .tools),
                finding("engine.sops", .ok, .engine),
                finding("security.plaintext", .warning, .security),
                finding("project.demo", .ok, .projects),
                finding("mystery.orphan", .problem, .tools),
            ])
        ]))
        await model.refresh()

        // This is exactly what HealthPanel renders: one section per category
        // plus the uncategorized fallback section. If this union ever drops or
        // duplicates a finding relative to the flat `findings` array, the
        // panel would too.
        let rendered = HealthCategory.allCases.flatMap(model.findings(in:)) + model.uncategorizedFindings
        #expect(rendered.count == model.findings.count)
        #expect(Set(rendered.map(\.id)) == Set(model.findings.map(\.id)))
    }
}

/// A refresh must not answer with a report built before it was asked for.
@MainActor
@Suite("A joined refresh still reflects state as of the request")
struct HealthRefreshFreshnessTests {

    @Test("a refresh arriving mid-scan causes another run, not a stale answer")
    func midScanRefreshRerunsTheBuilder() async {
        var builderCalls = 0
        var liveInputs = ["p1"]
        let gate = AsyncGate()

        let model = HealthViewModel(reportBuilder: {
            builderCalls += 1
            let snapshot = liveInputs
            return HealthReport(checks: [SnapshotCheck(ids: snapshot, gate: gate)])
        })

        // First refresh starts and blocks inside the check.
        async let first: Void = model.refresh()
        await gate.waitUntilEntered()

        // The user changes the world, then explicitly asks for a check.
        liveInputs = ["p1", "p2"]
        async let second: Void = model.refresh()

        await gate.release()
        _ = await (first, second)

        #expect(
            builderCalls == 2,
            "the second request was answered by the run already in flight, so the report describes inputs captured before the user asked")
        #expect(model.findings.count == 2, "the settled report is the stale one")
        #expect(!model.isRunning)
    }
}

/// A check that parks until released, so a second `refresh()` can arrive
/// while the first is genuinely mid-flight.
private actor AsyncGate {
    private var entered = false
    private var released = false

    func markEntered() { entered = true }
    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }
    func release() { released = true }
    func waitForRelease() async {
        while !released { await Task.yield() }
    }
}

private struct SnapshotCheck: HealthCheck {
    let ids: [String]
    let gate: AsyncGate

    var id: String { "snapshot" }
    var category: HealthCategory { .projects }

    func run() async -> [HealthFinding] {
        await gate.markEntered()
        await gate.waitForRelease()
        return ids.map {
            HealthFinding(id: "project.\($0)", title: $0, status: .ok, detail: "")
        }
    }
}
