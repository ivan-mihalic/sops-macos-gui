import Testing
@testable import SopsHealth

/// Ticket #15. `UnshippedKeyStore` and `UnshippedAppUpdates` are the stand-in
/// providers a caller passes to `HealthReport.standard` when it genuinely
/// does not care about key-store or app-update status (most tests in this
/// suite). They used to be *default* parameter values, which meant a caller
/// that simply forgot to pass the real provider got one of these silently —
/// wrong data, no compile error, no test failure. `HealthReport.standard` no
/// longer defaults `keyStore` or `appUpdates` at all (see
/// `HealthReport+Standard.swift`), so every call site in this package now
/// names one of these two types explicitly — that omission is what makes the
/// accidental path impossible, not anything asserted here.
///
/// What *is* worth asserting here is the other half of the ticket: the stub
/// text must not claim a milestone that has already happened.
/// `UnshippedAppUpdates` used to say update checking "arrives with Sparkle in
/// M5" — stale since Sparkle shipped in 0.1.0 (see `App/SopsGUIApp.swift`,
/// `App/Updater.swift`). `UnshippedKeyStore`'s "arrives in M3" stays true and
/// is deliberately not touched here.
@Suite("Unshipped* stub providers")
struct UnshippedProvidersTests {

    @Test("UnshippedAppUpdates does not claim a milestone that has already shipped")
    func appUpdatesStubNamesNoPastMilestone() {
        guard case .unavailable(let reason) = UnshippedAppUpdates().state else {
            Issue.record("expected .unavailable")
            return
        }
        let lowered = reason.lowercased()
        // Sparkle has been the real app-update provider since 0.1.0 — see
        // `App/SopsGUIApp.swift`'s comment on `appUpdates:`. A stub reason
        // that still names Sparkle or an "M5" arrival date is describing a
        // milestone that already happened.
        #expect(!lowered.contains("sparkle"), "stub text still names a shipped milestone: \(reason)")
        #expect(!lowered.contains("m5"), "stub text still names a shipped milestone: \(reason)")
    }

    @Test("UnshippedKeyStore still names an unshipped milestone, because M3 genuinely has not landed")
    func keyStoreStubStillNamesAFutureMilestone() {
        guard case .unavailable(let reason) = UnshippedKeyStore().state else {
            Issue.record("expected .unavailable")
            return
        }
        // Not a claim that M3 is the eternal truth — a claim that whoever
        // ships M3 must update this text in the same change, the way this
        // ticket updated UnshippedAppUpdates's.
        #expect(reason.lowercased().contains("m3"))
    }
}
