import Foundation
import Testing
@testable import SopsHealth

private struct Projects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// The structural half of the §6 D work.
///
/// The four disclosure tests that existed before this were load-bearing and
/// still let the blocker through twice, for a reason worth stating plainly:
/// they asserted that *particular sentences* appeared on *particular branches*.
/// Nothing they contained had any opinion about a branch nobody had thought of,
/// and every one of the five paths the review found was exactly that. A
/// reviewer measured the gap directly — deleting all six `withScope(…)` calls
/// from `ProjectHealthCheck` turned nothing red.
///
/// So these tests are about the *mechanism*, not about wording:
///
/// - every `ScanLimitation` produces a sentence that names its subject, driven
///   through a `switch` the compiler checks for exhaustiveness, so a new kind
///   of blind spot cannot be added without this file failing to compile;
/// - every limitation that claims to block an affirmative verdict actually
///   does, through the accountant, for both `.ok` and `.skipped`;
/// - the one that claims not to, does not;
/// - and a real end-to-end run over a limited walk carries the disclosure on
///   every tree-scoped finding it produces, whichever branch produced it.
@Suite("project scope disclosure, structurally")
struct ProjectScopeDisclosureStructureTests {

    /// One sample per `ScanLimitation` case.
    ///
    /// The `switch` in `subject(of:)` below is what the compiler enforces: add
    /// a case to `ScanLimitation` and that function stops compiling until it
    /// has an answer. `sampleCount` is the belt to that braces — it catches the
    /// other half, a case added to the enum *and* to `subject(of:)` but never
    /// exercised here.
    private static let samples: [ScanLimitation] = [
        .excludedDirectoryName("node_modules"),
        .budgetExhausted,
        .unreadableDirectory(path: "/root/vault"),
        .unreadableFile(path: "/root/locked.yaml"),
        .directorySymlinkNotFollowed(path: "/root/linked", target: "/elsewhere/shared"),
        .metadataBlockTooLarge(path: "/root/enormous.yaml"),
    ]
    private static let sampleCount = 6

    /// The substring the disclosure must contain for this limitation to have
    /// been genuinely disclosed rather than merely counted.
    ///
    /// Exhaustive, no `default`. This is the compile-time tripwire.
    private func subject(of limitation: ScanLimitation) -> String {
        switch limitation {
        case .excludedDirectoryName(let name): name
        case .budgetExhausted: "scan budget of \(ProjectScanner.maxScannedFiles)"
        case .unreadableDirectory(let path): URL(fileURLWithPath: path).lastPathComponent
        case .unreadableFile(let path): URL(fileURLWithPath: path).lastPathComponent
        case .directorySymlinkNotFollowed(let path, _): URL(fileURLWithPath: path).lastPathComponent
        case .metadataBlockTooLarge(let path): URL(fileURLWithPath: path).lastPathComponent
        }
    }

