import Testing
@testable import SopsHealth

private struct FakeLocator: ToolLocating {
    var tools: [String: LocatedTool]
    func locate(_ name: String, versionArguments: [String]) async -> LocatedTool? { tools[name] }
}

private func tool(_ name: String, _ version: SemanticVersion?) -> LocatedTool {
    LocatedTool(name: name, path: "/opt/homebrew/bin/\(name)",
                version: version, rawVersionOutput: version.map(\.description) ?? "")
}

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

@Suite("ExternalToolCheck")
struct ExternalToolCheckTests {
    private let embedded = SemanticVersion(3, 13, 3)

    @Test("a sops CLI older than the embedded engine is a warning with an upgrade command")
    func staleSopsWarns() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["sops": tool("sops", SemanticVersion(3, 13, 2))]),
            embeddedSopsVersion: embedded)

        let sops = finding(await check.run(), "tool.sops")
        #expect(sops.status == .warning)
        #expect(sops.remediation?.command == "brew upgrade sops")
        #expect(sops.detail.contains("3.13.2"))
        #expect(sops.detail.contains("3.13.3"))
    }

    @Test("a sops CLI at or above the embedded engine is OK")
    func currentSopsIsOK() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["sops": tool("sops", SemanticVersion(3, 13, 3))]),
            embeddedSopsVersion: embedded)
        #expect(finding(await check.run(), "tool.sops").status == .ok)
    }

    // yq v3 accepts `-o=props` silently but produces different output, so the
    // Help snippet in PROPOSAL.md §5 would generate a wrong .env file.
    @Test("yq v3 is a problem, not a warning")
    func yqV3IsAProblem() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["yq": tool("yq", SemanticVersion(3, 4, 1))]),
            embeddedSopsVersion: embedded)

        let yq = finding(await check.run(), "tool.yq")
        #expect(yq.status == .problem)
        #expect(yq.remediation?.command == "brew upgrade yq")
    }

    @Test("an absent optional tool is informational, not a failure")
    func absentDockerIsSkipped() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let docker = finding(await check.run(), "tool.docker")
        if case .skipped = docker.status {} else {
            Issue.record("docker absence should be skipped, got \(docker.status)")
        }
    }

    // Ticket #14: this check used to warn on every missing tool because the
    // header framed all five as mattering for "the Help section" — a surface
    // that does not exist anywhere in the app (no menu item, no view). With
    // nowhere to send the user, a missing tool is not something they can act
    // on from here, so it must not be able to degrade the report's headline
    // status the way a real, actionable warning does. See
    // `HealthReport.worstStatus` and `ExternalToolCheck`'s header comment.
    @Test("an absent tool is informational, not a warning, because there is nowhere in the app to send the user")
    func absentSopsIsInformational() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let sops = finding(await check.run(), "tool.sops")
        if case .skipped = sops.status {} else {
            Issue.record("sops absence should be skipped, got \(sops.status)")
        }
        #expect(sops.remediation?.command == "brew install sops")
    }

    @Test("a tool whose version cannot be parsed is unknown, never wrongly OK")
    func unparseableVersionIsUnknown() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["git": tool("git", nil)]),
            embeddedSopsVersion: embedded)
        let git = finding(await check.run(), "tool.git")
        if case .unknown = git.status {} else {
            Issue.record("unparseable version should be unknown, got \(git.status)")
        }
    }

    @Test("no remediation command ever mutates the system on the app's behalf")
    func remediationsAreCopyOnly() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        for finding in await check.run() {
            guard let command = finding.remediation?.command else { continue }
            #expect(!command.contains("sudo"))
            #expect(command.hasPrefix("brew "))
        }
    }

    @Test("reports on every tool the proposal lists")
    func coversAllTools() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let ids = Set((await check.run()).map(\.id))
        #expect(ids == ["tool.sops", "tool.age", "tool.git", "tool.yq", "tool.docker"])
    }

    // I5. PROPOSAL.md §6 A: "git — warn below 2.30", and failure is reserved
    // for yq v3. Old git used to be a .problem while *absent* git was only a
    // .warning, which ranked a missing tool as less serious than a stale one.
    @Test("git below 2.30 warns rather than failing")
    func oldGitWarns() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["git": tool("git", SemanticVersion(2, 20, 0))]),
            embeddedSopsVersion: embedded)
        #expect(finding(await check.run(), "tool.git").status == .warning)
    }

    // Ticket #14 reverses this on purpose. The original test (I5) guarded
    // against a missing tool ranking *below* a stale one — written when
    // absence was a `.warning`. Now absence is deliberately informational
    // (see `absentSopsIsInformational`): there is no Help surface to point a
    // user at, so "you don't have this at all" carries no actionable signal.
    // A *present but outdated* tool is a different claim — if you do use it,
    // running the app's own snippet-shaped commands against it may behave
    // differently — and that stays a real `.warning`. So a stale git must now
    // rank strictly *above* an absent one, not merely not-below it.
    @Test("an outdated git is rated more serious than an absent one")
    func oldGitOutranksAbsentGit() async {
        let absent = finding(
            await ExternalToolCheck(locator: FakeLocator(tools: [:]),
                                    embeddedSopsVersion: embedded).run(), "tool.git")
        let old = finding(
            await ExternalToolCheck(
                locator: FakeLocator(tools: ["git": tool("git", SemanticVersion(2, 20, 0))]),
                embeddedSopsVersion: embedded).run(), "tool.git")

        #expect(old.status.severity > absent.status.severity,
                "outdated git (\(old.status)) should outrank absent git (\(absent.status))")
    }

    @Test("yq stays the only tool that can fail outright")
    func onlyYQCanFail() async {
        // Every tool at an implausibly ancient version; only yq may be a
        // .problem, because only yq silently produces wrong output.
        let ancient = SemanticVersion(0, 1, 0)
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: Dictionary(uniqueKeysWithValues:
                ["sops", "age", "git", "yq", "docker"].map { ($0, tool($0, ancient)) })),
            embeddedSopsVersion: embedded)

        for finding in await check.run() where finding.status == .problem {
            #expect(finding.id == "tool.yq", "\(finding.id) must not be a problem: \(finding.detail)")
        }
    }

    // The header of ExternalToolCheck.swift says none of these tools are
    // needed for the app to work — the engine is compiled in. "the minimum
    // this app supports" contradicted that in the app's own voice.
    @Test("no finding claims a tool is a minimum the app supports")
    func copyDoesNotContradictTheChecksOwnPremise() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["yq": tool("yq", SemanticVersion(3, 4, 1))]),
            embeddedSopsVersion: embedded)
        for finding in await check.run() {
            #expect(!finding.detail.lowercased().contains("minimum"),
                    "\(finding.id): \(finding.detail)")
        }
    }

    // The row renders a skip reason and the detail back to back, so identical
    // text appears twice on screen.
    @Test("a skipped tool's reason and detail do not say the same thing")
    func skipReasonAndDetailAreNotDuplicated() async {
        let docker = finding(
            await ExternalToolCheck(locator: FakeLocator(tools: [:]),
                                    embeddedSopsVersion: embedded).run(), "tool.docker")
        guard case .skipped(let reason) = docker.status else {
            Issue.record("expected skipped, got \(docker.status)")
            return
        }
        #expect(reason != docker.detail)
        #expect(!docker.detail.contains(reason))
        #expect(!reason.contains(docker.detail))
    }

    // I2. An embedded sops version the bridge could not report is not a
    // version. Substituting 0.0.0 made every installed sops look current, so
    // "warn if the CLI is older than the engine" silently became "always OK".
    @Test("an unknown embedded sops version does not silently pass the CLI comparison")
    func unknownEmbeddedVersionIsDisclosed() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: ["sops": tool("sops", SemanticVersion(3, 0, 0))]),
            embeddedSopsVersion: nil)

        let sops = finding(await check.run(), "tool.sops")
        #expect(!sops.detail.contains("0.0.0"))
        // The comparison did not happen, and the copy says so rather than
        // letting a silent pass read as a pass.
        #expect(sops.detail.lowercased().contains("could not determine"))
    }

    // Ticket #14, acceptance criterion 1: no combination of missing tools may
    // degrade `HealthReport`'s headline. `ExternalToolCheck` can only inform
    // that outcome by never handing back anything worse than `.skipped` for a
    // tool that simply isn't there — this proves the whole check does exactly
    // that when every one of the five is absent at once, which used to make
    // the headline `.warning` on a machine with none of them installed.
    @Test("every tool missing at once never produces a warning-or-worse headline")
    func allToolsMissingNeverDegradesHeadline() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let findings = await check.run()
        let headline = HealthReport.worstStatus(in: findings)
        #expect(headline.severity < HealthStatus.warning.severity,
                "headline over an all-missing tool set was \(headline)")
    }

    // Ticket #14: the check used to justify all five tools by pointing at
    // "the Help section", which does not exist anywhere in the app yet (no
    // menu item, no view — see the header comment's rewrite). Nothing this
    // check produces may still make that claim.
    @Test("no finding or purpose text points at a Help section that does not exist")
    func noFindingMentionsHelp() async {
        let check = ExternalToolCheck(
            locator: FakeLocator(tools: [
                "sops": tool("sops", SemanticVersion(3, 0, 0)),
                "yq": tool("yq", SemanticVersion(3, 4, 1)),
            ]),
            embeddedSopsVersion: embedded)
        for finding in await check.run() {
            let text = (finding.detail + (finding.remediation?.explanation ?? "")).lowercased()
            #expect(!text.contains("help"), "\(finding.id) still points at Help: \(text)")
        }
    }
}
