import Foundation

public struct LocatedTool: Equatable, Sendable {
    public let name: String
    public let path: String
    public let version: SemanticVersion?
    public let rawVersionOutput: String
}

public protocol ToolLocating: Sendable {
    func locate(_ name: String, versionArguments: [String]) async -> LocatedTool?
}

/// Finds CLI tools without trusting the process `PATH`.
///
/// A GUI app launched from Finder inherits a minimal environment — typically no
/// `/opt/homebrew/bin` — so `which sops` reports "missing" on a machine that has
/// it. We ask the login shell what its `PATH` is and probe well-known locations.
public struct ToolLocator: ToolLocating {
    private let searchPaths: [String]

    public init(searchPaths: [String]? = nil) {
        self.searchPaths = searchPaths ?? Self.loginShellSearchPaths()
    }

    public static func loginShellSearchPaths() -> [String] {
        var paths: [String] = []

        // -lc, never -lic: an interactive shell can block on prompts or plugins.
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if let output = try? Self.capture(shell, ["-lc", "echo $PATH"], timeout: 3) {
            paths += output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":").map(String.init)
        }

        // Fallbacks for the case where the login shell is unusable.
        paths += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    public func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? {
        guard let path = searchPaths
            .map({ ($0 as NSString).appendingPathComponent(name) })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }

        let output = (try? Self.capture(path, versionArguments, timeout: 5)) ?? ""
        return LocatedTool(
            name: name,
            path: path,
            version: Self.parseVersion(from: output),
            rawVersionOutput: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Pulls the first version-looking token out of a tool's output.
    /// Tools print wildly different shapes; anchoring on the first token that
    /// starts with a digit (optionally after a `v`) covers all of ours.
    public static func parseVersion(from output: String) -> SemanticVersion? {
        for token in output.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let candidate = token.drop(while: { $0 == "v" || $0 == "V" })
            guard candidate.first?.isNumber == true else { continue }
            if let version = SemanticVersion(parsing: String(candidate)) { return version }
        }
        return nil
    }

    /// Runs a command and returns stdout+stderr. Never throws for a non-zero
    /// exit — many tools print `--version` to stderr and exit non-zero.
    ///
    /// Reads the pipe to EOF on a background thread *while* the process runs,
    /// then waits for exit. A child that writes more than the pipe buffer
    /// (~64 KB) blocks on write until someone drains the pipe; polling
    /// `process.isRunning` in a sleep loop and only reading afterwards would
    /// deadlock against that backpressure until the timeout fired, and would
    /// silently truncate output even when the child finishes fine. Draining
    /// concurrently avoids both failure modes.
    private static func capture(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        // No standardInput: an unattached stdin reads as closed/EOF for the
        // child rather than blocking it waiting for input.

        try process.run()

        // Drain the pipe on a background thread concurrently with the process
        // running, so a chatty child never blocks on a full pipe buffer.
        let outputBox = Mutex<Data>(Data())
        let readThread = Thread {
            let handle = pipe.fileHandleForReading
            let data = handle.readDataToEndOfFile()
            outputBox.withLock { $0 = data }
        }
        readThread.start()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()

        // The read thread hits EOF once the process exits and the write end of
        // the pipe closes; give it a bounded moment to finish draining.
        let readDeadline = Date().addingTimeInterval(1)
        while !readThread.isFinished && Date() < readDeadline {
            usleep(10_000)
        }

        let data = outputBox.withLock { $0 }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Minimal thread-safe box, used to hand data back from the background
/// drain thread without pulling in a heavier concurrency primitive.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
