import Foundation
import Testing
@testable import SopsHealth

/// `SessionTTLPreference` is the UserDefaults-backed policy `SessionKeyStore`
/// reads when it starts a new session, and the same value `SecurityPostureCheck`
/// reports on — one number, one place, the same shape as `UpdateCheckConsent`
/// right above it in `HealthReport+Standard.swift`.
///
/// A dedicated `UserDefaults(suiteName:)` per test, never `.standard`: Swift
/// Testing runs this suite's tests in parallel, and `.standard` is one process
/// -wide dictionary every test would be racing every other test to write.
@Suite("SessionTTLPreference")
struct SessionTTLPreferenceTests {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "SessionTTLPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("an untouched default reports the shipped default, not zero")
    func untouchedDefaultsReportTheShippedDefault() {
        let defaults = freshDefaults()
        #expect(SessionTTLPreference.minutes(in: defaults) == SessionTTLPreference.defaultMinutes)
    }

    @Test("a value that was set is read back exactly")
    func setValueRoundTrips() {
        let defaults = freshDefaults()
        SessionTTLPreference.setMinutes(30, in: defaults)
        #expect(SessionTTLPreference.minutes(in: defaults) == 30)
    }

    /// A TTL of zero would expire the key before any use of it could
    /// complete, and an unbounded one is "no TTL" wearing a costume — the
    /// exact defect this ticket exists to close. Clamped, not rejected: a
    /// stray `UserDefaults` write (a future version's smaller range, a
    /// hand-edited plist) must still produce something usable rather than a
    /// state this store cannot start a session in.
    @Test("a value outside the allowed range is clamped, not stored as-is", arguments: [
        (0, SessionTTLPreference.allowedRange.lowerBound),
        (-5, SessionTTLPreference.allowedRange.lowerBound),
        (10_000, SessionTTLPreference.allowedRange.upperBound),
    ])
    func outOfRangeValuesAreClamped(input: Int, expected: Int) {
        let defaults = freshDefaults()
        SessionTTLPreference.setMinutes(input, in: defaults)
        #expect(SessionTTLPreference.minutes(in: defaults) == expected)
    }
}
