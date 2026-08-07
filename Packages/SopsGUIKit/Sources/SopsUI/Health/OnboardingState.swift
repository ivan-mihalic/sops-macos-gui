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
