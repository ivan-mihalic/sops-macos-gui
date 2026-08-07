import SwiftUI
import SopsUI
import SopsHealth

@main
struct SopsGUIApp: App {
    // Read live from UserDefaults on every run of the report, not captured
    // once at launch: Settings › Updates writes the same key, and a captured
    // Bool would ignore the toggle for the rest of the session.
    @State private var health = HealthViewModel(
        report: .standard(updateChecksEnabled: { UpdateCheckConsent.isEnabled() }))
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
                    // The menu item is named for an action, and PROPOSAL.md §6
                    // requires the report to re-run on demand — so it re-runs
                    // here rather than relying on the wizard's `.task`. That
                    // fires only when the sheet is *presented*; invoking this
                    // while the wizard is already open changes no sheet
                    // identity, so the user was walked back to Welcome and
                    // shown the previous scan's results under a flow that
                    // looks brand new. `refresh()` coalesces, so this is at
                    // worst a no-op when a scan is already in flight.
                    Task { await health.refresh() }
                }
            }
        }

        // ⌘, is wired automatically by the Settings scene (PROPOSAL.md §4).
        Settings {
            TabView {
                HealthPanel(model: health)
                    .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
                UpdateSettingsPanel()
                    .tabItem { Label(.settingsTabUpdates, systemImage: "arrow.down.circle") }
            }
            .frame(width: 620, height: 480)
        }
    }
}
