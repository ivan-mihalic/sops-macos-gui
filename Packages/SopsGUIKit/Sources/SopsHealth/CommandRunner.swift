import Foundation

/// What a finished child process produced.
struct CommandOutcome {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
    /// True when the process had to be terminated because it outlived its
    /// timeout. Its output is then partial and its status meaningless.
    let timedOut: Bool
    /// False when the **stdout** reader was still blocked at the deadline, so
    /// that stream may be short of what the child actually wrote.
    ///
    /// This exists because "empty" and "incomplete" needed separating, and one
    /// bool could not do it. EOF on a pipe waits for **every** process holding
    /// the write end, so a grandchild that outlives the child keeps a reader
    /// blocked forever — while the child has already exited 0 and said
    /// everything it was going to say.
    ///
    /// The two callers want opposite things. `GitIgnoreOracle` must have the
    /// whole answer: a partial ignore list silently promotes the missing
    /// entries to "not ignored", which is how a gitignored `.env` gets
    /// reported as a plaintext leak. `ToolLocator` only wants whatever version
    /// string was printed, and a lingering grandchild is not a reason to call
    /// an installed tool missing.
    let standardOutputComplete: Bool
    /// The same, for stderr. Separate because the two streams fail
    /// independently: EOF waits on every process holding *that* pipe's write
    /// end, so a grandchild can block one while the other closed cleanly.
    ///
    /// One flag for both was iteration 7's mistake, and it produced the
    /// mirror image of the bug it fixed: `GitIgnoreOracle` reads only stdout,
    /// but required a combined flag, so a fake git that answered `true` on
    /// stdout, exited 0, and left a grandchild on stderr came back as
    /// "git did not finish answering". The comment above the flag even said
    /// stderr was deliberately excluded from the condition while the code six
    /// lines down included it.
    let standardErrorComplete: Bool

    var standardOutputText: String { String(decoding: standardOutput, as: UTF8.self) }
    var standardErrorText: String { String(decoding: standardError, as: UTF8.self) }
}

/// Runs a child process to completion and collects its output.
///
/// This app only ever runs *read-only* probes with it — `git --version`,
/// `git check-ignore`. It never runs a remediation: PROPOSAL.md §6 says the
/// app explains and the user acts, and nothing in `Remediation.command`
/// reaches this type.
///
/// Both pipes are drained on their own threads *while* the child runs, and
/// stdin is written on a third. A child that writes more than the pipe buffer
/// (~64 KB) blocks on `write` until someone drains it, so the "wait for exit,
/// then read" shape deadlocks against its own backpressure until the timeout
/// fires — and then reports truncated output as if it were complete. Draining
/// concurrently avoids both. The same reasoning applies in reverse to stdin:
/// a large path list would block *us* if we wrote it inline and the child was
/// not reading yet.
enum CommandRunner {

    static func run(
        _ executable: String,
        arguments: [String],
        standardInput: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval
    ) -> CommandOutcome? {
        let process = Process()
        // Passed to the child, never to this process. A test that needs a
        // different environment must not reach for `setenv`: it is
        // process-wide, and under Swift Testing's parallelism it leaks into
        // every suite running beside it — which is exactly how a login-shell
        // test that passed in isolation started failing in the full run.
        if let environment { process.environment = environment }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let inPipe: Pipe?
        if standardInput != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            // No standardInput: an unattached stdin reads as EOF for the child
            // rather than blocking it waiting for input.
            inPipe = nil
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        let outBox = Box<Data>(Data())
        let errBox = Box<Data>(Data())
        // Chunked rather than `readDataToEndOfFile()`, which is all-or-nothing:
        // it sets the box only once EOF arrives, so a reader still blocked
        // yields **empty** data, not partial data.
        //
        // That mattered for stderr. EOF waits on every process holding the
        // write end, so a grandchild outliving the child keeps stderr open
        // indefinitely — and `ToolLocator` parses stderr, because many tools
        // print `--version` there. Measured: a fake tool printing its version
        // to stderr with a lingering grandchild came back `version=nil, raw=""`
        // — reported as "the tool ran fine and said nothing", which is the
        // inversion this file calls worse than nothing three paragraphs down.
        //
        // Appending as data arrives means whatever the child actually wrote is
        // available at the deadline whether or not the pipe ever closes.
        func drain(_ handle: FileHandle, into box: Box<Data>) {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { return }
                box.append(chunk)
            }
        }
        let outThread = Thread { drain(outPipe.fileHandleForReading, into: outBox) }
        let errThread = Thread { drain(errPipe.fileHandleForReading, into: errBox) }
        outThread.start()
        errThread.start()

