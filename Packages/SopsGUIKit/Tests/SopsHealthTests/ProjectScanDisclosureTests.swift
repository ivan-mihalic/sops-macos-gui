import Foundation
import ScratchCleanup
import Testing
import SopsEngine
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func run(_ root: URL) async -> [HealthFinding] {
    await ProjectHealthCheck(source: Projects(
        projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()
}

private func leak(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix("gitignore") }!
}

private func recipients(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id.hasSuffix("stale-recipients") }!
}

/// M2 blocker 2, PROPOSAL.md §6 D: *"the check may not report OK about files
/// it did not look at"*, and, for the exclusion route specifically, the
/// exclusion *"must be stated in the finding, not buried in a constant"*.
///
/// The defect these tests pin: `ProjectScanner` skips `.build`, `.swiftpm`,
/// `node_modules` and friends on **every** walk, and `ProjectHealthCheck`
/// disclosed that fact in exactly one place — inside the `tree.wasTruncated`
/// branch of `recipientFinding`. A scan that skipped directories but never
/// came near the 20,000-file budget — the *normal* case, including this app
/// scanning its own repository — disclosed nothing at all, and the plaintext
/// finding said, in as many words:
///
///     Looked through <root> for plaintext files whose names conventionally
///     hold secrets (.env and its variants) and found none.
///
/// about a tree it had declined to enter parts of. That sentence is a verdict
/// on the whole project; the walk behind it was not.
///
/// Fixtures here are deliberately tiny — a handful of files in one excluded
/// directory, nowhere near the budget — because "budget not hit" is half of
/// what makes the bug reproduce. The one combination fixture that *does* cross
/// the budget is marked and is the expensive test in this suite.
@Suite("project scan scope disclosure")
struct ProjectScanDisclosureTests {

