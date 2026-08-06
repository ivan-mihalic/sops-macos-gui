import Foundation

/// Runs a set of checks concurrently and aggregates their findings.
/// Knows nothing about any individual check.
public struct HealthReport: Sendable {
    private let checks: [any HealthCheck]

    public init(checks: [any HealthCheck]) {
        self.checks = checks
    }

    public func run() async -> [HealthFinding] {
        await withTaskGroup(of: [HealthFinding].self) { group in
            for check in checks {
                group.addTask { await check.run() }
            }
            var all: [HealthFinding] = []
            for await findings in group {
                all.append(contentsOf: findings)
            }
            return all.sorted { $0.id < $1.id }
        }
    }

    public static func worstStatus(in findings: [HealthFinding]) -> HealthStatus {
        findings.map(\.status).max { $0.severity < $1.severity } ?? .ok
    }
}
