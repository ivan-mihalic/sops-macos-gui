import Foundation
import Testing
@testable import SopsHealth

/// Ticket #25 claim 1. `ProjectScanner.maxScannedFiles` was hardcoded with
/// no override anywhere — a monorepo past 20,000 files got a permanently
/// `.unknown` health report and no way to change that. `ScanBudgetSetting`
/// is the persisted override, following the same shape
/// `UpdateCheckConsent` already established for a user-editable
/// `UserDefaults`-backed setting in this package: a `defaultsKey`, and
/// `get`/`set` functions that take an injectable `UserDefaults` so a test
/// never has to touch the real one.
@Suite("ScanBudgetSetting")
struct ScanBudgetSettingTests {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "scan-budget-setting-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }

    @Test("an untouched default reads as ProjectScanner.maxScannedFiles")
    func defaultsToTheHardConstant() {
        #expect(ScanBudgetSetting.current(in: freshDefaults()) == ProjectScanner.maxScannedFiles)
    }

    @Test("a set value round-trips")
    func setValueRoundTrips() {
        let defaults = freshDefaults()
        ScanBudgetSetting.set(50_000, in: defaults)
        #expect(ScanBudgetSetting.current(in: defaults) == 50_000)
    }

    @Test("zero is treated as unset, not as a scanner that visits nothing")
    func zeroFallsBackToTheDefault() {
        let defaults = freshDefaults()
        ScanBudgetSetting.set(0, in: defaults)
        #expect(ScanBudgetSetting.current(in: defaults) == ProjectScanner.maxScannedFiles)
    }

    @Test("a negative value is rejected the same way zero is")
    func negativeFallsBackToTheDefault() {
        let defaults = freshDefaults()
        ScanBudgetSetting.set(-10, in: defaults)
        #expect(ScanBudgetSetting.current(in: defaults) == ProjectScanner.maxScannedFiles)
    }

    /// A budget of, say, 3 would make every real project's scan look
    /// truncated and teach the user the setting is broken rather than
    /// useful — the floor exists for the same reason a lower bound protects
    /// any other user-editable number that feeds a loop.
    @Test("a value under the floor is clamped up to it, not accepted as typed")
    func tooSmallIsClampedToTheFloor() {
        let defaults = freshDefaults()
        ScanBudgetSetting.set(10, in: defaults)
        #expect(ScanBudgetSetting.current(in: defaults) == ScanBudgetSetting.minimum)
    }
}
