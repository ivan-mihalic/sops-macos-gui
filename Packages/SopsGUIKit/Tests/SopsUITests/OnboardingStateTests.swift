import Foundation
import Testing
@testable import SopsUI

@Suite("OnboardingState")
@MainActor
struct OnboardingStateTests {

    private func makeState() -> OnboardingState {
        // A private suite name keeps the test off the real user defaults.
        OnboardingState(defaults: UserDefaults(suiteName: "onboarding-" + UUID().uuidString)!)
    }

    @Test("starts at the welcome step")
    func startsAtWelcome() {
        #expect(makeState().step == .welcome)
    }

    @Test("walks forward through every step and stops at the summary")
    func walksForward() {
        let state = makeState()
        let expected: [OnboardingStep] = [.tools, .engine, .security, .projects, .summary]
        for step in expected {
            state.advance()
            #expect(state.step == step)
        }
        state.advance()
        #expect(state.step == .summary, "the summary is the last step")
    }

    @Test("walks back and stops at the welcome step")
    func walksBack() {
        let state = makeState()
        state.advance()
        state.back()
        #expect(state.step == .welcome)
        state.back()
        #expect(state.step == .welcome)
    }

    @Test("is not marked complete until it is finished")
    func completionIsExplicit() {
        let state = makeState()
        #expect(state.hasCompletedOnboarding == false)
        state.finish()
        #expect(state.hasCompletedOnboarding == true)
    }

    @Test("completion survives a restart")
    func completionPersists() {
        let suite = "onboarding-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        OnboardingState(defaults: defaults).finish()
        #expect(OnboardingState(defaults: defaults).hasCompletedOnboarding == true)
    }

    // PROPOSAL.md §6: re-runnable. Reopening it must not lose the completion flag.
    @Test("re-running the wizard after completion restarts at welcome without un-completing it")
    func rerunIsNonDestructive() {
        let state = makeState()
        state.finish()
        state.restart()
        #expect(state.step == .welcome)
        #expect(state.hasCompletedOnboarding == true)
    }
}
