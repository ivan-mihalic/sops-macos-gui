import AppKit
import Testing
@testable import SopsUI

// Exercises the real `NSPasteboard.general` — this is the one thing this
// type exists to touch, and a fake pasteboard would only prove this code
// agrees with itself about what `NSPasteboard` does. Timings use generous
// margins (an order of magnitude past the scheduled interval) rather than
// tight ones, since this runs on whatever machine `swift test` happens to be
// scheduled on.
// `.serialized`: every test here touches the real, process-wide
// `NSPasteboard.general` (see the comment above), so two of these running
// concurrently can interleave — one test's synchronous pasteboard write
// landing between another's `await` and its assertion. Caught exactly that
// way running the full suite: "a later copy is not clobbered" read back
// "clipboard-other-…" from the concurrently-running termination test instead
// of its own "clipboard-second-…". Serializing trades a slightly slower
// suite for tests whose failures mean something.
@Suite("ClipboardClearing", .serialized)
@MainActor
struct ClipboardClearingTests {

    @Test("copy puts the value on the pasteboard immediately")
    func copyPutsValueOnPasteboard() {
        let canary = "clipboard-canary-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .seconds(30))
        #expect(NSPasteboard.general.string(forType: .string) == canary)
    }

    /// Waits for `condition` to hold, polling until it does or `timeout`
    /// elapses. Returns whether it ever held.
    ///
    /// This replaces a fixed `Task.sleep` followed by a single check. The
    /// difference matters, and it is the same distinction Task 16 drew for
    /// `ProjectHealthCheckLargeFileTests`: "the clear happened" is the
    /// property; "the clear happened within 400ms" is a wall-clock proxy for
    /// it that also measures how busy the machine is. `ClipboardClearing`
    /// schedules its clear as a `@MainActor Task`, and under bare
    /// `swift test` — one process, all 64 suites, many of them `@MainActor`
    /// — the main actor can stay saturated well past any fixed margin. Two
    /// of ten consecutive full-suite runs failed here for exactly that
    /// reason, with the clear arriving late rather than not at all.
    ///
    /// The timeout is not a loosened margin: it is a hang detector, three
    /// orders of magnitude past the 50ms interval under test. A clear that
    /// never gets scheduled still fails this, which is the regression the
    /// test exists to catch. Promptness was never the property — the shipped
    /// interval is 30 seconds, and nothing anywhere asserts its accuracy.
    ///
    /// The `await` inside the loop is also what makes the poll *work* rather
    /// than spin: it yields the main actor, which is precisely what the
    /// pending clear task is waiting for.
    private static func eventually(
        within timeout: Duration, _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("the pasteboard is cleared after the interval elapses")
    func pasteboardClearsAfterInterval() async throws {
        let canary = "clipboard-canary-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .milliseconds(50))

        #expect(NSPasteboard.general.string(forType: .string) == canary)

        let cleared = await Self.eventually(within: .seconds(10)) {
            NSPasteboard.general.string(forType: .string) != canary
        }
        #expect(cleared,
                "the scheduled clear never ran: a value copied through ClipboardClearing stayed on the pasteboard for ten seconds after a 50ms interval")
    }

    // The property PROPOSAL.md and the task brief both care about: a stale
    // clear timer must never clobber something the user copied *after* it —
    // a value from a password manager, another field, or a second row's
    // copy button.
    @Test("a later copy is not clobbered by an earlier copy's clear timer")
    func laterCopySurvivesEarlierClear() async throws {
        let first = "clipboard-first-\(UUID().uuidString)"
        let second = "clipboard-second-\(UUID().uuidString)"

        ClipboardClearing.copy(first, clearingAfter: .milliseconds(50))
        try await Task.sleep(for: .milliseconds(10))
        ClipboardClearing.copy(second, clearingAfter: .seconds(30))

        // Long enough for `first`'s clear timer to fire and find the
        // pasteboard has moved on.
        try await Task.sleep(for: .milliseconds(400))

        #expect(NSPasteboard.general.string(forType: .string) == second)
    }

    // The finding this fix addresses: a copied secret must not survive an
    // ordinary quit for the rest of the ~30s window. `clearOnTermination()`
    // is what `AppDelegate.applicationWillTerminate(_:)` calls in the real
    // app; exercised directly here since driving an actual app-termination
    // notification isn't something a package test can do.
    @Test("clearOnTermination wipes a pending copy immediately")
    func terminationClearsPendingCopy() {
        let canary = "clipboard-termination-\(UUID().uuidString)"
        // Long interval: if this test is wrong and the timer (not the
        // termination call) did the clearing, the assertion below would
        // still pass by accident. Keeping the interval far longer than the
        // test can run rules that out.
        ClipboardClearing.copy(canary, clearingAfter: .seconds(30))
        #expect(NSPasteboard.general.string(forType: .string) == canary)

        ClipboardClearing.clearOnTermination()

        #expect(NSPasteboard.general.string(forType: .string) != canary)
    }

    // MARK: - The marker a clipboard manager actually reads

