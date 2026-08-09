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
            .first(where: { Self.isRunnableExecutable(atPath: $0) })
        else { return nil }

        let output = (try? Self.capture(path, versionArguments, timeout: 5)) ?? ""
        return LocatedTool(
            name: name,
            path: path,
            version: Self.parseVersion(from: output),
            rawVersionOutput: output.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Whether something at `path` is a file this app could actually run.
    ///
    /// `FileManager.isExecutableFile(atPath:)` answers "is the execute bit set
    /// for me", and a directory's execute bit means *searchable*, not
    /// runnable — so every directory the user can `cd` into answers yes. A
    /// directory named `docker` anywhere in the search path therefore produced
    /// a `LocatedTool` whose version probe failed, i.e. a bogus `[UNKNOWN]
    /// Docker was found at … but its version output was not recognisable`.
    ///
    /// Worse than the bogus finding: `first(where:)` stops at it. A real
    /// `docker` later in `PATH` is never reached, so the directory *shadows*
    /// the tool and the report describes a machine the user does not have.
    ///
    /// The identical bug was found and fixed in `SecurityPostureCheck`'s
    /// legacy-key-file probe; this is the same fix, at the other site. Both
    /// cost only a `stat`.
    static func isRunnableExecutable(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Pulls the first version-looking token out of a tool's output.
    /// Tools print wildly different shapes; anchoring on the first token that
    /// starts with a digit (optionally after a `v`) covers all of ours.
    ///
    /// Tokenised on `Character.isWhitespace`, not on an explicit
    /// `" "`/`"\n"`/`"\t"` list. The explicit list had the CRLF blind spot
    /// that has now bitten this project four times (see `LineEndings`): a
    /// `"\r\n"` pair is one `Character` equal to none of the three, so a tool
    /// printing CRLF — unusual on macOS, but nothing here gets to assume the
    /// tool's provenance — came back as a single unsplittable token and no
    /// version was found at all.
    public static func parseVersion(from output: String) -> SemanticVersion? {
        for token in output.split(whereSeparator: \.isWhitespace) {
            let candidate = token.drop(while: { $0 == "v" || $0 == "V" })
            guard candidate.first?.isNumber == true else { continue }
            if let version = SemanticVersion(parsing: String(candidate)) { return version }
        }
        return nil
    }

    /// Runs a command and returns stdout followed by stderr. Never throws for
    /// a non-zero exit — many tools print `--version` to stderr and exit
    /// non-zero, so the status is deliberately ignored here.
    ///
    /// The concurrent-drain machinery this needs (a child that writes more
    /// than the ~64 KB pipe buffer blocks on `write` until someone reads, so
    /// "wait for exit, then read" deadlocks against its own backpressure)
    /// lives in `CommandRunner`, shared with the `git` probes in
    /// `GitIgnoreOracle`. One copy of that reasoning, not two.
    private static func capture(_ launchPath: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        guard let outcome = CommandRunner.run(launchPath, arguments: arguments, timeout: timeout) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return outcome.standardOutputText + outcome.standardErrorText
    }
}