    /// A real git repository with a `.sops.yaml`, one genuinely encrypted file
    /// matching it, and `count` files inside each of `excluded` — so a scan
    /// finds real, verifiable content *and* declines to enter something.
    private func makeProject(excluded: [String], filesPerExcludedDir: Int = 3,
                             extraFiles: [String: String] = [:]) throws -> URL {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("db_password: hunter2\n", to: [key.public]),
                                 to: root, at: "secrets.yaml")
        for dir in excluded {
            for i in 0..<filesPerExcludedDir {
                try ProjectFixture.write("noise\n", to: root, at: "\(dir)/f\(i).txt")
            }
        }
        for (path, contents) in extraFiles {
            try ProjectFixture.write(contents, to: root, at: path)
        }
        return root
    }

    // MARK: - The case that actually bit: a clean scan that still skipped something

    /// The reproduction. Nothing is wrong with this project, the budget is
    /// nowhere near hit, and two directories were never entered. Before the
    /// fix the plaintext finding was a bare `.ok` naming no exclusion.
    @Test("a clean plaintext scan still says which directories it never entered")
    func cleanScanDisclosesTheExclusion() async throws {
        let root = try makeProject(excluded: [".build", ".swiftpm"])
        defer { try? FileManager.default.removeItem(at: root) }

        let findings = await run(root)
        let plaintext = leak(findings)

        // Sanity: this is the clean, well-under-budget case, not a truncated one.
        #expect(!plaintext.detail.contains("scan budget"))

        #expect(plaintext.detail.contains(".build"),
                "a finding over a walk that skipped .build must say so — got: \(plaintext.detail)")
        #expect(plaintext.detail.contains(".swiftpm"),
                "a finding over a walk that skipped .swiftpm must say so — got: \(plaintext.detail)")
        // `.git` is on the same exclusion list and is a real directory in a
        // real repository, so it is disclosed too — it is not a special case
        // that gets to stay silent. A token in `.git/config` is an ordinary
        // way to leak a credential.
        #expect(plaintext.detail.contains(".git"))
    }

    /// The same walk feeds the recipients finding, which has its own `.ok`
    /// branch — "Checked 1 encrypted file's recipient key list … it matches."
    /// That is a verdict about every encrypted file in the project, produced
    /// by a walk that skipped part of it.
    @Test("a clean recipients scan still says which directories it never entered")
    func cleanRecipientScanDisclosesTheExclusion() async throws {
        let root = try makeProject(excluded: [".build"])
        defer { try? FileManager.default.removeItem(at: root) }

        let finding = recipients(await run(root))

        #expect(finding.detail.contains("Checked 1 encrypted file"),
                "sanity: this fixture must reach the affirmative branch — got: \(finding.detail)")
        #expect(finding.detail.contains(".build"),
                "a recipients verdict over a partial walk must name the exclusion — got: \(finding.detail)")
    }

    /// The exclusion must reach the user on the branches that carry real bad
    /// news too — a `.problem` that names two exposed files is still a
    /// statement about a tree the walk only partly entered.
    @Test("the exposed-files problem branch also states the exclusion")
    func problemBranchDisclosesTheExclusion() async throws {
        let root = try makeProject(excluded: ["node_modules"],
                                   extraFiles: [".env": "STRIPE_KEY=sk_live_51H8xQ2abcdefg\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let plaintext = leak(await run(root))

        #expect(plaintext.status == .problem)
        #expect(plaintext.detail.contains("node_modules"))
        // Never the value, on any branch.
        #expect(!plaintext.detail.contains("sk_live_51H8xQ2abcdefg"))
    }

    /// And on the "candidates exist, git ignores all of them" `.ok` branch,
    /// which is a second, separate confident sentence over the same walk.
    @Test("the all-ignored ok branch also states the exclusion")
    func ignoredCandidatesBranchDisclosesTheExclusion() async throws {
        let root = try makeProject(excluded: ["vendor"],
                                   extraFiles: [".gitignore": ".env\n",
                                                ".env": "DB_PASSWORD=hunter2\n"])
        defer { try? FileManager.default.removeItem(at: root) }

        let plaintext = leak(await run(root))

        #expect(plaintext.status == .ok)
        #expect(plaintext.detail.contains("git ignores all of them"),
                "sanity: this fixture must reach the all-ignored branch — got: \(plaintext.detail)")
        #expect(plaintext.detail.contains("vendor"))
        #expect(!plaintext.detail.contains("hunter2"))
    }

    // MARK: - The status question, decided deliberately

    /// A skipped directory does **not** demote the finding to `.unknown`.
    ///
    /// This is a decision, not an oversight, and it is pinned here so a future
    /// change to it has to be deliberate too. `ProjectScanner`'s exclusion list
    /// applies to *every* walk this app will ever do — `.git` alone guarantees
    /// it fires on every real repository. If an exclusion demoted the status,
    /// every project finding in the app would be permanently `.unknown`, and a
    /// status that is always on carries no information: a genuine `.unknown`
    /// (offline, an unreadable PGP rule, no git binary) would be
    /// indistinguishable from the constant background. PROPOSAL.md §6 D itself
    /// separates the two routes — the exclusion route "must be stated in the
    /// finding", the *budget* route is the one that "degrad[es] to Unknown".
    /// The honesty invariant is satisfied by making the scope claim true, not
    /// by making the status useless.
    @Test("an exclusion is stated, not turned into an unknown")
    func exclusionDoesNotDemoteTheStatus() async throws {
        let root = try makeProject(excluded: [".build"])
        defer { try? FileManager.default.removeItem(at: root) }

        let findings = await run(root)

        #expect(leak(findings).status == .ok)
        #expect(recipients(findings).status == .ok)
    }

    /// The other half of that decision: truncation *is* different, and does
    /// demote. What an exclusion missed is named and bounded; what truncation
    /// missed is neither — the enumerator's order decides it and nothing can
    /// name it afterwards. The recipients finding already did this; the
    /// plaintext finding did not, and would happily report "found none" over a
    /// walk that stopped 200,000 files early.
    @Test("a truncated walk stops the plaintext finding reporting ok", .timeLimit(.minutes(5)))
    func truncationBlocksPlaintextOK() async throws {
        let root = try ProjectFixture.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(try ProjectFixture.ageKeyPair().public)\n",
                                 to: root, at: ".sops.yaml")
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(src)
        for i in 0..<(ProjectScanner.maxScannedFiles + 50) {
            try "x".write(to: src.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        // A `node_modules` sibling so this fixture is the *combination*: a walk
        // that both declined to enter something and ran out of budget.
        try ProjectFixture.write("LEAKED=1\n", to: root, at: "node_modules/leak.env")

        let plaintext = leak(await run(root))

        guard case .unknown(let reason) = plaintext.status else {
            Issue.record("a walk that stopped at its budget cannot report \(plaintext.status) about plaintext files")
            return
        }
        #expect(reason.contains("scan budget"))
        // Both facts reach the user, from one paragraph — see
        // `scopeIsOneStatementNotTwo` for the shape requirement.
        #expect(plaintext.detail.contains("node_modules"))
        #expect(plaintext.detail.contains("scan budget of \(ProjectScanner.maxScannedFiles)"))
    }

    // MARK: - The wording itself, at both extremes

    /// One excluded directory is named outright — no counting, no summary.
    @Test("a single excluded directory is named in full")
    func singleExclusionIsNamedInFull() throws {
        var tree = ScannedTree()
        tree.limitations = [.excludedDirectoryName("node_modules")]

        let scope = try #require(ProjectHealthCheck.scanScopeSentence(tree: tree))

        #expect(scope.contains("node_modules"))
        #expect(!scope.contains("more"), "one name needs no summary: \(scope)")
        #expect(!scope.contains("scan budget"))
    }

    /// Every name, up to the cap. A polyglot repository hitting five or six
    /// entries is ordinary and the reader wants all of them.
    @Test("a handful of excluded directories are all named")
    func severalExclusionsAreAllNamed() throws {
        var tree = ScannedTree()
        tree.limitations = ["node_modules", ".build", ".git", "vendor"].map(ScanLimitation.excludedDirectoryName)

        let scope = try #require(ProjectHealthCheck.scanScopeSentence(tree: tree))

        for name in tree.skippedDirectoryNames { #expect(scope.contains(name)) }
        #expect(!scope.contains("more"))
    }

    /// The other extreme: a project that manages to hit every entry on the
    /// exclusion list. The names stop being the information at that point and
    /// the count starts being it, so the sentence names the first
    /// `excludedNamesShown` in a deterministic order and says how many more
    /// there are — never a wall of twenty. The *count* is still exact: nothing
    /// about the size of the exclusion is hidden, only the tail of the list.
    @Test("many excluded directories are summarised rather than listed wholesale")
    func manyExclusionsAreSummarised() throws {
        let all = ProjectScanner.skippedDirectoryNames.sorted()
        #expect(all.count > ProjectHealthCheck.excludedNamesShown,
                "sanity: this test needs the real list to be longer than the cap")

        var tree = ScannedTree()
        tree.limitations = all.map(ScanLimitation.excludedDirectoryName)

        let scope = try #require(ProjectHealthCheck.scanScopeSentence(tree: tree))

        // Deterministic prefix, in sorted order.
        for name in all.prefix(ProjectHealthCheck.excludedNamesShown) {
            #expect(scope.contains(name), "expected \(name) named: \(scope)")
        }
        // The exact remainder, stated as a number.
        #expect(scope.contains("and \(all.count - ProjectHealthCheck.excludedNamesShown) more"),
                "expected an exact remainder count: \(scope)")
        // Not a wall: the sentence stays short enough to read.
        #expect(scope.count < 500, "scope sentence is \(scope.count) characters: \(scope)")
    }

    /// The combination must read as one account of what was missed, not as two
    /// separately-worded paragraphs the reader has to reconcile. Pinned
    /// structurally, not by taste: the scope disclosure opens with exactly one
    /// lead-in, and both facts hang off it.
    @Test("excluded and truncated is one statement, not two")
    func scopeIsOneStatementNotTwo() throws {
        var tree = ScannedTree()
        tree.limitations = [.excludedDirectoryName(".build"),
                            .excludedDirectoryName("node_modules"),
                            .budgetExhausted]

        let scope = try #require(ProjectHealthCheck.scanScopeSentence(tree: tree))

        #expect(scope.contains(".build"))
        #expect(scope.contains("node_modules"))
        #expect(scope.contains("scan budget of \(ProjectScanner.maxScannedFiles)"))
        // One lead-in, one paragraph.
        #expect(scope.components(separatedBy: ProjectHealthCheck.scopeLeadIn).count - 1 == 1,
                "the scope disclosure must be a single statement: \(scope)")
        #expect(!scope.contains("\n"), "the scope disclosure is one paragraph: \(scope)")
    }

    /// A walk that covered everything says nothing — the disclosure must not
    /// become boilerplate that appears on findings it does not apply to.
    @Test("a complete walk discloses nothing")
    func completeWalkHasNoScopeSentence() {
        #expect(ProjectHealthCheck.scanScopeSentence(tree: ScannedTree()) == nil)
    }

    /// A project whose directory is gone never walked anything, so there is no
    /// exclusion to disclose and the one honest finding must not grow a
    /// paragraph about directories it never reached.
    @Test("a missing project directory gets no scope paragraph")
    func missingRootHasNoScopeParagraph() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(root)

        let findings = await run(root)

        #expect(findings.count == 1)
        #expect(!findings[0].detail.contains(ProjectHealthCheck.scopeLeadIn))
    }

    // MARK: - Diagnostic

    /// Prints the findings this app produces for a real checkout — set
    /// `PROJECT_HEALTH_ROOT` to a directory to run it. Skipped otherwise, the
    /// same way `ProjectScanPerformanceTests.realRepositoryScanWallClock` is,
    /// so no other machine depends on a path only this one has. This is how
    /// the literal finding text quoted in the task report was obtained, rather
    /// than by transcribing it from the source.
    ///
    /// It asserts, rather than only printing. An opt-in test with no `#expect`
    /// at all is a test that cannot fail: run against a path that does not
    /// exist it passed happily, so the one time somebody sets the variable —
    /// the moment it is supposed to earn its keep — it would report success
    /// over a scan that never happened.
    @Test("real repository findings",
          .enabled(if: ProcessInfo.processInfo.environment["PROJECT_HEALTH_ROOT"] != nil),
          .timeLimit(.minutes(5)))
    func realRepositoryFindings() async throws {
        let path = ProcessInfo.processInfo.environment["PROJECT_HEALTH_ROOT"]!
        try #require(FileManager.default.fileExists(atPath: path),
                     "PROJECT_HEALTH_ROOT names a path that is not there")
        let clock = ContinuousClock()
        let scanStart = clock.now
        let tree = await ProjectScanner.scan(root: URL(fileURLWithPath: path))
        let scanElapsed = clock.now - scanStart
        let start = clock.now
        let findings = await run(URL(fileURLWithPath: path))
        let elapsed = clock.now - start

        // Names only, never contents — the same constraint the findings
        // themselves are held to.
        print("PROJECT_HEALTH_ROOT=\(path) scan=\(scanElapsed) fullCheck=\(elapsed)")
        print("SCAN skipped=\(tree.skippedDirectoryNames.sorted()) truncated=\(tree.wasTruncated)")
        print("SCAN encrypted(\(tree.encrypted.count)): \(tree.encrypted.map(\.url.lastPathComponent).sorted())")
        print("SCAN otherFormat(\(tree.encryptedInOtherFormats.count)): \(tree.encryptedInOtherFormats.map(\.lastPathComponent).sorted())")
        print("SCAN plaintext(\(tree.plaintextCandidates.count)): \(tree.plaintextCandidates.map(\.lastPathComponent).sorted())")
        for finding in findings {
            print("--- [\(finding.status)] \(finding.title)\n\(finding.detail)")
            if let remediation = finding.remediation {
                print("REMEDIATION: \(remediation.explanation)")
            }
        }

        #expect(!tree.rootMissing && !tree.rootUnreadable,
                "the scan never got into PROJECT_HEALTH_ROOT, so nothing printed above is an answer")
        #expect(!findings.isEmpty,
                "a real project produced no findings at all, which no code path should be able to do")
        for finding in findings {
            #expect(!finding.detail.isEmpty,
                    Comment(rawValue: "\(finding.title) has a status and no explanation"))
        }
    }
}