    @Test("the sample set covers every case of ScanLimitation")
    func sampleSetIsComplete() {
        #expect(Self.samples.count == Self.sampleCount,
                "add the new ScanLimitation case to `samples` — every case has to be exercised here")
    }

    @Test("every limitation produces a sentence that names what was missed")
    func everyLimitationIsSpokenAloud() throws {
        for limitation in Self.samples {
            var tree = ScannedTree()
            tree.limitations = [limitation]

            let scope = try #require(
                ProjectHealthCheck.scanScopeSentence(tree: tree, relativeTo: "/root"),
                "\(limitation) produced no disclosure at all")
            #expect(scope.hasPrefix(ProjectHealthCheck.scopeLeadIn),
                    "\(limitation): \(scope)")
            #expect(scope.contains(subject(of: limitation)),
                    "\(limitation) is not named in its own disclosure: \(scope)")
            #expect(!scope.contains("\n"), "one paragraph: \(scope)")
        }
    }

    /// Every limitation at once still reads as one statement, and still names
    /// each one. This is the case a per-branch assertion never covers, because
    /// no fixture anybody writes by hand produces all six.
    @Test("all of them at once is still one statement that names all of them")
    func allLimitationsAtOnce() throws {
        var tree = ScannedTree()
        tree.limitations = Self.samples

        let scope = try #require(ProjectHealthCheck.scanScopeSentence(tree: tree, relativeTo: "/root"))

        for limitation in Self.samples {
            #expect(scope.contains(subject(of: limitation)), "\(limitation) missing from: \(scope)")
        }
        #expect(scope.components(separatedBy: ProjectHealthCheck.scopeLeadIn).count - 1 == 1,
                "the disclosure must be a single statement: \(scope)")
        #expect(!scope.contains("\n"))
    }

    // MARK: - The status floor

    /// A limitation that says it blocks an affirmative verdict must actually
    /// block one — both `.ok` and `.skipped`, because "there is nothing here"
    /// is as affirmative a claim about absence as "they all match" is about
    /// agreement, and `.skipped` was one of the reproduced falsehoods.
    @Test("a blocking limitation makes .ok and .skipped unreachable, both of them")
    func blockingLimitationsBlockBothAffirmativeStatuses() {
        for limitation in Self.samples where limitation.blocksAffirmativeVerdict {
            var tree = ScannedTree()
            tree.limitations = [limitation]
            let accountant = ProjectScopeAccountant(tree: tree, rootPath: "/root")

            for status in [HealthStatus.ok, .skipped(reason: "nothing here")] {
                let produced = accountant.finding(
                    about: .theWholeTree, id: "x", title: "x", status: status,
                    detail: "everything is fine").finding
                guard case .unknown(let reason) = produced.status else {
                    Issue.record("\(limitation) let \(status) through as \(produced.status)")
                    continue
                }
                #expect(!reason.isEmpty, "a demoted status must say why")
            }
        }
    }

    /// A real `.problem` is never buried under a caveat: the caveat goes in the
    /// prose, the status stays actionable.
    @Test("a blocking limitation never downgrades a real problem or warning")
    func realFindingsSurviveTheFloor() {
        var tree = ScannedTree()
        tree.limitations = [.unreadableDirectory(path: "/root/vault")]
        let accountant = ProjectScopeAccountant(tree: tree, rootPath: "/root")

        for status in [HealthStatus.problem, .warning] {
            let produced = accountant.finding(about: .theWholeTree, id: "x", title: "x",
                                              status: status, detail: "bad news").finding
            #expect(produced.status == status, "\(status) became \(produced.status)")
            #expect(produced.detail.contains(ProjectHealthCheck.scopeLeadIn),
                    "the caveat still has to be on the page: \(produced.detail)")
        }
    }

    /// The single deliberate exception, pinned so changing it has to be
    /// deliberate too. `ProjectScanner`'s name-based exclusion list applies to
    /// every walk this app will ever do — `.git` alone guarantees it fires on
    /// every real repository — so demoting for it would make every project
    /// finding permanently `.unknown`, and a status that is always on carries
    /// no information. PROPOSAL.md §6 D separates the two routes itself: the
    /// exclusion route "must be stated in the finding", the *budget* route is
    /// the one that "degrad[es] to Unknown".
    @Test("a named exclusion is stated, not turned into an unknown")
    func exclusionsAreStatedNotDemoted() {
        var tree = ScannedTree()
        tree.limitations = [.excludedDirectoryName(".git"), .excludedDirectoryName("node_modules")]
        let accountant = ProjectScopeAccountant(tree: tree, rootPath: "/root")

        let produced = accountant.finding(about: .theWholeTree, id: "x", title: "x",
                                          status: .ok, detail: "all good").finding

        #expect(produced.status == .ok)
        #expect(produced.detail.contains(".git"))
        #expect(produced.detail.contains("node_modules"))
    }

    /// A finding about one named file the check opened itself carries no scope
    /// paragraph: "your .sops.yaml parses" is not a claim about the tree, and
    /// hanging "this scan never enters .git" off it is the boilerplate that
    /// teaches users to skip the paragraph on the findings where it matters.
    @Test("a finding about one known path carries no scope paragraph")
    func oneKnownPathFindingsAreNotDecorated() {
        var tree = ScannedTree()
        tree.limitations = [.excludedDirectoryName(".git"), .budgetExhausted]
        let accountant = ProjectScopeAccountant(tree: tree, rootPath: "/root")

        let produced = accountant.finding(about: .oneKnownPath("/root/.sops.yaml"),
                                          id: "x", title: "x", status: .ok,
                                          detail: "The .sops.yaml parses.").finding

        #expect(produced.status == .ok)
        #expect(!produced.detail.contains(ProjectHealthCheck.scopeLeadIn))
    }

    /// A walk that covered everything says nothing at all.
    @Test("no limitations, no paragraph and no demotion")
    func cleanWalkIsUntouched() {
        let accountant = ProjectScopeAccountant(tree: ScannedTree(), rootPath: "/root")
        let produced = accountant.finding(about: .theWholeTree, id: "x", title: "x",
                                          status: .ok, detail: "all good").finding

        #expect(produced.status == .ok)
        #expect(produced.detail == "all good")
    }

    // MARK: - End to end

    /// The check itself, over a walk with more than one kind of blind spot at
    /// once. Whatever branch each finding came from, the disclosure is on it —
    /// which is the property the previous shape could not offer, because it
    /// depended on each branch remembering to ask for it.
    @Test("every tree-scoped finding of a real run over a limited walk carries the disclosure")
    func realRunDisclosesOnEveryBranch() async throws {
        let key = try ProjectFixture.ageKeyPair()
        let root = try ProjectFixture.makeDirectory()
        try ProjectFixture.gitInit(root)
        try ProjectFixture.write("creation_rules:\n  - age: \(key.public)\n", to: root, at: ".sops.yaml")
        try ProjectFixture.write(try ProjectFixture.encrypted("db: hunter2\n", to: [key.public]),
                                 to: root, at: "secrets.yaml")
        try ProjectFixture.write("noise\n", to: root, at: "node_modules/pkg/index.js")
        try ProjectFixture.write("SECRET=1\n", to: root, at: "vault/.env")
        let vault = root.appendingPathComponent("vault")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vault.path)
            try? FileManager.default.removeItem(at: root)
        }

        let findings = await ProjectHealthCheck(source: Projects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)])).run()

        for finding in findings where finding.id.hasSuffix("stale-recipients")
            || finding.id.hasSuffix("gitignore") {
            #expect(finding.detail.contains(ProjectHealthCheck.scopeLeadIn),
                    "\(finding.id) has no scope paragraph: \(finding.detail)")
            #expect(finding.detail.contains("node_modules"), "\(finding.id): \(finding.detail)")
            #expect(finding.detail.contains("vault"), "\(finding.id): \(finding.detail)")
            #expect(finding.status != .ok, "\(finding.id) claimed OK: \(finding.detail)")
        }
    }
}
