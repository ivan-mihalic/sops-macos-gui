import Foundation
import Observation
import SopsHealth

@MainActor
@Observable
public final class HealthViewModel {
    public private(set) var findings: [HealthFinding] = []
    public private(set) var isRunning = false

    private let report: HealthReport

    public init(report: HealthReport) {
        self.report = report
    }

    public var headlineStatus: HealthStatus {
        HealthReport.worstStatus(in: findings)
    }

    /// Findings are keyed by an id whose prefix names the category, which keeps
    /// the grouping stable without the view knowing which check produced what.
    public func findings(in category: HealthCategory) -> [HealthFinding] {
        let prefix = switch category {
        case .tools: "tool."
        case .engine: "engine."
        case .security: "security."
        case .projects: "project."
        }
        return findings.filter { $0.id.hasPrefix(prefix) }
    }

    public func refresh() async {
        isRunning = true
        defer { isRunning = false }
        findings = await report.run()
    }
}
