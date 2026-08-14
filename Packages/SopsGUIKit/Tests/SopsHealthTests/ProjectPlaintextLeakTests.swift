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

/// PROPOSAL.md §6 D: "plaintext secret files **inside the repo** that are not
/// gitignored".
///
/// Every fixture here is a real `git init` repository and every expectation is
/// anchored to what a real `git check-ignore` says about it, because the bug
/// this suite exists to prevent was an app that disagreed with git in both
/// directions at once: a green "No unignored plaintext secret files found."
/// printed over a live `sk_live_…`, and a red "…are not gitignored" printed
/// over a file git demonstrably ignores.
@Suite("ProjectHealthCheck plaintext leak guard")
struct ProjectPlaintextLeakTests {

    /// C3, direction one — the worst output in the whole report. A Stripe live
    /// key in a subdirectory, a second secret file at the root, and no
    /// `.gitignore` anywhere. Everything here is exposed.
    @Test("a secret in a subdirectory with no .gitignore at all is a problem, not an OK")
    func secretsInSubdirectoriesWithNoGitignoreAreExposed() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: "services/api/.env")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: root, at: ".env.staging")

        let leak = leakFinding(await run(root))

        #expect(leak.status == .problem)
        #expect(leak.detail.contains("services/api/.env"))
        #expect(leak.detail.contains(".env.staging"))
        // A finding is exactly the kind of text that gets screenshotted.
        #expect(!leak.detail.contains("sk_live_51H8xQ2abcdefg"))
        #expect(!leak.detail.contains("hunter2"))
    }

    /// C3, direction two — a false alarm. `git check-ignore` says `.env` is
    /// ignored by `.env*`; the app must agree, and must not offer to append a
    /// line that is already covered.
    @Test("a wildcard .gitignore pattern is honoured exactly as git honours it",
          arguments: [".env*", "*.env", "/.env", "**/.env", ".env\n.env.*"])
    func gitignorePatternFormsAreHonoured(pattern: String) async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write(pattern + "\n", to: root, at: ".gitignore")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: root, at: ".env")

        // The oracle: ask git directly, then require the app to match it.
        let git = try ProjectFixture.gitPath()
        let ignoredByGit = (try? ProjectFixture.run(
            git, ["-C", root.path, "check-ignore", "--", root.appendingPathComponent(".env").path])) != nil

        let leak = leakFinding(await run(root))
        if ignoredByGit {
            #expect(leak.status == .ok, "git ignores .env under \(pattern); the app reported \(leak.status)")
        } else {
            #expect(leak.status == .problem, "git does not ignore .env under \(pattern); the app reported \(leak.status)")
        }
    }

    /// A `.gitignore` in a parent directory governs a subdirectory. Only git
    /// knows this; an exact-line scan of the project root cannot.
    @Test("a parent directory's .gitignore is honoured")
    func parentGitignoreIsHonoured() async throws {
        let repo = try ProjectFixture.makeDirectory("repo")
        try ProjectFixture.gitInit(repo)
        try ProjectFixture.write("*.env\n.env\n", to: repo, at: ".gitignore")

        let project = repo.appendingPathComponent("packages/service")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: project, at: ".sops.yaml")
        try ProjectFixture.write("DB_PASSWORD=hunter2\n", to: project, at: ".env")

        #expect(leakFinding(await run(project)).status == .ok)
    }

    /// A file that is already committed is not "ignored" no matter what
    /// patterns exist — git itself reports it as not ignored. The app must
    /// therefore call it out, and must not tell the user that appending a
    /// gitignore line fixes it.
    @Test("a plaintext secret already tracked by git is a problem even when a matching ignore pattern exists")
    func trackedSecretIsStillAProblem() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write(".env\n", to: root, at: ".gitignore")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: ".env")
        try ProjectFixture.gitAdd(root, ".env")

        let leak = leakFinding(await run(root))
        #expect(leak.status == .problem)
        #expect(leak.detail.contains(".env"))
        #expect(!leak.detail.contains("sk_live_51H8xQ2abcdefg"))
        #expect(leak.remediation?.explanation.lowercased().contains("rotat") == true)
    }

    /// A `.env` that is genuinely sops-encrypted is not a plaintext leak. The
    /// old check would have flagged it purely on its name.
    @Test("a sops-encrypted .env is not reported as a plaintext leak")
    func encryptedDotEnvIsNotALeak() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("DB_PASSWORD: hunter2\n", to: [key.public]),
                                 to: root, at: ".env")

        #expect(leakFinding(await run(root)).status == .ok)
    }

    /// Committed placeholder files are the conventional way to document which
    /// variables exist. Flagging them is noise that trains users to ignore
    /// this finding.
    @Test("committed placeholder files are not treated as secrets",
          arguments: [".env.example", ".env.sample", ".env.template", ".env.dist"])
    func placeholderFilesAreNotSecrets(name: String) async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("DB_PASSWORD=\n", to: root, at: name)

        #expect(leakFinding(await run(root)).status == .ok)
    }

    /// No git repository means the ignore rules cannot be evaluated — but,
    /// per ticket #8 claim 2, "not inside a git repository" is a *definite*
    /// fact `GitIgnoreOracle` can establish, not a missing answer. A project
    /// with no git at all used to be stuck at `.unknown` on this finding
    /// forever; it is now an honest `.warning` that says exactly that: none
    /// of these files can be committed to a repository by accident, because
    /// there is no repository, though they are still on disk unencrypted.
    @Test("outside a git repository the check gives a definite warning, not unknown")
    func nonRepositoryIsAWarningNotUnknown() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: ".env")

        let leak = leakFinding(await run(root))
        #expect(leak.status == .warning)
        #expect(leak.detail.contains("not inside a git repository"))
        // It still names the file it found, which is the useful half.
        #expect(leak.detail.contains(".env"))
        #expect(!leak.detail.contains("sk_live_51H8xQ2abcdefg"))
    }

    /// Without git there is no oracle, so there is no verdict. The check must
    /// not fall back to a home-grown matcher — that is what produced C3.
    @Test("with no usable git binary the check reports unknown rather than guessing")
    func missingGitIsUnknown() async throws {
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: ".env")

        let check = ProjectHealthCheck(
            source: Projects(projects: [InspectedProject(name: "demo", rootPath: root.path)]),
            locator: NoToolsLocator())

        let leak = leakFinding(await check.run())
        guard case .unknown(let reason) = leak.status else {
            Issue.record("expected .unknown with no git available, got \(leak.status)")
            return
        }
        #expect(reason.lowercased().contains("git"))
    }

    /// The check is read-only. Running it must not create, modify or stage
    /// anything — `git status` before and after must be identical.
    @Test("the check never mutates the repository")
    func checkIsReadOnly() async throws {
        let root = try ProjectFixture.makeDirectory()
        let git = try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        try ProjectFixture.write("STRIPE_KEY=sk_live_51H8xQ2abcdefg\n", to: root, at: ".env")

        let before = try ProjectFixture.run(git, ["-C", root.path, "status", "--porcelain"])
        _ = await run(root)
        let after = try ProjectFixture.run(git, ["-C", root.path, "status", "--porcelain"])

        #expect(before == after)
    }
}

/// A locator that finds nothing, for proving the no-git path.
struct NoToolsLocator: ToolLocating {
    func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? { nil }
}
