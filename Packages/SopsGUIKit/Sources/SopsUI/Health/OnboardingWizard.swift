import SwiftUI
import SopsHealth

public struct OnboardingWizard: View {
    @Bindable private var health: HealthViewModel
    @Bindable private var state: OnboardingState
    @Environment(\.dismiss) private var dismiss

    public init(health: HealthViewModel, state: OnboardingState) {
        self.health = health
        self.state = state
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2).bold()
            Text(subtitle).foregroundStyle(.secondary)

            Divider()

            Group {
                if let category = state.step.category {
                    List(health.findings(in: category)) { HealthFindingRow(finding: $0) }
                } else if state.step == .summary {
                    summary
                } else {
                    welcome
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack {
                Button(LocalizedKey.actionBack.text) { state.back() }
                    .disabled(state.step == .welcome)
                Spacer()
                if state.step == .summary {
                    Button(LocalizedKey.actionDone.text) {
                        state.finish()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(LocalizedKey.actionContinue.text) { state.advance() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .task { await health.refresh() }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(.onboardingWelcomeBody1)
            Text(.onboardingWelcomeBody2)
            Text(.onboardingWelcomeBody3)
                .foregroundStyle(.secondary)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch health.headlineStatus {
            case .ok:
                Label(.onboardingSummaryOK, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.title3)
            case .warning:
                Label(.onboardingSummaryWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.title3)
            case .unknown, .skipped:
                // Deliberately not grouped with `.warning`: nothing was found
                // "worth a look" here — the check just didn't reach a verdict
                // (no subject yet, offline, or a feature that hasn't shipped).
                // Claiming otherwise would tell the user to go looking for a
                // problem that isn't there. Neutral glyph and tint to match:
                // this is information, not something that needs attention.
                Label(.onboardingSummaryIncomplete, systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary).font(.title3)
            case .problem:
                Label(.onboardingSummaryProblem, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red).font(.title3)
            }
            Text(.onboardingSummaryFooter)
                .foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch state.step {
        case .welcome: LocalizedKey.onboardingWelcomeTitle.text
        case .tools: LocalizedKey.healthCategoryTools.text
        case .engine: LocalizedKey.healthCategoryEngine.text
        case .security: LocalizedKey.healthCategorySecurity.text
        case .projects: LocalizedKey.healthCategoryProjects.text
        case .summary: LocalizedKey.onboardingSummaryTitle.text
        }
    }

    private var subtitle: String {
        switch state.step {
        case .welcome: LocalizedKey.onboardingWelcomeSubtitle.text
        case .tools: LocalizedKey.onboardingToolsSubtitle.text
        case .engine: LocalizedKey.onboardingEngineSubtitle.text
        case .security: LocalizedKey.onboardingSecuritySubtitle.text
        case .projects: LocalizedKey.onboardingProjectsSubtitle.text
        case .summary: LocalizedKey.onboardingSummarySubtitle.text
        }
    }
}
