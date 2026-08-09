import Foundation
import Testing
@testable import SopsHealth

/// A repository the user merely cloned must not be able to run code when this
/// app looks at it.
///
/// `GitIgnoreOracle` shells out to `git` on every project scan. `core.fsmonitor`
/// is a **repository-local** config key whose value git executes, so a hostile
/// (or merely compromised) repository could put a script there and have it run
/// as the user the moment the scan reached a file named `.env`. The oracle's
/// own doc comment said "read-only throughout", which was true of the
/// subcommands and beside the point: a read-only git subcommand is not a
/// read-only operation when git's configuration can name a program to run.
///
/// `safe.directory` does not help — the user owns the directory they just
/// cloned into, which is precisely the case that check exists to allow.
@Suite("A scanned repository cannot make the app run its code")
struct GitIgnoreOracleSafetyTests {

    private static var gitPath: String? {
        for candidate in ["/opt/homebrew/bin/git", "/usr/bin/git", "/usr/local/bin/git"]
        where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }

    /// The end-to-end proof, driven through the public entry point rather than
    /// a private helper — the mitigation has to hold for the call the app
    /// actually makes, not for a shape a test invented.
    ///
    /// Builds a real repository, plants a real hook, and asserts the marker
    /// file never appears. Before the fix this failed: the marker was there.
    @Test("classify() does not execute a hook the scanned repository configured")
    func classifyDoesNotRunTheRepositorysOwnHook() throws {
        let git = try #require(Self.gitPath, "git is required to establish this property")

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fsmonitor-\(UUID().uuidString)")
        let repo = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let marker = sandbox.appendingPathComponent("EXECUTED")
        let hook = repo.appendingPathComponent("hook.sh")
        try "#!/bin/sh\ntouch \(marker.path)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        run(git, ["-C", repo.path, "init", "-q", "."])
        run(git, ["-C", repo.path, "config", "core.fsmonitor", hook.path])

        let dotEnv = repo.appendingPathComponent(".env")
        try "SECRET=not-a-real-value\n".write(to: dotEnv, atomically: true, encoding: .utf8)

        _ = GitIgnoreOracle.classify(candidates: [dotEnv], root: repo, gitPath: git)

        #expect(
            !FileManager.default.fileExists(atPath: marker.path),
            "scanning a repository executed a program its own .git/config named")
    }

    /// The control. Without this, the test above would still pass if git
    /// stopped honouring `core.fsmonitor`, if the hook were not executable, or
    /// if the fixture were malformed — it would be asserting that nothing
    /// happens, for the wrong reason, forever.
    @Test("the same hook does fire without the mitigation, so the test above means something")
    func theHookIsRealWithoutTheMitigation() throws {
        let git = try #require(Self.gitPath, "git is required to establish this property")

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fsmonitor-control-\(UUID().uuidString)")
        let repo = sandbox.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let marker = sandbox.appendingPathComponent("EXECUTED")
        let hook = repo.appendingPathComponent("hook.sh")
        try "#!/bin/sh\ntouch \(marker.path)\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        run(git, ["-C", repo.path, "init", "-q", "."])
        run(git, ["-C", repo.path, "config", "core.fsmonitor", hook.path])

        let dotEnv = repo.appendingPathComponent(".env")
        try "SECRET=not-a-real-value\n".write(to: dotEnv, atomically: true, encoding: .utf8)

        // Deliberately *without* `-c core.fsmonitor=` — the call as it was.
        let input = Data((dotEnv.path + "\0").utf8)
        _ = CommandRunner.run(
            git,
            arguments: ["-C", repo.path, "check-ignore", "--stdin", "-z"],
            standardInput: input,
            timeout: 10)

        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "the unmitigated call did not fire the hook, so this fixture proves nothing and the sibling test is passing for the wrong reason")
    }

    /// Cheap and structural: no git invocation **anywhere in `Sources/`** may be
    /// assembled without the protective config.
    ///
    /// It used to read `GitIgnoreOracle.swift` alone, and a review defeated it
    /// in the obvious way: move `ls-files` into a sibling file without the
    /// mitigation, and both counts fall to 2 and the test passes. That is the
    /// same parse-one-file blindness that let an unguarded `//export` into
    /// `libprobe.h` on the Go side, found one review earlier — so it is fixed
    /// the same way, by looking at everything rather than at the file the bug
    /// happened to be in.
    @Test("every git invocation in Sources carries the protective config")
    func everyInvocationIsGuarded() throws {
        let sourcesRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")

        var source = ""
        var filesRead = 0
        if let walker = FileManager.default.enumerator(
            at: sourcesRoot, includingPropertiesForKeys: nil)
        {
            for case let url as URL in walker where url.pathExtension == "swift" {
                source += (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                filesRead += 1
            }
        }
        #expect(filesRead > 20, "read only \(filesRead) source files — has the layout moved?")

        // A git invocation is a `CommandRunner.run` whose *tool* is the git
        // executable. Counting bare `gitPath` would over-count:
        // `WorktreeResolver` has a local of the same name holding the path of
        // a `.git` directory, which it only ever `stat`s and reads. And the
        // other `CommandRunner.run` callers launch `$SHELL` or
        // `<tool> --version`, neither of which reads a repository's config.
        var gitInvocations = 0
        for chunk in source.components(separatedBy: "CommandRunner.run(").dropFirst() {
            let head = chunk.prefix(while: { $0.isWhitespace || $0 == "\n" })
            if chunk.dropFirst(head.count).hasPrefix("gitPath") {
                gitInvocations += 1
            }
        }
        #expect(
            gitInvocations > 0,
            "found no git invocations anywhere in Sources — has the oracle moved or been renamed?")

        let guarded = source.components(separatedBy: "arguments: gitArguments(root:").count - 1
        #expect(
            guarded == gitInvocations,
            "\(gitInvocations) git invocations in Sources but \(guarded) built through gitArguments — one of them can reach core.fsmonitor in a scanned repository")
    }

    private func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
