import Foundation
import Observation

/// Which copy button, if any, is currently saying "Copied" instead of "Copy".
///
/// ## Why this is a type and not a `@State private var didCopy`
/// It was a `Bool` in `HealthFindingRow` and another in `KeyImportView`, and
/// in both it was write-only: set to `true` on click and never set back, so
/// the button said "Copied" for the rest of that view's life. Nothing caught
/// it because nothing could — a `@State` that only changes on a real click is
/// unreachable from a unit test and invisible to `Scripts/snapshots.sh`, which
/// renders an un-clicked view (CLAUDE.md, "What it still cannot see"). Task 12
/// looked at it and had to file it as "not reached". Moving the state out of
/// the view is what makes the two properties below testable at all.
///
/// ## One confirmation at a time, keyed by target
/// The pasteboard holds exactly one thing, so at most one button may claim to
/// have just filled it. `target` is whatever identifies the button —
/// `HealthFinding.id` for a remediation command — and confirming one target
/// un-confirms every other, so copying row A's command can never leave row B
/// reading "Copied". That was M1's concern about a shared flag, and this is
/// the shape in which it is a property of one object a test can drive, rather
/// than an accident of SwiftUI giving each row its own `@State`.
///
/// ## How long the label lasts, and why it is not the clipboard's ~30s
/// `confirmationDuration` is deliberately far shorter than
/// `ClipboardClearing.defaultInterval`, and the ordering is load-bearing in
/// one direction only: **the label must never outlive what it describes.** A
/// button still reading "Copied" after `ClipboardClearing` has already wiped
/// the pasteboard would be telling the user their clipboard holds something
/// it does not — and for a secret, that is the direction that costs them a
/// failed paste at the worst moment. The reverse (the label reverting while
/// the pasteboard still holds the value) claims nothing false: "Copied" is an
/// acknowledgement that the click landed, not a live readout of pasteboard
/// contents.
///
/// The two call sites today (`HealthFindingRow`, `KeyImportView`) copy shell
/// commands, not secrets, and write to `NSPasteboard` directly rather than
/// through `ClipboardClearing` — nothing clears those, so nothing can expire
/// under the label. `CopyFeedbackTests` pins the inequality anyway, so a
/// future secret-copying button that does route through `ClipboardClearing`
/// inherits a label that cannot lie.
@MainActor
@Observable
public final class CopyFeedback {

    /// Long enough to be seen and read, short enough that a stale "Copied"
    /// never becomes the resting state of a button. Well under
    /// `ClipboardClearing.defaultInterval` — see the type's doc comment.
    public static let defaultConfirmationDuration: Duration = .seconds(2)

    private let confirmationDuration: Duration
    private var confirmedTarget: String?

    /// Bumped by every `confirmCopy(of:)` and by `reset()`, so an in-flight
    /// expiry from an earlier copy cannot clear a later one's confirmation
    /// when it finally fires. Same shape as `ClipboardClearing`'s
    /// `changeCount` guard, and for the same reason: the thing being cleared
    /// must be the thing this timer was scheduled for.
    private var confirmationCount = 0

    /// - Parameter confirmationDuration: how long "Copied" stays up.
    ///   Overridable so a test can drive the expiry in milliseconds instead of
    ///   waiting out the real interval — the same seam
    ///   `ClipboardClearing.copy(_:clearingAfter:)` exposes.
    public init(confirmationDuration: Duration = CopyFeedback.defaultConfirmationDuration) {
        self.confirmationDuration = confirmationDuration
    }

    /// What `target`'s copy button should read right now.
    public func label(for target: String) -> LocalizedKey {
        confirmedTarget == target ? .actionCopied : .actionCopy
    }

    /// Records that `target`'s value was just put on the pasteboard, and
    /// schedules the label's return to "Copy".
    ///
    /// Does not touch the pasteboard itself. That is the caller's job, and
    /// keeping it out of here is what lets the tests for this type run
    /// alongside `ClipboardClearingTests` without the two fighting over the
    /// one real `NSPasteboard.general` they would otherwise share.
    public func confirmCopy(of target: String) {
        confirmedTarget = target
        confirmationCount += 1
        let confirmation = confirmationCount
        let duration = confirmationDuration
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard let self, self.confirmationCount == confirmation else { return }
            self.confirmedTarget = nil
        }
    }

    /// Drops any standing confirmation immediately.
    ///
    /// Used where the surrounding state changed enough that a leftover
    /// "Copied" would be about a command the user is no longer looking at —
    /// `KeyImportView` re-importing from the legacy key file, which redraws
    /// the callout the button lives in.
    public func reset() {
        confirmedTarget = nil
        confirmationCount += 1
    }
}
