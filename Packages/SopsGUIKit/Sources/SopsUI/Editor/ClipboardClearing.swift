import AppKit
import Foundation

/// Copies a value to the general pasteboard and clears it again after a
/// fixed delay — PROPOSAL.md §2: "clipboard auto-cleared after ~30 s",
/// applied to the editor's per-row copy button (Task 9's brief) exactly as
/// it already applies to the key-reveal flow M3 will build.
///
/// ## Where the interval lives
/// Task 9's brief says to reuse whatever Settings already exposes for this,
/// or decide where it lives if nothing does. Settings today has no UI for
/// it at all — `UpdateSettingsPanel` and `KeyImportView` are the only two
/// tabs, and neither is about timing. Building a new Settings tab for a
/// single number is out of proportion to this task, so `defaultInterval`
/// below is a single named constant instead: every call site in this module
/// already goes through it rather than hardcoding a duration, so a future
/// Settings screen (session TTL and clipboard delay belong together per
/// PROPOSAL.md §4, and session TTL doesn't exist until M3 either) can source
/// it from `UserDefaults` without any call site changing — the same seam
/// `SessionKeyStore`'s doc comment describes for swapping its own storage.
@MainActor
public enum ClipboardClearing {

    /// PROPOSAL.md §2's "~30 s", taken literally.
    public static let defaultInterval: Duration = .seconds(30)

    /// The `changeCount` recorded by the most recent `copy(_:clearingAfter:)`
    /// call that hasn't been cleared yet — `nil` once that copy's guard has
    /// already fired (successfully or not) or if nothing has been copied
    /// through this type at all. Read by `clearOnTermination()` so the
    /// termination path runs the exact same guard the timer does, on the
    /// same piece of state, rather than a second copy of it that could drift.
    private static var pendingChangeCount: Int?

    /// Puts `value` on the general pasteboard, then clears it again after
    /// `interval` — but only if the pasteboard still holds exactly what this
    /// call put there.
    ///
    /// Guarded by `NSPasteboard.changeCount` rather than by reading the
    /// string back and comparing: something else the user copied in the
    /// meantime — a password manager, another app, a second field in this
    /// same editor — must not be wiped out by a timer that has nothing to do
    /// with it. `changeCount` increments on every pasteboard write from any
    /// source, so a mismatch after the delay means somebody else already
    /// owns the pasteboard and this call has nothing left to clean up.
    public static func copy(_ value: String, clearingAfter interval: Duration = defaultInterval) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        let expectedChangeCount = pasteboard.changeCount
        pendingChangeCount = expectedChangeCount

        Task {
            try? await Task.sleep(for: interval)
            clearIfStillOwned(expecting: expectedChangeCount)
        }
    }

    /// Clears the pasteboard right now, but only through the same
    /// `changeCount` guard `copy` schedules its own timer with — reused, not
    /// reimplemented, because a guard this project has been bitten by
    /// duplicating before is only trustworthy as one piece of code. A no-op
    /// if nothing copied through this type is still pending (nothing was
    /// ever copied, or the timer already ran).
    ///
    /// ## What this covers, and what it does not
    /// Intended to be called from `NSApplicationDelegate.applicationWillTerminate(_:)`,
    /// which AppKit runs for an ordinary quit — Cmd-Q, the app's Quit menu
    /// item, "Quit and Keep Windows" — closing the window between a copy and
    /// the ~30s timer that would otherwise have cleaned it up. It does
    /// **not** run on a force-quit (Activity Monitor, `kill -9`/`SIGKILL`)
    /// or a crash: nothing in-process, including this, gets to run when the
    /// process is torn down from outside rather than asked to quit. This
    /// closes a gap in the timer; it is not a replacement for it, and it is
    /// not a guarantee that a copied secret never outlives the process.
    public static func clearOnTermination() {
        guard let expectedChangeCount = pendingChangeCount else { return }
        clearIfStillOwned(expecting: expectedChangeCount)
    }

    /// The one guard both `copy`'s timer and `clearOnTermination()` run
    /// through: clears the pasteboard only if it still holds exactly what
    /// the matching `copy` call put there.
    private static func clearIfStillOwned(expecting expectedChangeCount: Int) {
        // Whether this fires or not, the pending copy this call was guarding
        // has been resolved one way or the other — either cleared, or
        // superseded by someone else's write. Either way there is nothing
        // left for a later call (e.g. termination, after the timer already
        // ran) to do on its behalf.
        if pendingChangeCount == expectedChangeCount {
            pendingChangeCount = nil
        }
        guard NSPasteboard.general.changeCount == expectedChangeCount else { return }
        NSPasteboard.general.clearContents()
    }
}
