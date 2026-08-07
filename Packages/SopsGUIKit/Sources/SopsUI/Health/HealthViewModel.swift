import Foundation
import Observation
import SopsHealth

@MainActor
@Observable
public final class HealthViewModel {
    public private(set) var findings: [HealthFinding] = []
    public private(set) var isRunning = false

    private let report: HealthReport

    /// The currently-running refresh, if any. A caller that arrives while a
    /// refresh is already in flight awaits this same task instead of starting
    /// a second one — see `refresh()`.
    private var inFlightRefresh: Task<Void, Never>?

    public init(report: HealthReport) {
        self.report = report
    }

    public var headlineStatus: HealthStatus {
        HealthReport.worstStatus(in: findings)
    }

    private static func prefix(for category: HealthCategory) -> String {
        switch category {
        case .tools: "tool."
        case .engine: "engine."
        case .security: "security."
        case .projects: "project."
        }
    }

    /// Findings are keyed by an id whose prefix names the category, which keeps
    /// the grouping stable without the view knowing which check produced what.
    public func findings(in category: HealthCategory) -> [HealthFinding] {
        let prefix = Self.prefix(for: category)
        return findings.filter { $0.id.hasPrefix(prefix) }
    }

    /// Findings whose id prefix matches none of `HealthCategory`'s known
    /// prefixes. `HealthPanel` renders these in a fallback section: a naming
    /// mismatch between a check's id and its category must never make a
    /// finding — including a `.problem` that already drives `headlineStatus`
    /// — silently disappear from the UI.
    public var uncategorizedFindings: [HealthFinding] {
        findings.filter { finding in
            !HealthCategory.allCases.contains { finding.id.hasPrefix(Self.prefix(for: $0)) }
        }
    }

    /// Runs every check and replaces `findings` with the result.
    ///
    /// Concurrent callers share one in-flight run rather than each starting
    /// their own. Checks shell out to CLI tools and walk project trees, so two
    /// full scans running at once is wasteful — and, without this guard, a
    /// genuine race: whichever call's `findings` assignment happened to land
    /// last would win (last-completion-wins, not last-call-wins), and the
    /// first call's `isRunning = false` would fire while a second call was
    /// still running, making the spinner and the disabled re-run button lie.
    ///
    /// A caller that arrives mid-refresh awaits the same run and observes its
    /// result; it never starts a second one, and `isRunning` stays true until
    /// that shared run actually finishes.
    public func refresh() async {
        if let inFlightRefresh {
            await inFlightRefresh.value
            return
        }
        isRunning = true
        let task = Task {
            let results = await self.report.run()
            self.findings = results
            self.isRunning = false
            self.inFlightRefresh = nil
        }
        inFlightRefresh = task
        await task.value
    }
}
