import Foundation

public enum HealthCategory: String, CaseIterable, Sendable, Hashable {
    case tools, engine, security, projects
}

public enum HealthStatus: Equatable, Sendable, Hashable {
    case ok
    case warning
    case problem
    /// The check could not run because its subject does not exist yet.
    /// The reason is shown to the user verbatim — always say why.
    case skipped(reason: String)
    /// The check ran but could not reach a verdict (offline, no consent).
    case unknown(reason: String)

    /// Ordering used to pick the headline status. Informational statuses sit
    /// below `warning` so they can never hide a real finding.
    var severity: Int {
        switch self {
        case .ok: 0
        case .skipped: 1
        case .unknown: 2
        case .warning: 3
        case .problem: 4
        }
    }
}

/// What the user can do about a finding. The app only ever shows `command` for
/// the user to copy and run themselves — the app never executes it. Nothing in
/// this type is executed by the app; it never mutates the system.
public struct Remediation: Equatable, Sendable, Hashable {
    public let explanation: String
    public let command: String?
    public let documentationURL: URL?

    public init(explanation: String, command: String? = nil, documentationURL: URL? = nil) {
        self.explanation = explanation
        self.command = command
        self.documentationURL = documentationURL
    }
}

public struct HealthFinding: Identifiable, Equatable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let status: HealthStatus
    public let detail: String
    public let remediation: Remediation?

    public init(id: String, title: String, status: HealthStatus, detail: String,
                remediation: Remediation? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.detail = detail
        self.remediation = remediation
    }
}

/// One independently re-runnable diagnostic. Implementations must never mutate
/// the system and must never throw — an unrunnable probe is a `.unknown` finding.
public protocol HealthCheck: Sendable {
    var id: String { get }
    var category: HealthCategory { get }
    func run() async -> [HealthFinding]
}