        if let inPipe, let standardInput {
            // A child that exits early (git check-ignore does, on `fatal`)
            // leaves us writing to a closed pipe. `try?` is not enough: the
            // default disposition of SIGPIPE **terminates the process**, and
            // the comment that used to sit here claimed Foundation disables
            // it — a review measured that as false. Under AppKit the
            // disposition is `SIG_DFL`, and a 2 MB write to a child that never
            // reads killed the app with exit 141.
            //
            // Two triggers are reachable today, both through
            // `GitIgnoreOracle`, whose candidate list passes 64 KiB on any
            // sizeable project: git failing with `fatal`, and this function's
            // own `terminate()` below closing the pipe while the writer is
            // still going.
            //
            // A crash here is worse than a failed check — the open document
            // goes with it, and `applicationWillTerminate` is skipped, so a
            // copied secret stays on the pasteboard.
            ignoreSIGPIPEOnce()
            let writer = Thread {
                let handle = inPipe.fileHandleForWriting
                try? handle.write(contentsOf: standardInput)
                try? handle.close()
            }
            writer.start()
        }

        var timedOut = false
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            timedOut = true
            // `terminate()` is SIGTERM, which a child is free to ignore — and
            // then `waitUntilExit()` below blocks forever. `timeout:` read as
            // a bound but was not one: a review ran `sleep 30` with
            // `timeout: 2` and the call was still blocked 15 seconds later.
            // There is no outer deadline to catch that — `HealthReport.run()`
            // has no per-check limit and `HealthViewModel.refresh()` would sit
            // at `isRunning == true` for the rest of the session.
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < killDeadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        // Both readers hit EOF once the process exits and the write ends close;
        // give them a bounded moment to finish draining.
        let readDeadline = Date().addingTimeInterval(1)
        while (!outThread.isFinished || !errThread.isFinished) && Date() < readDeadline {
            usleep(10_000)
        }

        // A **stdout** reader that has not reached EOF has a partially filled
        // — or empty — box, and returning that as a status-0 success is worse
        // than returning nothing.
        //
        // Measured consequence of the old behaviour: `GitIgnoreOracle.ignoredPaths`
        // reads an empty set as "git ignores none of these", so every candidate
        // becomes `exposed` and the user is told their gitignored `.env` files
        // are leaking. A false accusation, from a drain that timed out.
        //
        // **stderr is deliberately not part of this condition**, and the first
        // version of this check got that wrong. EOF on a pipe waits for every
        // process holding the write end, not just the child — so a grandchild
        // that inherited stderr and outlives the child keeps that reader
        // blocked while stdout has already delivered a complete answer.
        // Measured: `sh -c "echo true; sleep 25 >/dev/null & exit 0"` returned
        // the full `true\n` on stdout, exit 0, and the check threw it away.
        // Downstream that turned into `ToolLocator` losing the login shell's
        // PATH and `GitIgnoreOracle` telling the user a real repository "is
        // not inside a git repository".
        //
        // stderr is diagnostic here — no caller parses it for a decision — so
        // whatever arrived by the deadline is good enough for it.
        return CommandOutcome(
            standardOutput: outBox.get(),
            standardError: errBox.get(),
            terminationStatus: process.terminationStatus,
            timedOut: timedOut,
            standardOutputComplete: outThread.isFinished,
            standardErrorComplete: errThread.isFinished
        )
    }

    /// Sets SIGPIPE to `SIG_IGN`, process-wide, exactly once.
    ///
    /// Process-wide because signal dispositions are: there is no per-thread
    /// SIGPIPE. With it ignored, a write to a closed pipe returns `EPIPE`
    /// instead of killing the app — which is what every `try?` around a pipe
    /// write in this file already assumed was happening.
    ///
    /// A `static let` so the `signal(2)` call happens once no matter how many
    /// commands run concurrently.
    private static let sigpipeIgnored: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    private static func ignoreSIGPIPEOnce() {
        _ = sigpipeIgnored
    }
}

/// Minimal thread-safe box, used to hand data back from a drain thread without
/// pulling in a heavier concurrency primitive.
final class Box<Value>: @unchecked Sendable {
    fileprivate var value: Value
    fileprivate let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        defer { lock.unlock() }
        value = newValue
    }
}

extension Box where Value == Data {
    /// Appends under the same lock, so a drain thread can publish partial
    /// output as it arrives instead of only at EOF.
    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        value.append(chunk)
    }
}
