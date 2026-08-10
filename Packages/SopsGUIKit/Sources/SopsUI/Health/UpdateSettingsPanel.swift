import SwiftUI
import SopsHealth

/// The Settings tab that owns the one piece of user consent this app has:
/// whether it may ask GitHub for the latest sops and age releases
/// (PROPOSAL.md §4 lists an update toggle in Settings; §6 B gates the lookup
/// behind it).
///
/// Before this existed, `updateChecksEnabled` was hardcoded `false` in
/// `SopsGUIApp.swift` and nothing anywhere could change it, so §6 B never ran
/// for anybody and the engine-freshness finding permanently told the user the
/// app "can't tell" why — about its own constant.
///
/// The toggle writes straight to `UserDefaults` through `UpdateCheckConsent`,
/// and the health report reads it live on every run, so flipping it and
/// pressing Re-run in the Health tab changes the result immediately.
public struct UpdateSettingsPanel: View {
    private let defaults: UserDefaults
    /// Called after the flag is written, so whatever else reads it can pick
    /// the change up in *this* session. Sparkle needs that: its
    /// `automaticallyChecksForUpdates` is a property on a live object, not a
    /// closure re-read per run like the health report's, so without this the
    /// toggle would appear to work and take effect only after a relaunch.
    /// Defaults to doing nothing, which is what every test and snapshot wants.
    private let onConsentChanged: @MainActor () -> Void
    @State private var isEnabled: Bool

    public init(defaults: UserDefaults = .standard,
                onConsentChanged: @escaping @MainActor () -> Void = {}) {
        self.defaults = defaults
        self.onConsentChanged = onConsentChanged
        _isEnabled = State(initialValue: UpdateCheckConsent.isEnabled(in: defaults))
    }

    public var body: some View {
        Form {
            Section {
                Toggle(LocalizedKey.settingsUpdatesToggle.text, isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        UpdateCheckConsent.setEnabled(newValue, in: defaults)
                        onConsentChanged()
                    }
            } footer: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(.settingsUpdatesExplanation)
                    Text(.settingsUpdatesPrivacy)
                }
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}
