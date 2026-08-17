import Foundation
import Testing
@testable import SopsHealth
@testable import SopsUI

/// Settings has to be able to change how long an imported key lives.
///
/// The mechanism shipped without it: `SessionKeyStore` expires the key on a
/// deadline read from `SessionTTLPreference`, the health report reports the
/// value, and nothing anywhere could set it — the only way was editing
/// `UserDefaults` by hand. `PROPOSAL §4` lists a session-TTL control as
/// something Settings should have.
///
/// Two earlier passes left it out on the grounds that new UI strings are
/// expensive here because `LocalizationTests` is strict. That turned out to be
/// a misreading of what the rule forbids — four specific fragments in catalog
/// strings, not paths or new strings in general — so the reason for deferring
/// it is gone.
///
/// The control lives beside the key it governs, in Settings › Key. Anywhere
/// else and a user changing how long their key survives would be doing it on
/// a screen that is not about their key.
@Suite("Session TTL is settable")
@MainActor
struct SessionTTLControlTests {

    private func isolatedDefaults(_ label: String) -> UserDefaults {
        let suite = "ttl-control-\(label)-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("the control writes the chosen value through to the preference")
    func writesThrough() {
        let defaults = isolatedDefaults("write")
        let model = SessionTTLSetting(defaults: defaults)

        model.minutes = 45

        #expect(SessionTTLPreference.minutes(in: defaults) == 45)
    }

    @Test("it starts from whatever is stored, not from a hardcoded default")
    func readsStoredValue() {
        let defaults = isolatedDefaults("read")
        SessionTTLPreference.setMinutes(90, in: defaults)

        #expect(SessionTTLSetting(defaults: defaults).minutes == 90)
    }

    /// The bounds are the preference's, not the control's own idea of them —
    /// a control that let a user ask for something the store then silently
    /// clamped would be lying about what it accepted.
    @Test("a value outside the allowed range comes back clamped, not stored raw")
    func clampsOutOfRange() {
        let defaults = isolatedDefaults("clamp")
        let model = SessionTTLSetting(defaults: defaults)

        model.minutes = 10_000

        #expect(model.minutes == SessionTTLPreference.allowedRange.upperBound)
        #expect(SessionTTLPreference.minutes(in: defaults) == SessionTTLPreference.allowedRange.upperBound)
    }

    @Test("the pane explains what the value actually does")
    func paneExplainsTheConsequence() {
        let text = LocalizedKey.keyTTLFooter.text.lowercased()
        #expect(text.contains("sleep"), Comment(rawValue: """
            The TTL footer does not mention that the key is also forgotten when the Mac \
            sleeps, which is the half a user cannot infer from a number of minutes. \
            Text was: \(LocalizedKey.keyTTLFooter.text)
            """))
    }
}
