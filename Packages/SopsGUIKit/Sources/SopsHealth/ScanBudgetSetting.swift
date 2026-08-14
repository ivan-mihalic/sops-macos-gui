import Foundation

/// The user-editable override for `ProjectScanner.maxScannedFiles`.
///
/// ## Why this exists (ticket #25 claim 1)
///
/// `maxScannedFiles` was a hardcoded `20_000` with no override anywhere in
/// the app — `scanBudget`/`ScanBudget`/`scanCap` did not exist. A monorepo
/// past that count got every project finding permanently demoted to
/// `.unknown` (`ScanLimitation.budgetExhausted.blocksAffirmativeVerdict` is
/// `true`) with nothing the user could do about it: the disclosure named
/// the number in prose (`ProjectScopeDisclosure`) but named nothing the user
/// could press.
///
/// Follows the same shape `UpdateCheckConsent` already established for a
/// persisted, user-editable setting in this package: a `defaultsKey`, and
/// `get`/`set` functions taking an injectable `UserDefaults` so nothing here
/// ever has to touch the real one to be tested.
///
/// `ProjectScanner.maxScannedFiles` stays exactly what it was: the
/// **default** value of this setting, and the floor `Self.minimum` is
/// checked against is a separate, much smaller number — the constant is not
/// a ceiling this type ever needs to know about, just what an unset default
/// resolves to.
public enum ScanBudgetSetting {
    public static let defaultsKey = "scanning.maxScannedFilesOverride"

    /// A budget this small would make every real project's scan look
    /// truncated — teaching the user the setting is broken rather than
    /// useful — so a value below it is clamped up rather than honoured as
    /// typed. Not zero: zero (and anything negative) means "unset", handled
    /// separately, so the two failure shapes stay distinguishable in the
    /// implementation even though a caller sees the same floor in both.
    public static let minimum = 100

    /// `UserDefaults.integer(forKey:)` returns `0` for a key that was never
    /// written, which is why `0` and "unset" collapse to the same case here
    /// — matching `UpdateCheckConsent`'s own note that `UserDefaults.bool`
    /// does the identical thing for its flag, and for the identical reason:
    /// there is no third value to distinguish them with.
    public static func current(in defaults: UserDefaults = .standard) -> Int {
        let stored = defaults.integer(forKey: defaultsKey)
        guard stored > 0 else { return ProjectScanner.maxScannedFiles }
        return max(stored, Self.minimum)
    }

    public static func set(_ value: Int, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: defaultsKey)
    }

    /// Clears the override, so `current(in:)` reads
    /// `ProjectScanner.maxScannedFiles` again — the same "unset" state a key
    /// that was never written has.
    public static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: defaultsKey)
    }
}
