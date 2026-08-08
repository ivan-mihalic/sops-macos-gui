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

        Task {
            try? await Task.sleep(for: interval)
            guard NSPasteboard.general.changeCount == expectedChangeCount else { return }
            NSPasteboard.general.clearContents()
        }
    }
}
