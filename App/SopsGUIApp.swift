import SwiftUI
import SopsUI
import SopsHealth

@main
struct SopsGUIApp: App {
    var body: some Scene {
        WindowGroup {
            AppShell()
        }
        // ⌘, is wired automatically by the Settings scene (PROPOSAL.md §4).
        Settings {
            TabView {
                // TODO(Task 13): swap for HealthReport.standard() once the real
                // checks are wired together — this empty report is a placeholder.
                HealthPanel(model: HealthViewModel(report: HealthReport(checks: [])))
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
            }
            .frame(width: 620, height: 480)
        }
    }
}
