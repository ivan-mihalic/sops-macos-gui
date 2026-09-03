import Foundation
import Observation
import SopsHealth

/// How long an imported age key survives, as something a control can bind to.
///
/// `SessionTTLPreference` shipped with the mechanism and no way to reach it:
/// `SessionKeyStore` expires the key against it and the health report reports
/// it, but the only way to change the value was editing `UserDefaults` by
/// hand. This is the missing half.
///
/// The clamp lives here, in the setter, rather than in the view. A control
/// that accepted 10 000 and let the store quietly reduce it would be lying
/// about what it took: the value the user sees after typing has to be the
/// value that is in force. `SessionTTLPreference.setMinutes` clamps too — this
/// reads back through it rather than clamping independently, so there is one
/// definition of the bounds and no way for the two to drift.
@MainActor
@Observable
public final class SessionTTLSetting {
    private let defaults: UserDefaults

    public var minutes: Int {
        didSet {
            SessionTTLPreference.setMinutes(minutes, in: defaults)
            // Read back rather than trusting the write: the preference is the
            // authority on its own range, and this is what makes an
            // out-of-range entry visibly become the value that is actually in
            // force instead of one the user believes they set.
            let stored = SessionTTLPreference.minutes(in: defaults)
            if stored != minutes { minutes = stored }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.minutes = SessionTTLPreference.minutes(in: defaults)
    }

    public var range: ClosedRange<Int> { SessionTTLPreference.allowedRange }

    /// The values the picker offers, plus — when the stored value is not one
    /// of them — the stored value itself.
    ///
    /// SOPS-51 replaced a stepper with a four-item menu. A `Picker` whose
    /// binding holds a value absent from its own options renders with nothing
    /// selected and, on the first interaction, silently replaces that value
    /// with whichever option the user lands on. Someone who had set 45 minutes
    /// under the old stepper would open Settings, see a blank control, and
    /// lose the setting by looking at it.
    ///
    /// So an off-list value is carried as a fifth entry rather than dropped.
    /// It disappears on its own the moment the user picks something else,
    /// which is the only point at which discarding it is something they did
    /// rather than something that happened to them.
    public var offeredMinutes: [Int] {
        let offered = SessionTTLPreference.offeredMinutes
        guard !offered.contains(minutes) else { return offered }
        return (offered + [minutes]).sorted()
    }
}
