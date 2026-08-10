import CoreFoundation
import Foundation
import Testing

@testable import SopsHealth

/// The app froze solid the moment the Settings row was clicked. Not slowly —
/// permanently, with the window still on screen and every accessibility query
/// returning `kAXErrorCannotComplete`.
///
/// `sample(1)` on the live process gave the mechanism, and it is not the one
/// anybody would guess from reading the code:
///
///     NSHostingView.layout()
///       … KeyImportView.init
///         AgeKeyFileLocations.readFromLoginShell
///           ToolLocator.capture
///             CommandRunner.run
///               -[NSConcreteTask waitUntilExit]
///                 _CFRunLoopRunSpecificWithOptions      ← nested run loop
///                   __CFRunLoopDoSources0
///                     CA::Transaction::flush_as_runloop_observer
///                       NSDisplayCycleFlush
///                         -[NSWindow layoutIfNeeded]
///                           NSHostingView.layout()      ← re-entered
///                             … KeyImportView.init      ← and round again
///
/// `Process.waitUntilExit()` does not block the thread. It **runs a nested run
/// loop**, which lets AppKit's display cycle back in, which lays out the view
/// that is *currently* inside `init`, which spawns the process again. The
/// recursion has no bottom. The login shell being fast is irrelevant — timed
/// at 0.01 s on this machine while the app was hung.
///
/// So the bug is not "this is slow on the main thread", and a fix that only
/// moved the call off the main actor would leave the trap armed for the next
/// caller. `CommandRunner` must not pump a run loop, ever, on any thread.
@Suite("A command never pumps the caller's run loop", .serialized)
struct MainThreadReentrancyTests {

    /// Counts run-loop activity on the calling thread while a command runs. If
    /// `CommandRunner` spins a nested run loop, this observer fires — which is
    /// exactly the door the display cycle came back through.
    @MainActor
    @Test("running a command does not let the caller's run loop run")
    func commandDoesNotPumpTheRunLoop() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()

        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { _, _ in counter.value += 1 }
        CFRunLoopAddObserver(CFRunLoopGetCurrent(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetCurrent(), observer, .commonModes) }

        // Long enough that a run loop, if one were pumped, would certainly get
        // a turn; short enough not to slow the suite.
        let result = CommandRunner.run("/bin/sh", arguments: ["-c", "sleep 0.4; printf ok"],
                                       timeout: 5)
        let output = result.map { String(decoding: $0.standardOutput, as: UTF8.self) }
        #expect(output?.trimmingCharacters(in: .whitespacesAndNewlines) == "ok",
                "the command itself must still work")
        #expect(counter.value == 0, """
            CommandRunner pumped the caller's run loop. On the main thread that \
            re-enters AppKit's display cycle and calls back into whatever view \
            was being laid out — the app hangs forever. See this suite's comment.
            """)
    }

    /// The timeout path takes a different route out of the function, and it is
    /// the one that ends in the unconditional wait. It must not pump either.
    @MainActor
    @Test("a command that has to be killed does not pump the run loop either")
    func timingOutDoesNotPumpTheRunLoop() throws {
        final class Counter: @unchecked Sendable { var value = 0 }
        let counter = Counter()

        let observer = CFRunLoopObserverCreateWithHandler(
            nil, CFRunLoopActivity.allActivities.rawValue, true, 0
        ) { _, _ in counter.value += 1 }
        CFRunLoopAddObserver(CFRunLoopGetCurrent(), observer, .commonModes)
        defer { CFRunLoopRemoveObserver(CFRunLoopGetCurrent(), observer, .commonModes) }

        // Ignores SIGTERM, so the runner has to escalate to SIGKILL and then
        // reap it — the exact sequence whose final wait caused the hang.
        _ = CommandRunner.run("/bin/sh",
                              arguments: ["-c", "trap '' TERM; sleep 30"],
                              timeout: 0.5)
        #expect(counter.value == 0, "the kill path pumped the caller's run loop")
    }
}
