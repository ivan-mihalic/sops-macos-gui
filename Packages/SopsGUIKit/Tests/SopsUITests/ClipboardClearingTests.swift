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
}
