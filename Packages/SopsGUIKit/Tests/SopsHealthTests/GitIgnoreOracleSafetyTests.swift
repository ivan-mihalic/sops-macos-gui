import Foundation
import ScratchCleanup
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
ScratchDirectoryRegistry.shared.register(repo)
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
ScratchDirectoryRegistry.shared.register(repo)
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

/// "git did not answer" and "git said no" must not produce the same sentence.
@Suite("An unreadable git answer is not reported as 'not a repository'")
struct GitIgnoreOracleVerdictTests {

    private static func makeFakeGit(_ script: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fakegit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let tool = dir.appendingPathComponent("git")
        try ("#!/bin/sh\n" + script + "\n").write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    /// A grandchild holding the pipe leaves `rev-parse`'s answer unreadable.
    /// The old `Bool` return made that indistinguishable from "false", so the
    /// app told the user a real repository was not one.
    @Test("an answer cut short is reported as undetermined, not as 'not a repository'")
    func truncatedAnswerIsNotAVerdict() throws {
        let git = try Self.makeFakeGit("""
            printf 'tru'
            sleep 20 &
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: git.path)

        guard case .undetermined(let reason) = verdict else {
            Issue.record("expected .undetermined, got \(verdict)")
            return
        }
        #expect(
            !reason.contains("not inside a git repository"),
            "an unreadable answer was reported as a confident verdict about the repository")
        #expect(reason.contains("did not finish"))
    }

    /// The other side: a genuine "no" must still say so, or the fix would have
    /// traded one wrong sentence for another. Ticket #8, claim 2: a genuine
    /// "no" is now `.noRepository`, not `.undetermined` — a definite fact,
    /// not a missing answer. See `GitIgnoreOracle.Verdict.noRepository`.
    @Test("a real 'not a repository' answer is a definite noRepository, not undetermined")
    func genuineOutsideAnswerIsPreserved() throws {
        let git = try Self.makeFakeGit("echo false; exit 1")
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: git.path)

        guard case .noRepository = verdict else {
            Issue.record("expected .noRepository, got \(verdict)")
            return
        }
    }

    /// The case where `outputComplete` is the only thing standing between a
    /// blocked read and a confident wrong answer: git exits non-zero — which
    /// on its own is a legitimate "outside a work tree" — while a grandchild
    /// keeps the pipe open, so we never learn whether it said anything.
    ///
    /// Without the completeness check the exit code alone decides, and the
    /// user is told "not inside a git repository" on the strength of a read
    /// that never finished.
    @Test("a non-zero exit with an unfinished read is undetermined, not 'outside'")
    func nonZeroExitWithBlockedReadIsUndetermined() throws {
        let git = try Self.makeFakeGit("""
            sleep 20 &
            exit 128
            """)
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: git.path)

        guard case .undetermined(let reason) = verdict else {
            Issue.record("expected .undetermined, got \(verdict)")
            return
        }
        #expect(
            reason.contains("did not finish"),
            "an exit code was treated as an answer although the read never completed")
    }
}

/// git failing is not git saying "this is not a repository".
@Suite("A failed git run is undetermined, not a verdict")
struct GitIgnoreOracleFailureTests {

    /// The real git binary, if one is installed.
    static let realGit: String? = ["/opt/homebrew/bin/git", "/usr/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static func fakeGit(_ script: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("failgit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let tool = dir.appendingPathComponent("git")
        try ("#!/bin/sh\n" + script + "\n").write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private func undeterminedReason(from git: URL) -> String? {
        let verdict = GitIgnoreOracle.classify(
            candidates: [], root: URL(fileURLWithPath: NSTemporaryDirectory()), gitPath: git.path)
        if case .undetermined(let reason) = verdict { return reason }
        return nil
    }

    /// Each of these exited non-zero for a reason that is not "outside a work
    /// tree", and each was reported as "not inside a git repository".
    @Test(
        "a git that fails for its own reasons does not become a verdict about the project",
        arguments: [
            ("permission denied", "echo \"fatal: cannot change to 'x': Permission denied\" >&2; exit 128"),
            ("root vanished", "echo \"fatal: cannot change to 'x': No such file or directory\" >&2; exit 128"),
            ("broken toolchain", "echo 'xcrun: error: invalid active developer path' >&2; exit 1"),
            ("dubious ownership", "echo 'fatal: detected dubious ownership in repository' >&2; exit 128"),
        ])
    func gitFailureIsNotAVerdict(_ scenario: (name: String, script: String)) throws {
        let git = try Self.fakeGit(scenario.script)
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let reason = try #require(undeterminedReason(from: git), "expected .undetermined for \(scenario.name)")
        #expect(
            !reason.contains("not inside a git repository"),
            "\(scenario.name) was reported as a confident verdict about the repository")
    }

    /// Removed as a separate case: its fixture was
    /// `fatal: not a git repository` with no path, which real git never prints
    /// for `rev-parse --is-inside-work-tree`. It was the only guard on
    /// `.outside`, and it guarded a string that cannot occur.
    /// `plainDirectoryIsReportedAsOutside` above replaces it with the wording
    /// git actually uses.


    /// The same two cases against the **real** git binary, because the fixtures
    /// above encode my reading of what git prints — and iteration 10 got that
    /// reading exactly backwards, classifying the canonical "not a repository"
    /// message as a git malfunction.
    @Test(
        "real git: a plain directory reads as outside, a damaged one as undetermined",
        .enabled(if: Self.realGit != nil, "git is required"))
    func realGitAgreesWithTheFixtures() throws {
        let git = try #require(Self.realGit)

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("realgit-\(UUID().uuidString)")
        let plain = sandbox.appendingPathComponent("plain")
        let damaged = sandbox.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(plain)
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(damaged)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        Self.run(git, ["-C", damaged.path, "init", "-q", "."])
        try? FileManager.default.removeItem(at: damaged.appendingPathComponent(".git/refs"))
        try? FileManager.default.removeItem(at: damaged.appendingPathComponent(".git/HEAD"))

        guard case .noRepository =
            GitIgnoreOracle.classify(candidates: [], root: plain, gitPath: git) else {
            Issue.record("expected .noRepository for a plain directory")
            return
        }

        guard case .undetermined(let damagedReason) =
            GitIgnoreOracle.classify(candidates: [], root: damaged, gitPath: git) else {
            Issue.record("expected .undetermined for a damaged repository")
            return
        }
        #expect(
            !damagedReason.contains("not inside a git repository"),
            "a repository with a damaged .git was reported as not being one")
    }

    /// The regression iteration 11 introduced while fixing the swap: the `.git`
    /// discriminator looked only in `root`. Git prints "not a git repository
    /// (or any of the parent directories)" from *anywhere inside* a repository
    /// whose `.git` is damaged, and a project is very often a subdirectory —
    /// so the app went back to the confident, false "this project is not
    /// inside a git repository", with the gitignore check silently dropped on
    /// the strength of it. The previous round's own tests could not see this:
    /// both built `.git` directly in `root`.
    @Test(
        "real git: a damaged repository is undetermined from a subdirectory too",
        .enabled(if: GitIgnoreOracleFailureTests.realGit != nil, "git is required"))
    func realGitDamagedRepositorySeenFromASubdirectory() throws {
        let git = try #require(Self.realGit)

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("realgit-sub-\(UUID().uuidString)")
        let repository = sandbox.appendingPathComponent("repo")
        let project = repository.appendingPathComponent("services/config")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(project)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        Self.run(git, ["-C", repository.path, "init", "-q", "."])
        try? FileManager.default.removeItem(at: repository.appendingPathComponent(".git/refs"))
        try? FileManager.default.removeItem(at: repository.appendingPathComponent(".git/HEAD"))

        try #require(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".git").path),
                     "the project directory has its own .git — this test would not exercise the walk upward")

        guard case .undetermined(let reason) =
            GitIgnoreOracle.classify(candidates: [], root: project, gitPath: git) else {
            Issue.record("expected .undetermined for a project inside a damaged repository")
            return
        }
        #expect(
            !reason.contains("not inside a git repository"),
            "a project inside a damaged repository was told it is not in a repository at all")
    }

    /// The other side of the same walk: a plain directory nested several levels
    /// under no repository at all must still read as outside, not as a git
    /// malfunction. Without this, "walk up until you find a .git" could be
    /// satisfied by never finding one and always answering `.unreadable`.
    @Test(
        "real git: a deeply nested plain directory still reads as outside",
        .enabled(if: GitIgnoreOracleFailureTests.realGit != nil, "git is required"))
    func realGitNestedPlainDirectoryIsStillOutside() throws {
        let git = try #require(Self.realGit)

        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("realgit-plain-\(UUID().uuidString)")
        let nested = sandbox.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(nested)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        guard case .noRepository =
            GitIgnoreOracle.classify(candidates: [], root: nested, gitPath: git) else {
            Issue.record("expected .noRepository for a plain nested directory")
            return
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    /// A linked worktree whose main clone is unreachable says
    /// `fatal: not a git repository: (null)` — the phrase, meaning the
    /// opposite. This project groups worktrees in the sidebar, so it is
    /// precisely the case that must not become a verdict.
    @Test("a worktree with an unreachable main repository is undetermined")
    func orphanedWorktreeIsNotAVerdict() throws {
        let git = try Self.fakeGit("echo 'fatal: not a git repository: (null)' >&2; exit 128")
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let reason = try #require(undeterminedReason(from: git))
        #expect(
            !reason.contains("not inside a git repository"),
            "an orphaned worktree was reported as not being in a repository at all")
    }

    /// A damaged `.git` gives the **same** message as being outside a
    /// repository — measured, both are
    /// `fatal: not a git repository (or any of the parent directories): .git`.
    /// The filesystem is the only discriminator, so this fixture provides a
    /// real `.git` directory and expects "we could not tell", not a verdict.
    @Test("a damaged repository is undetermined, not 'outside'")
    func damagedRepositoryIsNotAVerdict() throws {
        let git = try Self.fakeGit(
            "echo 'fatal: not a git repository (or any of the parent directories): .git' >&2; exit 128")
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("damaged-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: git.path)
        guard case .undetermined(let reason) = verdict else {
            Issue.record("expected .undetermined, got \(verdict)")
            return
        }
        #expect(
            !reason.contains("not inside a git repository"),
            "a repository with a damaged .git was reported as not being one")
    }

    /// The case iteration 10 made unreachable: an ordinary directory that is
    /// simply not in a repository. For a secrets GUI that is a common, normal
    /// state, and it must read as itself rather than as a git malfunction —
    /// and, per ticket #8 claim 2, as a definite `.noRepository`, not an
    /// "unknown" this app can never resolve for a project with no git at all.
    @Test("an ordinary non-repository directory is reported as exactly that")
    func plainDirectoryIsReportedAsOutside() throws {
        let git = try Self.fakeGit(
            "echo 'fatal: not a git repository (or any of the parent directories): .git' >&2; exit 128")
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        defer { try? FileManager.default.removeItem(at: root) }

        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: git.path)
        guard case .noRepository = verdict else {
            Issue.record("expected .noRepository, got \(verdict) — a plain directory was reported as git failing to answer, sending the user to debug a toolchain problem that does not exist")
            return
        }
    }

    /// stdout complete, stderr held open by a grandchild: the answer was read
    /// in full, so it must be used. Iteration 7's single flag rejected it.
    @Test("a complete stdout answer is used even when a grandchild holds stderr")
    func stderrBlockedDoesNotDiscardTheAnswer() throws {
        // `>/dev/null` only, deliberately: with `2>&1` the grandchild holds
        // neither pipe (measured: stderr EOF in 14 ms) and this test cannot
        // fail on the bug it names. Verified by mutation — restoring
        // iteration 7's combined flag left the whole suite green with the
        // two-redirect fixture, and reddens this one.
        let git = try Self.fakeGit("""
            echo true
            sleep 20 >/dev/null &
            exit 0
            """)
        defer { try? FileManager.default.removeItem(at: git.deletingLastPathComponent()) }

        let verdict = GitIgnoreOracle.classify(
            candidates: [], root: URL(fileURLWithPath: NSTemporaryDirectory()), gitPath: git.path)
        if case .undetermined(let reason) = verdict {
            Issue.record("a fully-read 'true' was discarded: \(reason)")
        }
    }
}

/// Ticket #8, claim 2: a project with no `.git` at all used to be
/// `.undetermined` forever, both when git said so and when git was not even
/// installed. These pin the `.noRepository` verdict on both routes there —
/// through a real git binary, and through the pure-filesystem fallback that
/// answers the same question without one.
@Suite("A project with no git repository at all gets a definite answer")
struct GitIgnoreOracleNoRepositoryTests {

    /// The real git binary, if one is installed.
    static let realGit: String? = ["/opt/homebrew/bin/git", "/usr/bin/git", "/usr/local/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    private static func makeDirectory(_ label: String) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        ScratchDirectoryRegistry.shared.register(root)
        return root
    }

    /// The real git binary, on an ordinary directory with no `.git` anywhere
    /// above it — the common case for anyone who has not yet run `git init`.
    @Test("real git, no repository: noRepository, not undetermined",
          .enabled(if: Self.realGit != nil, "git is required"))
    func realGitNoRepository() throws {
        let git = try #require(Self.realGit)
        let root = try Self.makeDirectory("no-repo")

        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: git)
        guard case .noRepository = verdict else {
            Issue.record("expected .noRepository, got \(verdict)")
            return
        }
    }

    /// No git binary at all, and no `.git` anywhere above `root` either — a
    /// pure filesystem question this app can still answer honestly without
    /// git installed. Before this, a machine with no git told every project
    /// "git was not found … it never guesses", forever, even about a project
    /// that plainly has no repository to guess about.
    @Test("no git binary, no .git anywhere: noRepository, not 'git was not found'")
    func noGitBinaryNoRepository() throws {
        let root = try Self.makeDirectory("no-git-no-repo")

        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: nil)
        guard case .noRepository = verdict else {
            Issue.record("expected .noRepository, got \(verdict)")
            return
        }
    }

    /// No git binary, but a `.git` genuinely exists above `root` — this app
    /// cannot tell whether it is healthy, damaged, or even the right kind of
    /// repository without git to ask, so this must stay `.undetermined`
    /// rather than guessing either `.answered` or `.noRepository`.
    @Test("no git binary, but a .git exists: still undetermined")
    func noGitBinaryButRepositoryExists() throws {
        let root = try Self.makeDirectory("no-git-has-repo")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)

        let verdict = GitIgnoreOracle.classify(candidates: [], root: root, gitPath: nil)
        guard case .undetermined(let reason) = verdict else {
            Issue.record("expected .undetermined, got \(verdict)")
            return
        }
        #expect(reason.contains("git was not found"))
    }
}
