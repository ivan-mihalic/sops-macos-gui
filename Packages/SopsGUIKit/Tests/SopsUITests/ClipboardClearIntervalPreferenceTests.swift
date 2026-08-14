import Foundation
import Testing
@testable import SopsUI

/// `ClipboardClearIntervalPreference` is the `UserDefaults`-backed policy
/// `ClipboardClearing.defaultInterval` reads on every copy — ticket #6, claim
/// 4: `defaultInterval` used to be a hardcoded `static let .seconds(30)` with
/// nothing anywhere reading `UserDefaults`, despite PROPOSAL.md §4 listing a
/// clipboard-clear-delay control as planned. Same shape as
/// `SessionTTLPreference` (`SopsHealth/HealthReport+Standard.swift`, ticket
/// #4): a dedicated `UserDefaults(suiteName:)` per test, never `.standard`,
/// because Swift Testing runs this suite in parallel and `.standard` is one
/// process-wide dictionary every test would race every other test to write.
@Suite("ClipboardClearIntervalPreference")
struct ClipboardClearIntervalPreferenceTests {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "ClipboardClearIntervalPreferenceTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("an untouched default reports the shipped default, not zero")
    func untouchedDefaultsReportTheShippedDefault() {
        let defaults = freshDefaults()
        #expect(ClipboardClearIntervalPreference.seconds(in: defaults)
                == ClipboardClearIntervalPreference.defaultSeconds)
    }

    @Test("the shipped default is still PROPOSAL.md's ~30 seconds")
    func shippedDefaultIsThirtySeconds() {
        #expect(ClipboardClearIntervalPreference.defaultSeconds == 30)
    }

    @Test("a value that was set is read back exactly")
    func setValueRoundTrips() {
        let defaults = freshDefaults()
        ClipboardClearIntervalPreference.setSeconds(90, in: defaults)
        #expect(ClipboardClearIntervalPreference.seconds(in: defaults) == 90)
    }

    /// An interval near zero clears a copied secret before any realistic
    /// paste can finish — not a short window, a copy button that silently
    /// does nothing. An unbounded one defeats the entire point of the
    /// feature: the secret sits on the pasteboard for an ordinary work
    /// session. Clamped, not rejected, for the same reason
    /// `SessionTTLPreference` clamps: a stray `UserDefaults` write must still
    /// produce something this type can use.
    @Test("a value outside the allowed range is clamped, not stored as-is", arguments: [
        (0, ClipboardClearIntervalPreference.allowedRange.lowerBound),
        (-5, ClipboardClearIntervalPreference.allowedRange.lowerBound),
        (10_000, ClipboardClearIntervalPreference.allowedRange.upperBound),
    ])
    func outOfRangeValuesAreClamped(input: Int, expected: Int) {
        let defaults = freshDefaults()
        ClipboardClearIntervalPreference.setSeconds(input, in: defaults)
        #expect(ClipboardClearIntervalPreference.seconds(in: defaults) == expected)
    }

    @Test("interval(in:) converts the stored seconds to a Duration")
    func intervalConvertsSecondsToDuration() {
        let defaults = freshDefaults()
        ClipboardClearIntervalPreference.setSeconds(45, in: defaults)
        #expect(ClipboardClearIntervalPreference.interval(in: defaults) == .seconds(45))
    }
}
