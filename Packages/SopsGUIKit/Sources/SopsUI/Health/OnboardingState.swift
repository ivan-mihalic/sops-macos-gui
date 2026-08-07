import Foundation
import Observation
import SopsHealth

public enum OnboardingStep: Int, CaseIterable, Comparable, Sendable {
    case welcome, tools, engine, security, projects, summary

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The health category this step reports on, if any.
    var category: HealthCategory? {
        switch self {
        case .tools: .tools
        case .engine: .engine
        case .security: .security
        case .projects: .projects
        case .welcome, .summary: nil
        }
    }
}

@MainActor
@Observable
public final class OnboardingState {
    private static let completionKey = "onboarding.completed"

    public private(set) var step: OnboardingStep = .welcome
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.completionKey)
    }

    public func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public func back() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    public func finish() {
        defaults.set(true, forKey: Self.completionKey)
    }

    /// Reopens the wizard. Completion is sticky — re-running is a diagnostic,
    /// not a reset.
    public func restart() {
        step = .welcome
    }
}

/// What the wizard's summary step should tell the user, computed independently
/// of SwiftUI so the decision itself can be tested directly.
///
/// The summary is the one surface in this app that asserts a verdict —
/// "Everything checks out" / "Some things need fixing" — rather than just
/// listing findings the way `HealthPanel` and the per-category steps do. That
/// makes it the one place a scan that hasn't finished, or has produced no
/// findings yet, must never be read as an answer.
///
/// `HealthReport.worstStatus(in:)` returns `.ok` for an empty array — correct
/// for that function (there is no worse status to report among zero
/// findings), but wrong to hand straight to the user as "everything checks
/// out": a user who clicks Continue through the wizard faster than the scan
/// completes (measured ~400ms/13 findings on a real machine — comfortably
/// reachable by key-repeat alone) would otherwise land on the summary while
/// no run has completed yet and read an all-clear the app never verified.
///
/// The "has it finished" signal is `HealthViewModel.hasCompletedRefresh`, not
/// `findings.isEmpty`. An empty finding list is a legitimate completed result
/// — `HealthReport(checks: [])` is a supported construction — so treating
/// emptiness as "still running" would get stuck on `.checking` forever for
/// any report that genuinely completes with zero findings. Nothing in
/// `HealthReport.standard` produces that today (every check it assembles
/// emits at least one finding), but `compute` is general-purpose API other
/// callers can reuse, and that shape of report is a legitimate future case
/// this must not silently mishandle.
public enum OnboardingSummaryState: Equatable, Sendable {
    /// The scan is still running, or has never completed a run.
    /// Never assert a verdict in this state.
    case checking
    case verdict(HealthStatus)

    public static func compute(
        isRunning: Bool, hasCompletedRefresh: Bool, findings: [HealthFinding]
    ) -> OnboardingSummaryState {
        guard !isRunning, hasCompletedRefresh else { return .checking }
        return .verdict(HealthReport.worstStatus(in: findings))
    }
}
