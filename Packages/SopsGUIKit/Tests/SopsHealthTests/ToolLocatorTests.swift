import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

@Suite("ToolLocator")
struct ToolLocatorTests {

    // Real output captured on macOS 26.5 from the tools this app cares about.
    @Test("parses the version out of each tool's real output", arguments: [
        ("sops 3.13.2\n[info] a new version of sops (v3.13.3) is available", SemanticVersion(3, 13, 2)),
        ("v1.3.1", SemanticVersion(1, 3, 1)),
        ("git version 2.54.0 (Apple Git-157)", SemanticVersion(2, 54, 0)),
        ("yq (https://github.com/mikefarah/yq/) version v4.44.3", SemanticVersion(4, 44, 3)),
        ("Docker version 29.4.0, build 9d7ad9f", SemanticVersion(29, 4, 0)),
    ])
    func parsesRealOutput(output: String, expected: SemanticVersion) {
        #expect(ToolLocator.parseVersion(from: output) == expected)
    }

    @Test("returns nil rather than a wrong version for unparseable output")
    func refusesToGuess() {
        #expect(ToolLocator.parseVersion(from: "") == nil)
        #expect(ToolLocator.parseVersion(from: "command not found") == nil)
    }

    @Test("finds a tool that exists only in a non-default search path")
    func findsToolOutsideProcessPath() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let script = dir.appendingPathComponent("faketool")
        try "#!/bin/sh\necho 'faketool version 9.8.7'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let locator = ToolLocator(searchPaths: [dir.path])
        let found = await locator.locate("faketool", versionArguments: ["--version"])

