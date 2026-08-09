import Testing
@testable import SopsUI

/// The two properties Task 12 had to file as "not reached".
///
/// Both are about a copy button's *label*, which used to be a
/// `@State private var didCopy` inside `HealthFindingRow` — reachable only by
/// clicking, and `Scripts/snapshots.sh` cannot click (CLAUDE.md, "What it
/// still cannot see"). `CopyFeedback` exists so the state lives somewhere a
/// test can drive it; see its doc comment.
///
/// Deliberately touches no pasteboard. `ClipboardClearingTests` owns the real
/// `NSPasteboard.general` and is `.serialized` for exactly that reason —
/// writing to it from a concurrently-running suite is a defect this project
/// has already paid for once.
@Suite("CopyFeedback")
@MainActor
struct CopyFeedbackTests {

    // MARK: - Between rows (the M1 concern)

    @Test("a button that was never copied from reads Copy")
    func startsAsCopy() {
        let feedback = CopyFeedback()
        #expect(feedback.label(for: "tool.age") == .actionCopy)
    }

    @Test("the button that was copied from reads Copied")
    func confirmedTargetReadsCopied() {
        let feedback = CopyFeedback()
        feedback.confirmCopy(of: "tool.age")
        #expect(feedback.label(for: "tool.age") == .actionCopied)
    }

    /// Copy row A, then look at row B. The pasteboard holds one thing, so one
    /// button at most may claim to have just filled it.
    @Test("copying one row's command leaves every other row reading Copy")
    func otherRowsAreUnaffected() {
        let feedback = CopyFeedback()
        feedback.confirmCopy(of: "tool.age")

        #expect(feedback.label(for: "security.legacy-key-file") == .actionCopy)
        #expect(feedback.label(for: "project.0.stale-recipients") == .actionCopy)
    }

    /// And the other half of it: the *first* row must go back to "Copy" when
    /// the second is copied, or both would be claiming the clipboard at once.
    @Test("copying a second row un-confirms the first")
    func aSecondCopyMovesTheConfirmation() {
        let feedback = CopyFeedback()
        feedback.confirmCopy(of: "tool.age")
        feedback.confirmCopy(of: "security.legacy-key-file")

        #expect(feedback.label(for: "tool.age") == .actionCopy)
        #expect(feedback.label(for: "security.legacy-key-file") == .actionCopied)
    }

    // MARK: - The same row, after its timeout

    /// The half that was genuinely broken: before this, "Copied" was the
    /// resting state of a button for the rest of its view's life.
    @Test("the label returns to Copy once the confirmation expires")
    func labelExpires() async throws {
        let feedback = CopyFeedback(confirmationDuration: .milliseconds(50))
        feedback.confirmCopy(of: "tool.age")
        #expect(feedback.label(for: "tool.age") == .actionCopied)

        // Polled to a deadline rather than "sleep 500ms, then assert".
        // The expiry runs on the main actor, and so does every other suite in
        // this target — `AccessibilityTreeTests` lays out real
        // `NSHostingView`s and `WorkspaceSwitchDecisionTests` decrypts real
        // documents, concurrently. A fixed sleep measures how busy the main
        // actor happens to be as much as it measures this type; caught
        // exactly that way, failing at 500ms in a full-suite run and passing
        // alone. The deadline is generous because a *broken* expiry never
        // fires at all, so the only cost of generosity is how long a real
        // failure takes to report. Twenty seconds and not five: five was not
        // enough under bare `swift test`, which runs every suite in this
        // package in one process, and where another suite blocking the main
        // actor delays this expiry and this loop's own polling alike.
        let deadline = ContinuousClock.now + .seconds(20)
        while feedback.label(for: "tool.age") != .actionCopy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(feedback.label(for: "tool.age") == .actionCopy)
    }

    /// A second copy of the *same* row restarts the clock rather than
    /// inheriting the first copy's remaining time — otherwise a click landing
    /// just before an old expiry would flash "Copied" and lose it again.
    @Test("re-copying the same row restarts its confirmation")
    func recopyingRestartsTheClock() async throws {
        let feedback = CopyFeedback(confirmationDuration: .milliseconds(200))
        feedback.confirmCopy(of: "tool.age")
        try await Task.sleep(for: .milliseconds(150))
        feedback.confirmCopy(of: "tool.age")

        // Past the first confirmation's expiry, well short of the second's.
        try await Task.sleep(for: .milliseconds(100))
        #expect(feedback.label(for: "tool.age") == .actionCopied)
    }

    /// An expiry scheduled by an earlier copy must not clear a later one's
    /// confirmation when it fires. Same property `ClipboardClearing`'s
    /// `changeCount` guard holds for the pasteboard itself.
    @Test("an earlier row's expiry does not clear a later row's confirmation")
    func staleExpiryDoesNotClobber() async throws {
        let feedback = CopyFeedback(confirmationDuration: .milliseconds(200))
        feedback.confirmCopy(of: "tool.age")
        try await Task.sleep(for: .milliseconds(150))
        feedback.confirmCopy(of: "security.legacy-key-file")

        try await Task.sleep(for: .milliseconds(100))
        #expect(feedback.label(for: "security.legacy-key-file") == .actionCopied,
                "the first row's expiry cleared the second row's confirmation")
    }

    @Test("reset drops a standing confirmation immediately")
    func resetClearsImmediately() {
        let feedback = CopyFeedback()
        feedback.confirmCopy(of: "tool.age")
        feedback.reset()
        #expect(feedback.label(for: "tool.age") == .actionCopy)
    }

    // MARK: - The label may never outlive what it describes

    /// The one direction of the label/clipboard relationship that can lie to
    /// the user: a button still reading "Copied" after `ClipboardClearing`
    /// has already wiped the pasteboard. See `CopyFeedback`'s doc comment.
    @Test("the confirmation expires well before the clipboard it could describe")
    func confirmationIsShorterThanTheClipboardsLifetime() {
        #expect(CopyFeedback.defaultConfirmationDuration < ClipboardClearing.defaultInterval)
    }
}
