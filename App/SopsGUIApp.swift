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
                HealthPanel(model: HealthViewModel(report: .standard(updateChecksEnabled: false)))
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
            }
            .frame(width: 620, height: 480)
        }
    }
}
