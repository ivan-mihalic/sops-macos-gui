import AppKit
import CryptoKit
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

    /// nspasteboard.org's de-facto marker for "this is a secret". Raycast,
    /// Alfred, Maccy, Paste and 1Password's own copy path all read it; a
    /// pasteboard entry carrying it is meant to be left out of, or at least
    /// obfuscated in, a clipboard history.
    ///
    /// This is the only part of the ~30s window that reaches a clipboard
    /// manager at all. A manager records the entry the instant it lands, so
    /// clearing `NSPasteboard.general` half a minute later does nothing
    /// whatsoever to the copy already written to that manager's on-disk
    /// history. The timer bounds how long the *pasteboard* holds the secret;
    /// this marker is what bounds how long everything else does.
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// The companion marker for "this will not be here long", which is
    /// literally true of every value this type puts on the pasteboard.
    ///
    /// `ConcealedType` is the semantically exact one and would be enough for
    /// a manager that implements the whole convention. `TransientType` is set
    /// as well because the convention is honoured piecemeal in practice —
    /// some tools skip only transient entries, some only concealed ones —
    /// and the cost of setting both is a second empty payload. Neither marker
    /// affects pasting: the string is still on the board under `.string`.
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    /// What the most recent `copy(_:clearingAfter:)` put on the pasteboard,
    /// in the only two forms the clear needs: the `changeCount` it produced,
    /// and a SHA-256 of the value.
    ///
    /// A digest rather than the value itself. The pasteboard already holds
    /// the plaintext — that is the whole problem this type is bounding — and
    /// keeping a second copy of it alive in this module for the length of the
    /// window, reachable from a crash report or a heap dump, would widen the
    /// exposure the timer exists to narrow. A digest answers the only
    /// question the guard asks ("is what is on the board still the thing I
    /// put there?") and answers nothing else.
    private struct PendingCopy {
        let changeCount: Int
        let digest: SHA256Digest
    }

    /// The copy whose clear has not yet been resolved — `nil` once that
    /// copy's guard has fired (whether it cleared or declined to), or if
    /// nothing has been copied through this type at all. Read by
    /// `clearOnTermination()` so the termination path runs the exact same
    /// guard the timer does, on the same piece of state, rather than a
    /// second copy of it that could drift.
    private static var pending: PendingCopy?

    /// Puts `value` on the general pasteboard — marked as a secret, and kept
    /// off this user's other devices — then clears it again after `interval`,
    /// provided the pasteboard is still holding that same secret.
    public static func copy(_ value: String, clearingAfter interval: Duration = defaultInterval) {
        let pasteboard = NSPasteboard.general
        // `.currentHostOnly` rather than a bare `clearContents()`: without it
        // the pasteboard is eligible for Universal Clipboard, and a value the
        // user copied to paste into a terminal on *this* machine is pushed to
        // every other Mac, iPhone and iPad signed into the same Apple
        // Account, where nothing in this process can ever clear it. There is
        // no public API to read this option back, so no test here asserts it;
        // it is stated as an implementation commitment, not as something
        // proven from outside.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.addTypes([.string, concealedType, transientType], owner: nil)
        pasteboard.setString(value, forType: .string)
        // Empty payloads: for both markers it is the presence of the type
        // that carries the meaning (nspasteboard.org).
        pasteboard.setData(Data(), forType: concealedType)
        pasteboard.setData(Data(), forType: transientType)

        let record = PendingCopy(changeCount: pasteboard.changeCount, digest: digest(of: value))
        pending = record

        Task {
            try? await Task.sleep(for: interval)
            clearIfStillOurs(record)
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
        guard let record = pending else { return }
        clearIfStillOurs(record)
    }

    /// The one guard both `copy`'s timer and `clearOnTermination()` run
    /// through: clears the pasteboard if, and only if, what is on it is
    /// still the secret the matching `copy` call put there.
    ///
    /// ## Why `changeCount` alone is not the question
    /// `changeCount` increments on every pasteboard write from any source,
    /// so an unchanged count is conclusive proof that the secret is still
    /// there and nobody else has claimed the board. A *changed* count,
    /// however, is not proof of the opposite, and treating it that way was a
    /// real hole: a clipboard manager that rewrites the pasteboard —
    /// normalising types, restoring a history entry, re-copying on a hotkey
    /// — moves the count while leaving the secret exactly where it was.
    /// Declining to clear in that case handed the secret a permanent stay,
    /// which is the precise opposite of this type's purpose. So a changed
    /// count falls through to the question that actually matters: is the
    /// string on the board still ours?
    ///
    /// Compared by digest, and only in this direction. Something the user
    /// copied *afterwards* — a password manager, another app, a second field
    /// in this same editor — hashes differently and is left strictly alone,
    /// which is the property the timer must never violate.
    ///
    /// Two consequences worth naming rather than discovering later. Copying
    /// the same value twice means the first window's clear can end the second
    /// window early — clearing a secret sooner than promised is the safe
    /// direction of that error. And reading the string back does briefly
    /// materialise it here; it is compared and dropped, never logged, and the
    /// pasteboard was already holding it.
    private static func clearIfStillOurs(_ record: PendingCopy) {
        // Whether this clears or not, the pending copy it was guarding has
        // been resolved. Nothing is left for a later call (e.g. termination,
        // after the timer already ran) to do on its behalf.
        if pending?.changeCount == record.changeCount {
            pending = nil
        }

        let pasteboard = NSPasteboard.general
        if pasteboard.changeCount == record.changeCount {
            pasteboard.clearContents()
            return
        }
        guard let current = pasteboard.string(forType: .string),
              digest(of: current) == record.digest
        else { return }
        pasteboard.clearContents()
    }

    private static func digest(of value: String) -> SHA256Digest {
        SHA256.hash(data: Data(value.utf8))
    }
}
