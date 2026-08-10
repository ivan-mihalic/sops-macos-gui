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
/// What one of the wizard's four category steps should show, computed
/// independently of SwiftUI so the decision itself can be tested.
///
/// The summary step was gated against a mid-scan false all-clear in Task 14;
/// these four steps were not. They rendered a bare `List` of whatever
/// `findings(in:)` returned, which during the ~0.4s scan is an empty array —
/// so a user clicking Continue faster than the scan settles saw "Security"
/// with nothing under it. An empty list under a category heading reads as
/// "nothing to report here", which is the same implied all-clear, one layer
/// out, and reachable by key-repeat alone.
///
/// `.empty` exists separately from `.findings([])` for the same reason
/// `OnboardingSummaryState.nothingChecked` exists: after a completed run, a
/// category that genuinely produced nothing should say so rather than leave
/// the user to interpret blank space.
public enum OnboardingCategoryState: Equatable, Sendable {
    /// The scan is still running, or has never completed a run.
    case checking
    /// A run completed and this category produced no findings.
    case empty
    case findings([HealthFinding])

    public static func compute(
        isRunning: Bool, hasCompletedRefresh: Bool, findingsInCategory: [HealthFinding]
    ) -> OnboardingCategoryState {
        guard !isRunning, hasCompletedRefresh else { return .checking }
        return findingsInCategory.isEmpty ? .empty : .findings(findingsInCategory)
    }
}

public enum OnboardingSummaryState: Equatable, Sendable {
    /// The scan is still running, or has never completed a run.
    /// Never assert a verdict in this state.
    case checking
    /// A run completed and produced no findings at all.
    ///
    /// Distinct from `.verdict(.ok)`, deliberately. `worstStatus(in: [])` is
    /// `.ok` — correct for that function, there being no worse status among
    /// zero findings — but rendering it as "Everything checks out." conflates
    /// *verified clean* with *nothing was configured to be checked*. Nothing
    /// in `HealthReport.standard` produces an empty report today, but
    /// `HealthReport(checks: [])` is a supported construction and this is the
    /// same false-all-clear shape as C2's vacuous "every file's key list
    /// matches", one layer out.
    case nothingChecked
    case verdict(HealthStatus)

    public static func compute(
        isRunning: Bool, hasCompletedRefresh: Bool, findings: [HealthFinding]
    ) -> OnboardingSummaryState {
        guard !isRunning, hasCompletedRefresh else { return .checking }
        guard !findings.isEmpty else { return .nothingChecked }
        return .verdict(HealthReport.worstStatus(in: findings))
    }

    /// The findings the summary must show underneath its verdict, worst first.
    ///
    /// The summary used to be a single sentence — "Some things need fixing." —
    /// over nothing. A user who read it could not tell *what* needed fixing
    /// without walking back through all four category steps and comparing
    /// them, which is what actually happened on the first signed build.
    ///
    /// This app's standing rule is that it never states something it has not
    /// shown the basis for. That rule was written about false all-clears, but
    /// it cuts the same way here: a bad verdict with the evidence hidden is
    /// still a claim the user cannot check.
    ///
    /// `.skipped` and `.unknown` are excluded on purpose. Both mean "no
    /// verdict was reached", and the wizard already gives them a neutral glyph
    /// and neutral wording for that reason; listing them under a heading that
    /// says something needs attention would contradict the line directly above
    /// them. Categorisation is not consulted either — a finding whose id
    /// matches no category prefix appears on none of the four steps, so the
    /// summary is the only place it can be seen at all.
    public static func evidence(in findings: [HealthFinding]) -> [HealthFinding] {
        func rank(_ status: HealthStatus) -> Int? {
            switch status {
            case .problem: 0
            case .warning: 1
            case .ok, .skipped, .unknown: nil
            }
        }
        // Sorting on (rank, original index) rather than rank alone: Swift's
        // sort is not stable, so without the tiebreak two findings of equal
        // severity could swap between runs and the list would be
        // non-deterministic for no reason a user could see.
        return findings.enumerated()
            .compactMap { index, finding in rank(finding.status).map { ($0, index, finding) } }
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map(\.2)
    }
}
