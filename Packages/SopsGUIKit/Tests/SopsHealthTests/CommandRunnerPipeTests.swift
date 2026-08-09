import Foundation
import Testing
@testable import SopsHealth

/// Writing to a child that never reads must not kill this process.
///
/// `CommandRunner` writes `standardInput` from a background thread and wraps
/// the write in `try?`. A comment claimed that was sufficient "because SIGPIPE
/// is disabled in Foundation's process handling". A review measured the
/// disposition under AppKit as `SIG_DFL` and killed a host app with exit 141 by
/// handing 2 MB to a child that exits immediately.
///
/// The reachable path is `GitIgnoreOracle`, which feeds git a NUL-joined
/// candidate list — past 64 KiB the writer blocks in `write`, and either git
/// failing with `fatal` or `CommandRunner`'s own `terminate()` closes the read
/// end underneath it. A crash there takes the open document with it and skips
/// `applicationWillTerminate`, so a copied secret stays on the pasteboard.
///
/// These tests are the property, not a proxy for it: if the fix regresses, the
/// **test process itself dies** and the whole suite reports a crash rather than
/// a failure. That is the correct shape here — there is no gentler signal to
/// assert on.
@Suite("A child that never reads stdin cannot kill this process")
struct CommandRunnerPipeTests {

    /// 2 MiB — comfortably past the pipe buffer, so the writer is guaranteed to
    /// still be inside `write` when the child is already gone.
    private static let oversizedInput = Data(repeating: UInt8(ascii: "x"), count: 2 << 20)

    @Test("a child that exits immediately without reading does not raise SIGPIPE")
    func childExitsWithoutReading() throws {
        let outcome = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "exit 0"],
            standardInput: Self.oversizedInput,
            timeout: 10)

        // Reaching this line at all is the assertion — an unhandled SIGPIPE
        // would have taken the test runner down before it.
        let result = try #require(outcome, "the command did not run")
        #expect(result.terminationStatus == 0)
    }

    @Test("a child killed by our own timeout does not raise SIGPIPE either")
    func timeoutClosesThePipeUnderTheWriter() throws {
        // Sleeps without reading, so the write blocks and `terminate()` closes
        // the read end while the writer is still in it — the second reachable
        // trigger, and the one that does not need the child to fail.
        let outcome = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "sleep 30"],
            standardInput: Self.oversizedInput,
            timeout: 2)

        let result = try #require(outcome, "the command did not run")
        #expect(result.timedOut, "the fixture did not actually time out, so it proves nothing")
    }

    /// The control: without it, both tests above would pass on a machine where
    /// SIGPIPE happened to be ignored for an unrelated reason, and would keep
    /// passing if the fix were removed on such a machine.
    @Test("SIGPIPE really is ignored after CommandRunner has run with stdin")
    func dispositionIsIgnored() {
        _ = CommandRunner.run("/bin/sh", arguments: ["-c", "exit 0"],
                              standardInput: Data("probe".utf8), timeout: 5)

        var current = sigaction()
        sigaction(SIGPIPE, nil, &current)
        // Function pointers are not Equatable in Swift, so compare the raw
        // bit patterns — which is what the C macro comparison is anyway.
        let handler = unsafeBitCast(current.__sigaction_u.__sa_handler, to: UInt.self)
        let ignore = unsafeBitCast(SIG_IGN, to: UInt.self)
        #expect(
            handler == ignore,
            "SIGPIPE is not ignored, so a write to a closed pipe still terminates the app")
    }
}

/// `timeout:` has to be a bound, and a truncated read has to be reported as
/// one.
@Suite("CommandRunner's timeout is a bound, and a partial read is not a success")
struct CommandRunnerTimeoutTests {

    /// `terminate()` sends SIGTERM, which a child may ignore. Before the
    /// escalation to SIGKILL, `waitUntilExit()` blocked indefinitely — a review
    /// measured a `timeout: 2` call still running after 15 seconds, with no
    /// outer deadline anywhere to catch it.
    @Test("a child that ignores SIGTERM is killed rather than waited on forever")
    func sigtermIgnoringChildIsKilled() {
        let started = Date()
        let outcome = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30"],
            timeout: 1)
        let elapsed = Date().timeIntervalSince(started)

