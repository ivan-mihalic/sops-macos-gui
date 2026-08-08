import SwiftUI
import SopsUI
import SopsHealth
import SopsProjects

@main
struct SopsGUIApp: App {
    // One ProjectStore, shared by the sidebar and the health check, backed
    // by the app's real Application Support location. The sidebar mutates it
    // (add/remove); the health report reads it fresh on every refresh — see
    // `_health`'s initializer below and `HealthViewModel.init(reportBuilder:)`.
    // Two separate instances would each load the same file at launch and
    // *look* consistent then, but the sidebar's edits would never reach the
    // health check without a relaunch — the exact staleness bug
    // `reportBuilder` exists to avoid.
    private let projectStore = ProjectStore(fileURL: ProjectStore.defaultFileURL)
    @State private var projects: ProjectSidebarModel
    // Rebuilt from scratch on every refresh rather than captured once at
    // launch, so a project added through the sidebar mid-session is seen the
    // next time the report runs, not only after relaunching the app. Also
    // read live from UserDefaults on every run: Settings › Updates writes the
    // same key, and a captured Bool would ignore the toggle for the rest of
    // the session.
    @State private var health: HealthViewModel
    @State private var onboarding = OnboardingState()
    @State private var isShowingOnboarding = false

    init() {
        let store = projectStore
        _projects = State(initialValue: ProjectSidebarModel(store: store))
        _health = State(initialValue: HealthViewModel(reportBuilder: {
            .standard(updateChecksEnabled: { UpdateCheckConsent.isEnabled() }, projects: store.healthSource)
        }))
    }

    var body: some Scene {
        WindowGroup {
            AppShell(projects: projects)
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
