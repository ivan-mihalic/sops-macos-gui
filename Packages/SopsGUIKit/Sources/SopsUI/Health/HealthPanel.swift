import SwiftUI
import SopsHealth

/// The re-runnable report. Used as a Settings tab and as the final wizard step.
public struct HealthPanel: View {
    @Bindable private var model: HealthViewModel

    /// One per panel, shared by every row in it, so at most one Copy button
    /// can read "Copied" at a time — the pasteboard holds one thing. See
    /// `CopyFeedback`.
    @State private var copyFeedback = CopyFeedback()

    public init(model: HealthViewModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            List {
                // A completed run with no findings at all renders as an empty
                // List, which reads as "nothing to report" — the same implied
                // all-clear the wizard's summary was fixed for. Say it
                // instead. Unreachable through `HealthReport.standard` today,
                // but `HealthReport(checks: [])` is a supported construction.
                if model.hasCompletedRefresh && !model.isRunning && model.findings.isEmpty {
                    Text(.healthNothingChecked).foregroundStyle(.secondary)
                }

                ForEach(HealthCategory.allCases, id: \.self) { category in
                    let findings = model.findings(in: category)
                    if !findings.isEmpty {
                        Section(title(for: category)) {
                            ForEach(findings) { HealthFindingRow(finding: $0, copyFeedback: copyFeedback) }
                        }
                    }
                }

                // A finding whose id prefix matches no known category must still
                // render somewhere — never silently dropped from the panel.
                let orphaned = model.uncategorizedFindings
                if !orphaned.isEmpty {
                    Section(LocalizedKey.healthCategoryOther.text) {
                        ForEach(orphaned) { HealthFindingRow(finding: $0, copyFeedback: copyFeedback) }
                    }
                }
            }
            .scrollOverflowFade()

            Divider()

            HStack {
                if model.isRunning {
                    ProgressView().controlSize(.small)
                    Text(.healthChecking).foregroundStyle(.secondary)
                } else if let lastRefreshedAt = model.lastRefreshedAt {
                    // Ticket #22: the only signal on screen that these
                    // findings might be stale. `.relative` keeps updating on
                    // its own ("2 minutes ago" → "an hour ago") without this
                    // view needing a timer.
                    HStack(spacing: 4) {
                        Text(.healthLastChecked)
                        Text(lastRefreshedAt, style: .relative)
                    }
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button(LocalizedKey.actionRerunChecks.text) {
                    Task { await model.refresh() }
                }
                .disabled(model.isRunning)
            }
            .padding(12)
        }
        // Unconditional, like `OnboardingWizard`'s. The `if
        // model.findings.isEmpty` guard this replaces made the panel show the
        // previous run's verdicts as if they were current: `HealthViewModel` is
        // one shared instance for the whole app, and the `security.keystore`
        // check reads the same `SessionKeyStore` the neighbouring Settings ›
        // Key tab writes to. Open Health, import a key in Key, come back — and
        // Health still says "No age key is configured in this app, so this app
        // cannot decrypt anything", in the present tense, about a key that is
        // configured. Findings carry no timestamp, so nothing on screen hints
        // that they are old.
        //
        // A re-run costs what a re-run costs; `model.refresh()` already
        // coalesces a request arriving mid-scan (see `startRefresh`), so
        // arriving here while one is in flight rejoins it rather than starting
        // a second.
        .task { await model.refresh() }
    }

    private func title(for category: HealthCategory) -> String {
        switch category {
        case .tools: LocalizedKey.healthCategoryTools.text
        case .engine: LocalizedKey.healthCategoryEngine.text
        case .security: LocalizedKey.healthCategorySecurity.text
        case .projects: LocalizedKey.healthCategoryProjects.text
        }
    }
}
