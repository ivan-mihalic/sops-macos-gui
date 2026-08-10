import SopsProjects
import SwiftUI

/// The settings panes, as content rather than as a window.
///
/// PROPOSAL §4 pins Settings to the bottom of the sidebar, and a sidebar row
/// that opens a separate window is a different interaction from every other
/// row in that list. This is the same three tabs the `Settings` scene shows —
/// one view, used in both places, so ⌘, and the sidebar row can never drift
/// into showing different things.
public struct SettingsPaneView: View {
    private let health: HealthViewModel
    private let keyStore: SessionKeyStore
    private let onUpdateConsentChanged: @MainActor () -> Void

    public init(health: HealthViewModel,
                keyStore: SessionKeyStore,
                onUpdateConsentChanged: @escaping @MainActor () -> Void = {}) {
        self.health = health
        self.keyStore = keyStore
        self.onUpdateConsentChanged = onUpdateConsentChanged
    }

    public var body: some View {
        TabView {
            HealthPanel(model: health)
                .tabItem { Label(.settingsTabHealth, systemImage: "stethoscope") }
            KeyImportView(store: keyStore)
                .tabItem { Label(.settingsTabKey, systemImage: "key") }
            UpdateSettingsPanel(onConsentChanged: onUpdateConsentChanged)
                .tabItem { Label(.settingsTabUpdates, systemImage: "arrow.down.circle") }
        }
        .padding(.top, 8)
    }
}
