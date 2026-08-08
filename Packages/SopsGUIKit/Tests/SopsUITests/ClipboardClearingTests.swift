import AppKit
import Testing
@testable import SopsUI

// Exercises the real `NSPasteboard.general` — this is the one thing this
// type exists to touch, and a fake pasteboard would only prove this code
// agrees with itself about what `NSPasteboard` does. Timings use generous
// margins (an order of magnitude past the scheduled interval) rather than
// tight ones, since this runs on whatever machine `swift test` happens to be
// scheduled on.
@Suite("ClipboardClearing")
@MainActor
struct ClipboardClearingTests {

    @Test("copy puts the value on the pasteboard immediately")
    func copyPutsValueOnPasteboard() {
        let canary = "clipboard-canary-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .seconds(30))
        #expect(NSPasteboard.general.string(forType: .string) == canary)
    }

    @Test("the pasteboard is cleared after the interval elapses")
    func pasteboardClearsAfterInterval() async throws {
        let canary = "clipboard-canary-\(UUID().uuidString)"
        ClipboardClearing.copy(canary, clearingAfter: .milliseconds(50))

        #expect(NSPasteboard.general.string(forType: .string) == canary)

        try await Task.sleep(for: .milliseconds(400))

        #expect(NSPasteboard.general.string(forType: .string) != canary)
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
}
