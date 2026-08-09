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
///
/// ## Why this suite is serialized, and why the absence check waits
///
/// A review reported this red in 1 of 5 full runs and could not reproduce it in
/// 11 more; I could not reproduce it in 11 either (8 isolated, 3 full). That is
/// not the same as "it is fine" — for an arbitrary-code-execution property, an
/// unexplained red is the one result you cannot file away.
///
/// So two things were done rather than one explanation being picked. The suite
/// is `.serialized`, because the control test below deliberately *does* execute
/// a hook and running the two concurrently is the obvious way for one to be
/// blamed for the other. And the absence assertion settles first: git may
/// invoke an fsmonitor hook asynchronously, so checking immediately could pass
/// while the hook was still starting — a false negative in the direction that
/// matters, and a plausible source of an occasional red.
@Suite("A scanned repository cannot make the app run its code", .serialized)
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

        // Settle before asserting absence — an immediate check would pass while
        // an asynchronously-invoked hook was still starting.
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, !FileManager.default.fileExists(atPath: marker.path) {
            usleep(50_000)
        }

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

    /// There is exactly **one** place in the app that runs git, and it applies
    /// the mitigation.
    ///
    /// The previous version of this test counted call sites against guarded
    /// ones by matching source text, and a review walked past it five ways:
    /// rename the local holding the executable, write `self.gitPath`, put the
    /// guarded token inside a comment, hide the executable in an array — and,
    /// worst, **delete `safeArguments` from the helper** while leaving every
    /// call site untouched, which the count could not see at all.
    ///
    /// Counting was the wrong idea. `GitIgnoreOracle.runGit` is now the single
    /// chokepoint, so this asserts that shape instead: one `CommandRunner.run`
    /// in the file, carrying `safeArguments`. It is still source text — the
    /// behavioural test above is what actually proves the hook does not fire —
    /// but it now fails on the mutation that mattered most, and there is no
    /// arithmetic left to fool.
    @Test("git runs from exactly one place, and that place applies the mitigation")
    func gitHasASingleGuardedChokepoint() throws {
        let oracle = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SopsHealth/GitIgnoreOracle.swift")
        let source = try String(contentsOf: oracle, encoding: .utf8)

        // Comments are stripped first. A review defeated the sibling test in
        // `OuterSidebarSwitchTests` by moving the matched literal into a
        // comment above the gutted code, and the same trick applies here.
        let code = Self.strippingComments(source)

        let invocations = code.components(separatedBy: "CommandRunner.run").count - 1
        #expect(
            invocations == 1,
            "\(invocations) CommandRunner.run calls in GitIgnoreOracle — git must run from one place, or the mitigation is per-call-site again")

        #expect(
            code.contains("safeArguments + [\"-C\", root.path]"),
            "runGit no longer prepends safeArguments — every scanned repository can run code from its own .git/config")
    }

    /// Removes `//` line comments so a matched literal cannot be satisfied by
    /// a comment sitting above the very code it is supposed to describe.
    /// Removes `/* */` blocks as well as `//` line comments.
    ///
    /// The `//`-only version was defeated one round later in the obvious way:
    /// wrap the guarded form in `/* */` above the gutted code and every check
    /// passed while a click on About discarded a dirty document. Still naive —
    /// it does not know about string literals containing `//` — which is one
    /// more reason the real guard is behavioural.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                guard let close = rest.range(of: "*/") else { break }
                index = close.upperBound
                inBlock = false
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                guard let newline = rest.firstIndex(of: "\n") else { break }
                index = newline
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
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
