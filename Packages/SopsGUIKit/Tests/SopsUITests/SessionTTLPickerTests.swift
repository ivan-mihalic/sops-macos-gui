import Foundation
import Testing
@testable import SopsUI
import SopsHealth

/// SOPS-51. The Settings › Key duration control became a four-item menu.
@Suite("Session TTL picker")
@MainActor
struct SessionTTLPickerTests {

    private func setting(storedMinutes: Int?) -> SessionTTLSetting {
        let defaults = UserDefaults(suiteName: "ttl-picker-\(UUID().uuidString)")!
        if let storedMinutes {
            SessionTTLPreference.setMinutes(storedMinutes, in: defaults)
        }
        return SessionTTLSetting(defaults: defaults)
    }

    @Test("the menu offers the four durations that were asked for")
    func offersTheFourDurations() {
        #expect(SessionTTLPreference.offeredMinutes == [5, 15, 30, 60])
    }

    /// The default has to be a value the menu can show. A default off the
    /// list would open the picker with a fifth entry on every fresh install —
    /// the escape hatch for a legacy stored value, showing up as if it were
    /// the design.
    @Test("the default is one of the offered durations")
    func defaultIsOnTheMenu() {
        #expect(SessionTTLPreference.offeredMinutes.contains(SessionTTLPreference.defaultMinutes))
    }

    /// Ivan, 2026-09-03. Pinned as a decision rather than left to whatever the
    /// constant happens to say: the reason it moved from 15 is that SOPS-46
    /// made expiry cost a fingerprint instead of a re-paste, and a future
    /// change should have to argue with that rather than drift past it.
    @Test("a fresh install forgets the key after five minutes")
    func freshInstallDefaultsToFiveMinutes() {
        #expect(SessionTTLPreference.defaultMinutes == 5)
        #expect(setting(storedMinutes: nil).minutes == 5)
    }

    @Test("a stored value on the list is not duplicated")
    func onListValueIsNotDuplicated() {
        #expect(setting(storedMinutes: 30).offeredMinutes == [5, 15, 30, 60])
    }

    /// The defect a plain four-item `Picker` would have shipped with. SwiftUI
    /// renders a selection absent from its options as *nothing selected*, and
    /// replaces it the moment the user touches the control — so someone who
    /// set 45 minutes with the old stepper would open Settings, see a blank
    /// control, and lose the setting by looking at it.
    @Test("a stored value off the list is carried, not dropped")
    func offListValueSurvives() {
        let ttl = setting(storedMinutes: 45)

        #expect(ttl.minutes == 45)
        #expect(ttl.offeredMinutes == [5, 15, 30, 45, 60])
    }

    @Test("an off-list value disappears once the user picks something else")
    func offListValueGoesOnceReplaced() {
        let ttl = setting(storedMinutes: 45)

        ttl.minutes = 15

        #expect(ttl.offeredMinutes == [5, 15, 30, 60])
    }

    /// `allowedRange` must stay wider than the menu. Narrowing the clamp to
    /// the four offered values would silently rewrite a stored 45 on the next
    /// read — destroying it in the one place that is supposed to preserve it.
    @Test("the honoured range stays wider than the menu")
    func rangeStaysWide() {
        #expect(SessionTTLPreference.allowedRange.contains(45))
        #expect(SessionTTLPreference.allowedRange.lowerBound < 5)
        #expect(SessionTTLPreference.allowedRange.upperBound > 60)
    }

    // MARK: - Labels

    @Test("an hour reads as an hour, not as sixty minutes")
    func hourReadsAsAnHour() {
        let label = KeyImportView.durationLabel(forMinutes: 60)

        #expect(label.contains("hour"))
        #expect(label.contains("60") == false)
    }

    @Test("the sub-hour durations read as minutes")
    func minutesReadAsMinutes() {
        for minutes in [5, 15, 30] {
            let label = KeyImportView.durationLabel(forMinutes: minutes)
            #expect(label.contains("\(minutes)"))
            #expect(label.contains("minute"))
        }
    }

    /// A value that is not a whole number of hours stays in minutes: "1.5
    /// hours" would claim a precision this setting does not have.
    @Test("a partial hour stays in minutes")
    func partialHourStaysInMinutes() {
        let label = KeyImportView.durationLabel(forMinutes: 90)

        #expect(label.contains("90"))
        #expect(label.contains("minute"))
    }
}
