import SopsProjects
import SwiftUI

/// The settings panes, as content rather than as a window.
///
/// PROPOSAL §4 pins Settings to the bottom of the sidebar. Since 2026-08-15
/// there is no separate Settings *scene* at all — ⌘, selects this row rather
/// than opening a window of its own, so there is only one place this content
/// can be, and nothing to keep in sync.
///
/// The Updates tab is gone from here: its single toggle moved to About, next
/// to Check for Updates and the releases link. See `UpdateConsentToggle`.
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
            ScanSettingsPanel()
                .tabItem { Label(.settingsTabScanning, systemImage: "magnifyingglass") }
        }
        .padding(.top, 8)
    }
}