        // The property is the bound. `timeout: 1` plus the 2s kill grace and
        // the 1s drain window puts the ceiling near 4s; anything approaching
        // the child's own 30s means `waitUntilExit()` was blocked on a process
        // that ignored SIGTERM, which is what this exists to prevent.
        #expect(
            elapsed < 10,
            "took \(elapsed)s — the SIGTERM-ignoring child was waited on rather than killed")

        // `nil` rather than a `timedOut` outcome, and that is correct here:
        // `sleep` is a grandchild holding the same pipe, so killing `sh` does
        // not close it and the readers never reach EOF. Returning a
        // half-drained buffer as a status-0 success is exactly what this
        // function now refuses to do.
        #expect(
            outcome == nil || outcome?.timedOut == true,
            "a command that blew its deadline came back looking like a clean success")
    }

    @Test("an ordinary command is unaffected by the escalation")
    func ordinaryCommandStillWorks() throws {
        let outcome = CommandRunner.run("/bin/sh", arguments: ["-c", "echo hello"], timeout: 5)
        let result = try #require(outcome)
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
        #expect(!result.timedOut)
    }
}

/// A grandchild holding a pipe must not discard a complete answer.
@Suite("A lingering grandchild does not invalidate the child's output")
struct CommandRunnerGrandchildTests {

    /// Iteration 4 required *both* readers to reach EOF before returning an
    /// outcome. EOF waits on every process holding the write end, so a
    /// background grandchild that inherits stderr keeps that reader blocked
    /// while stdout has already delivered everything.
    ///
    /// The two callers this broke: `ToolLocator` silently lost the login
    /// shell's PATH (leaving four hardcoded fallbacks, so an mise/asdf/nix user
    /// is told an installed tool is missing), and `GitIgnoreOracle` reported
    /// "This project is not inside a git repository" about one that is.
    @Test("stdout is honoured even when a grandchild still holds stderr")
    func grandchildHoldingStderrDoesNotDiscardStdout() throws {
        let outcome = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo true; sleep 25 >/dev/null & exit 0"],
            timeout: 5)

        let result = try #require(
            outcome,
            "a complete stdout answer was discarded because a grandchild still held stderr")
        #expect(
            result.standardOutputComplete,
            "the grandchild's stdout is redirected to /dev/null, so stdout closed cleanly — flagging it incomplete is one stream speaking for the other")
        #expect(result.terminationStatus == 0)
        #expect(result.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) == "true")
        #expect(!result.timedOut)
    }
}

/// stderr must survive a grandchild that never closes it.
@Suite("Partial output is published as it arrives, not only at EOF")
struct CommandRunnerPartialOutputTests {

    /// `ToolLocator` parses stderr, because many tools print `--version`
    /// there. With `readDataToEndOfFile` the box was only filled at EOF, and
    /// EOF waits on every process holding the write end — so a lingering
    /// grandchild turned a tool that answered correctly into
    /// `terminationStatus: 0` with empty output. "The tool ran fine and said
    /// nothing" is the inversion this file elsewhere calls worse than nothing.
    @Test("stderr written before exit is returned even if a grandchild holds the pipe open")
    func stderrSurvivesALingeringGrandchild() throws {
        let outcome = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo 1.2.3 >&2; sleep 25 & exit 0"],
            timeout: 5)

        let result = try #require(outcome, "the command did not run")
        #expect(
            result.standardErrorText.contains("1.2.3"),
            "stderr came back empty because a grandchild kept the pipe open — a tool that reported its version reads as one that said nothing")
        #expect(
            !result.standardErrorComplete,
            "stderr is flagged complete although its reader was still blocked")
        #expect(
            !result.standardOutputComplete,
            "this grandchild inherits stdout too, so stdout is genuinely incomplete and must say so")
    }

    @Test("ordinary stdout and stderr are both still complete")
    func bothStreamsStillComplete() throws {
        let outcome = CommandRunner.run(
            "/bin/sh",
            arguments: ["-c", "echo out; echo err >&2"],
            timeout: 5)

        let result = try #require(outcome)
        #expect(result.standardOutputText.contains("out"))
        #expect(result.standardErrorText.contains("err"))
        #expect(result.terminationStatus == 0)
    }
}