        #expect(found?.path == script.path)
        #expect(found?.version == SemanticVersion(9, 8, 7))
    }

    @Test("reports nil for a tool that is genuinely absent")
    func absentToolIsNil() async {
        let locator = ToolLocator(searchPaths: ["/nonexistent"])
        #expect(await locator.locate("definitely-not-a-tool", versionArguments: ["--version"]) == nil)
    }

    // Rewritten. The previous version of this test set SHELL to nothing in
    // particular, unset PATH, and asserted that the result contained
    // "/usr/bin" and one of "/opt/homebrew/bin" / "/usr/local/bin" — every one
    // of which is a hardcoded entry in `loginShellSearchPaths`'s own fallback
    // list. Deleting the login-shell probe entirely left it green, so it
    // proved nothing about the behaviour it was named for. That behaviour is
    // covered by `loginShellProbeOutputIsActuallyUsed` below.
    //
    // What is left worth testing is the *other* half: the fallbacks must still
    // hold up when the probe cannot run at all. This version makes that
    // load-bearing by pointing SHELL at a path that does not exist, so the
    // probe genuinely fails and only the fallback list can satisfy the
    // expectations. Deleting the fallback list fails this; deleting the probe
    // fails the other.
    @Test("the fallback search paths survive a login shell that cannot run")
    func fallbackPathsSurviveAnUnusableLoginShell() {
        let originalPath = getenv("PATH").map { String(cString: $0) }
        let originalShell = getenv("SHELL").map { String(cString: $0) }
        unsetenv("PATH")
        setenv("SHELL", "/nonexistent/definitely-not-a-shell-\(UUID().uuidString)", 1)
        defer {
            if let originalPath { setenv("PATH", originalPath, 1) }
            if let originalShell { setenv("SHELL", originalShell, 1) } else { unsetenv("SHELL") }
        }

        let paths = ToolLocator.loginShellSearchPaths()

        #expect(!paths.isEmpty)
        #expect(paths.contains("/usr/bin"))
        // The component exists specifically to recover Homebrew's location,
        // which a minimal process PATH would not contain.
        #expect(paths.contains("/opt/homebrew/bin") || paths.contains("/usr/local/bin"))
    }

    // Task 6's deferred finding, fixed at last. `isExecutableFile(atPath:)`
    // answers "is the execute bit set for me", and a directory's execute bit
    // means *searchable*. So a directory named `docker` in the search path
    // used to be located as if it were the tool.
    @Test("a directory with the tool's name is not mistaken for the tool")
    func directoryIsNotAnExecutable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-dir-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("docker"), withIntermediateDirectories: true)

        let locator = ToolLocator(searchPaths: [dir.path])
        #expect(await locator.locate("docker", versionArguments: ["--version"]) == nil)
    }

    // The sharper half of the same bug: `first(where:)` stops at the first
    // match, so a bogus directory earlier in the search path *shadows* the
    // real tool later in it. The report then describes a machine the user
    // does not have — a genuine `docker` reported as `[UNKNOWN]`.
    @Test("a directory earlier in the search path does not shadow the real tool")
    func directoryDoesNotShadowARealToolLaterInThePath() async throws {
        let decoyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-decoy-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(decoyDir)
        try FileManager.default.createDirectory(
            at: decoyDir.appendingPathComponent("faketool"), withIntermediateDirectories: true)

        let realDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-real-" + UUID().uuidString)

        ScratchDirectoryRegistry.shared.register(realDir)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(realDir)
        let script = realDir.appendingPathComponent("faketool")
        try "#!/bin/sh\necho 'faketool version 9.8.7'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let locator = ToolLocator(searchPaths: [decoyDir.path, realDir.path])
        let found = await locator.locate("faketool", versionArguments: ["--version"])

        #expect(found?.path == script.path)
        #expect(found?.version == SemanticVersion(9, 8, 7))
    }

    @Test("a non-executable file with the tool's name is not located")
    func nonExecutableFileIsNotATool() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locator-plain-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let file = dir.appendingPathComponent("sops")
        try "not a program".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        let locator = ToolLocator(searchPaths: [dir.path])
        #expect(await locator.locate("sops", versionArguments: ["--version"]) == nil)
    }

    @Test("the login-shell probe's own output is what populates the result, not just the fallback list")
    func loginShellProbeOutputIsActuallyUsed() throws {
        // The hardcoded fallback list already contains /opt/homebrew/bin,
        // /usr/local/bin, /usr/bin and /bin, so a test that only checks for
        // those cannot tell "the shell probe works" apart from "the shell
        // probe was deleted and only the fallback ran". Point SHELL at a
        // fake shell that prints a sentinel directory found nowhere in the
        // fallback list, and require that sentinel to show up in the result.
        // If the probe is deleted, or broken, the sentinel is absent and
        // this fails -- unlike loginShellPathIsRicherThanProcessPath above.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shellprobe-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let sentinelDir = dir.appendingPathComponent("sentinel-\(UUID().uuidString)").path
        let fakeShell = dir.appendingPathComponent("fakeshell")
        // Ignores its arguments entirely and always reports the sentinel PATH --
        // this is a stand-in for "$SHELL -lc 'echo $PATH'", not a real shell.
        try "#!/bin/sh\necho \"\(sentinelDir):/usr/bin:/bin\"\n".write(
            to: fakeShell, atomically: true, encoding: .utf8
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeShell.path)

        let originalShell = ProcessInfo.processInfo.environment["SHELL"]
        setenv("SHELL", fakeShell.path, 1)
        defer {
            if let originalShell {
                setenv("SHELL", originalShell, 1)
            } else {
                unsetenv("SHELL")
            }
        }

        let paths = ToolLocator.loginShellSearchPaths()

        #expect(paths.contains(sentinelDir))
    }

    @Test("drains output far larger than the pipe buffer without truncating or stalling until the timeout")
    func handlesOutputLargerThanPipeBuffer() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bigoutput-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let script = dir.appendingPathComponent("bigtool")
        // macOS pipe buffers are ~64 KB. A naive "wait for exit, then read"
        // capture deadlocks against this: the child blocks on write() once the
        // buffer fills and never exits, so the poll loop burns the full
        // timeout and the eventual read is truncated. Generated at runtime --
        // never commit a fixture this size.
        let scriptBody = """
        #!/bin/sh
        head -c 1048576 /dev/zero | tr '\\0' 'x'
        printf '\\nbigtool version 9.9.9\\n'
        """
        try scriptBody.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let locator = ToolLocator(searchPaths: [dir.path])

        let start = ContinuousClock.now
        let found = await locator.locate("bigtool", versionArguments: ["--version"])
        let elapsed = start.duration(to: .now)

        #expect(found?.version == SemanticVersion(9, 9, 9))
        #expect((found?.rawVersionOutput.utf8.count ?? 0) > 1_000_000)
        // This is the assertion that actually distinguishes a concurrent drain
        // from the broken read-after-wait shape: the fixed `capture()` returns
        // as soon as the child exits; the broken shape only returns once the
        // production 5 s timeout elapses, holding truncated output.
        //
        // The ceiling is 4 s, not the 2 s it was. 2 s is comfortable on an idle
        // machine and not comfortable under this suite's own parallelism — it
        // failed a full `xcrun swift test` run at 5.3 s wall for the test,
        // which is the whole suite competing for cores, not a stalled drain.
        // A wall-clock assertion that fires on machine load is the same defect
        // as the main-actor occupancy one, and this one was on the ledger for
        // two rounds. 4 s still sits below the 5 s timeout the broken shape
        // would have to wait out, so it keeps the discrimination it exists for,
        // and the two assertions above already prove nothing was truncated.
        #expect(elapsed < .seconds(4), Comment(rawValue: "capture() took \(elapsed)"))
    }
}
