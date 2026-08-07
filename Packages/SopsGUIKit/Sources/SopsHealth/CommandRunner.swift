import Foundation

/// What a finished child process produced.
struct CommandOutcome {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
    /// True when the process had to be terminated because it outlived its
    /// timeout. Its output is then partial and its status meaningless.
    let timedOut: Bool

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
        timeout: TimeInterval
    ) -> CommandOutcome? {
        let process = Process()
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
        let outThread = Thread { outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile()) }
        let errThread = Thread { errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile()) }
        outThread.start()
        errThread.start()

        if let inPipe, let standardInput {
            let writer = Thread {
                let handle = inPipe.fileHandleForWriting
                // A child that exits early (git check-ignore can) leaves us
                // writing to a closed pipe; SIGPIPE is disabled in Foundation's
                // process handling, so this surfaces as a throw we ignore.
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
            process.terminate()
        }
        process.waitUntilExit()

        // Both readers hit EOF once the process exits and the write ends close;
        // give them a bounded moment to finish draining.
        let readDeadline = Date().addingTimeInterval(1)
        while (!outThread.isFinished || !errThread.isFinished) && Date() < readDeadline {
            usleep(10_000)
        }

        return CommandOutcome(
            standardOutput: outBox.get(),
            standardError: errBox.get(),
            terminationStatus: process.terminationStatus,
            timedOut: timedOut
        )
    }
}

/// Minimal thread-safe box, used to hand data back from a drain thread without
/// pulling in a heavier concurrency primitive.
final class Box<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

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
