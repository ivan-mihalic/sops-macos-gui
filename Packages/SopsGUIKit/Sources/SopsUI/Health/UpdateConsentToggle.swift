import SopsHealth
import SwiftUI

/// The one piece of user consent this app has: whether it may ask GitHub for
/// the latest sops and age releases (PROPOSAL §6 B gates the lookup behind it,
/// and Sparkle's own automatic check follows the same flag).
///
/// It lived in a Settings tab of its own until 2026-08-15. It sits in About
/// now, next to Check for Updates and the releases link — the three things a
/// user goes looking for at the same moment. A whole tab for a single switch
/// also made Settings look like it had more to configure than it does.
///
/// The toggle writes straight to `UserDefaults` through `UpdateCheckConsent`,
/// and the health report reads it live on every run, so flipping it and
/// re-running the report changes the result immediately.
public struct UpdateConsentToggle: View {
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
        VStack(alignment: .leading, spacing: 8) {
            Toggle(LocalizedKey.settingsUpdatesToggle.text, isOn: $isEnabled)
                .onChange(of: isEnabled) { _, newValue in
                    UpdateCheckConsent.setEnabled(newValue, in: defaults)
                    onConsentChanged()
                }
            // Kept with the control rather than dropped in the move: the
            // toggle decides whether this app talks to the network at all,
            // and a switch that says only "check automatically" does not tell
            // the user that is what they are agreeing to.
            Text(.settingsUpdatesExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 320, alignment: .leading)
    }
}