    /// The ~30s clear cannot reach the consequences of a clipboard manager.
    /// Raycast, Alfred, Maccy and Paste all record every pasteboard change
    /// into a searchable, on-disk history the moment it happens; wiping
    /// `NSPasteboard.general` half a minute later does nothing to the copy
    /// they already took. `org.nspasteboard.ConcealedType` is the de-facto
    /// opt-out (nspasteboard.org) and the only thing that reaches them.
    ///
    /// Asserted on `types` rather than on any value, because the marker's
    /// payload is deliberately empty — its presence *is* the signal.
    @Test("a copied secret is marked concealed so clipboard managers skip it")
    func copyMarksTheValueConcealed() {
        let canary = "clipboard-concealed-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .seconds(30))

        let types = NSPasteboard.general.types ?? []
        #expect(types.contains(ClipboardClearing.concealedType),
                "a secret went onto the pasteboard without org.nspasteboard.ConcealedType; every clipboard manager on the machine just archived it permanently. Types present: \(types)")
        #expect(types.contains(ClipboardClearing.transientType),
                "no org.nspasteboard.TransientType either; managers that honour only that marker still recorded it. Types present: \(types)")
        // And the value is still genuinely pasteable — the markers must not
        // have displaced the string.
        #expect(NSPasteboard.general.string(forType: .string) == canary)
    }

    // MARK: - What changeCount must do when a manager has touched the board

    /// The guard used to be "clear only if `changeCount` is untouched", which
    /// is the wrong way round in the one case that matters. A clipboard
    /// manager that rewrites the pasteboard — normalising types, restoring a
    /// history entry, re-copying on a hotkey — bumps `changeCount` while
    /// leaving *the secret itself* sitting there. The old guard read that as
    /// "somebody else owns this now" and skipped the clear entirely, so the
    /// secret stayed on the pasteboard forever: the exact opposite of what
    /// the ~30s window is for.
    @Test("a manager rewriting the same secret does not buy it a permanent stay")
    func rewrittenSecretIsStillCleared() async throws {
        let canary = "clipboard-rewritten-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .milliseconds(50))

        // A manager re-writing the identical value: changeCount moves, the
        // secret does not.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(canary, forType: .string)

        let cleared = await Self.eventually(within: .seconds(10)) {
            NSPasteboard.general.string(forType: .string) != canary
        }
        #expect(cleared,
                "the secret was left on the pasteboard indefinitely because something else rewrote it with the same value")
    }

    /// Same hole, at the termination call site.
    @Test("clearOnTermination wipes a secret a manager rewrote")
    func terminationClearsRewrittenSecret() {
        let canary = "clipboard-term-rewritten-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .seconds(30))

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(canary, forType: .string)

        ClipboardClearing.clearOnTermination()

        #expect(NSPasteboard.general.string(forType: .string) != canary)
    }

    // The other half of the guard: something copied *after* the secret —
    // by this app or any other — must survive termination exactly as it
    // must survive the timer. Same guard, same property, proven at the
    // other call site.
    @Test("clearOnTermination does not clobber a later, unrelated copy")
    func terminationDoesNotClobberLaterCopy() {
        let secret = "clipboard-secret-\(UUID().uuidString)"
        let other = "clipboard-other-\(UUID().uuidString)"

        ClipboardClearing.copy(secret, clearingAfter: .seconds(30))
        // Simulates something else claiming the pasteboard before quit —
        // another app, a password manager, or a second field in this same
        // editor — without going through `ClipboardClearing.copy` at all,
        // which is the realistic case: nothing about NSPasteboard requires
        // going through this type to write to it.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(other, forType: .string)

        ClipboardClearing.clearOnTermination()

        #expect(NSPasteboard.general.string(forType: .string) == other)
    }

    // MARK: - Remediation commands (ticket #6, claim 3)
    //
    // `HealthFindingRow` and `KeyImportView` copy shell remediation commands
    // — `chmod 600 <path>` — that carry the absolute path to the user's
    // private key file. That path is not a secret *value*, but it is exactly
    // the kind of thing a clipboard manager's on-disk history or Universal
    // Clipboard should not retain indefinitely, so it must not bypass the
    // concealed/transient/host-only markers the way a raw
    // `NSPasteboard.general.setString` does. It also must not be yanked back
    // after 30 seconds — the user is meant to paste it into a terminal on
    // their own schedule, and an auto-clear would take back something they
    // explicitly asked for. `copyWithoutAutoClear` is the seam that gives
    // both properties at once.

    @Test("copyWithoutAutoClear puts the value on the pasteboard immediately")
    func copyWithoutAutoClearPutsValueOnPasteboard() {
        let command = "clipboard-remediation-\(UUID().uuidString)"
        ClipboardClearing.copyWithoutAutoClear(command)
        #expect(NSPasteboard.general.string(forType: .string) == command)
    }

    @Test("copyWithoutAutoClear marks the value concealed and transient, same as copy")
    func copyWithoutAutoClearMarksConcealed() {
        let command = "clipboard-remediation-\(UUID().uuidString)"
        ClipboardClearing.copyWithoutAutoClear(command)

        let types = NSPasteboard.general.types ?? []
        #expect(types.contains(ClipboardClearing.concealedType),
                "a remediation command went onto the pasteboard without org.nspasteboard.ConcealedType, so a clipboard manager just archived a path to the user's private key file permanently. Types present: \(types)")
        #expect(types.contains(ClipboardClearing.transientType),
                "no org.nspasteboard.TransientType either. Types present: \(types)")
        #expect(NSPasteboard.general.string(forType: .string) == command)
    }

    /// The property that distinguishes this from `copy`: nothing schedules a
    /// clear, and nothing registers the copy for `clearOnTermination()` to
    /// act on either — calling it right afterwards must be a no-op against
    /// this copy. If `copyWithoutAutoClear` reused `copy`'s `pending` guard by
    /// mistake, this would catch it: the command would vanish the instant
    /// termination ran, instead of staying until the user pastes it.
    @Test("copyWithoutAutoClear does not register for clearOnTermination")
    func copyWithoutAutoClearSurvivesTermination() {
        let command = "clipboard-remediation-\(UUID().uuidString)"
        ClipboardClearing.copyWithoutAutoClear(command)

        ClipboardClearing.clearOnTermination()

        #expect(NSPasteboard.general.string(forType: .string) == command,
                "copyWithoutAutoClear registered with the same pending-clear guard copy() uses; a remediation command must survive termination, not be wiped like a timed secret")
    }
}
