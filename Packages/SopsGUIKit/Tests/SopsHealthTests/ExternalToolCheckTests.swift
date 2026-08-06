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

    @Test("an absent recommended tool warns and offers an install command")
    func absentSopsWarns() async {
        let check = ExternalToolCheck(locator: FakeLocator(tools: [:]), embeddedSopsVersion: embedded)
        let sops = finding(await check.run(), "tool.sops")
        #expect(sops.status == .warning)
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
}
