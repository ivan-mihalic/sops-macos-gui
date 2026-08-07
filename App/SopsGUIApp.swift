import SwiftUI
import SopsUI
import SopsHealth

@main
struct SopsGUIApp: App {
    @State private var health = HealthViewModel(report: .standard(updateChecksEnabled: false))
    @State private var onboarding = OnboardingState()
    @State private var isShowingOnboarding = false

    var body: some Scene {
        WindowGroup {
            AppShell()
                .sheet(isPresented: $isShowingOnboarding) {
                    OnboardingWizard(health: health, state: onboarding)
                }
                .onAppear {
                    isShowingOnboarding = !onboarding.hasCompletedOnboarding
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button(LocalizedKey.actionRunSetupCheck.text) {
                    onboarding.restart()
                    isShowingOnboarding = true
                }
            }
        }

        // ⌘, is wired automatically by the Settings scene (PROPOSAL.md §4).
        Settings {
            TabView {
                HealthPanel(model: health)
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
            }
            .frame(width: 620, height: 480)
        }
    }
}
