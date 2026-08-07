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
    @State private var isEnabled: Bool

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        _isEnabled = State(initialValue: UpdateCheckConsent.isEnabled(in: defaults))
    }

    public var body: some View {
        Form {
            Section {
                Toggle(LocalizedKey.settingsUpdatesToggle.text, isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, newValue in
                        UpdateCheckConsent.setEnabled(newValue, in: defaults)
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
