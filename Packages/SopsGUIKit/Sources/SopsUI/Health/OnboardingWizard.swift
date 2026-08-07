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
            // Gated through OnboardingSummaryState.compute rather than reading
            // health.headlineStatus directly: an empty findings array reads as
            // `.ok` to HealthReport.worstStatus(in:), so without this gate a
            // user who reaches this step before the scan settles would see an
            // all-clear the app never actually verified.
            switch OnboardingSummaryState.compute(isRunning: health.isRunning, findings: health.findings) {
            case .checking:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(.healthChecking)
                }
                .foregroundStyle(.secondary).font(.title3)
            case .verdict(.ok):
                Label(.onboardingSummaryOK, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.title3)
            case .verdict(.warning):
                Label(.onboardingSummaryWarning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.title3)
            case .verdict(.skipped):
                // Deliberately not grouped with `.warning`: the check's
                // subject doesn't exist yet (no projects added, a feature not
                // shipped) — there is nothing to look at. Neutral glyph and
                // tint: this is information, not something needing attention.
                Label(.onboardingSummarySkipped, systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary).font(.title3)
            case .verdict(.unknown):
                // Also deliberately not grouped with `.warning`, and not the
                // same wording as `.skipped`: this check genuinely ran, it
                // just couldn't reach a verdict (offline, checks disabled) —
                // "could not run" would misdescribe what actually happened.
                Label(.onboardingSummaryUnknown, systemImage: "info.circle.fill")
                    .foregroundStyle(.secondary).font(.title3)
            case .verdict(.problem):
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
