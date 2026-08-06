import Foundation

/// PROPOSAL.md §6 A. None of these tools are needed for the app to work — the
/// SOPS engine is compiled into the app and runs in-process. They matter
/// because the Help section gives the user snippets to run in their own
/// terminal and in CI, against the same files this app writes. A missing
/// tool is information, not an emergency — except `yq` below v4, which
/// accepts the `-o=props` syntax our snippet uses but silently produces
/// different output, which would generate a wrong `.env` file.
public struct ExternalToolCheck: HealthCheck {
    public let id = "external-tools"
    public let category = HealthCategory.tools

    struct Requirement: Sendable {
        let name: String
        let findingID: String
        let title: String
        /// Lowercase clause, no trailing period: "used for <purpose>".
        let purpose: String
        /// Below this, the tool is wrong rather than merely old.
        let hardFloor: SemanticVersion?
        /// Extra sentence appended when `hardFloor` is breached, explaining
        /// *why* the old version is actively wrong rather than just stale.
        let hardFloorConsequence: String?
        /// Below this, the tool still works but should be updated.
        let softFloor: SemanticVersion?
        /// How to describe `softFloor` in the warning, e.g. "the version
        /// built into this app" for sops, vs. nil for a plain recommendation.
        let softFloorContext: String?
        /// Absence is informational rather than a warning.
        let optional: Bool
        let versionArguments: [String]
        let formula: String
    }

    private let locator: any ToolLocating
    private let embeddedSopsVersion: SemanticVersion

    public init(locator: any ToolLocating, embeddedSopsVersion: SemanticVersion) {
        self.locator = locator
        self.embeddedSopsVersion = embeddedSopsVersion
    }

    private var requirements: [Requirement] {
        [
            Requirement(
                name: "sops", findingID: "tool.sops", title: "sops CLI",
                purpose: "decrypting these files in your terminal and in CI",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: embeddedSopsVersion, softFloorContext: "the version built into this app",
                optional: false, versionArguments: ["--version"], formula: "sops"),
            Requirement(
                name: "age", findingID: "tool.age", title: "age",
                purpose: "generating age keys outside this app, e.g. on a server",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: SemanticVersion(1, 3, 0), softFloorContext: nil,
                optional: false, versionArguments: ["--version"], formula: "age"),
            Requirement(
                name: "git", findingID: "tool.git", title: "git",
                purpose: "worktree detection and commit hygiene",
                hardFloor: SemanticVersion(2, 30, 0), hardFloorConsequence: nil,
                softFloor: nil, softFloorContext: nil,
                optional: false, versionArguments: ["--version"], formula: "git"),
            Requirement(
                name: "yq", findingID: "tool.yq", title: "yq",
                purpose: "generating a .env file from these secrets",
                hardFloor: SemanticVersion(4, 0, 0),
                hardFloorConsequence: "Its -o=props syntax accepts versions below v4 silently but produces different output there, which would generate a wrong .env file.",
                softFloor: nil, softFloorContext: nil,
                optional: false, versionArguments: ["--version"], formula: "yq"),
            Requirement(
                name: "docker", findingID: "tool.docker", title: "Docker",
                purpose: "running the docker-compose snippets in Help",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: nil, softFloorContext: nil,
                optional: true, versionArguments: ["--version"], formula: "docker"),
        ]
    }

    public func run() async -> [HealthFinding] {
        await withTaskGroup(of: HealthFinding.self) { group in
            for requirement in requirements {
                group.addTask { await evaluate(requirement) }
            }
            var findings: [HealthFinding] = []
            for await finding in group { findings.append(finding) }
            return findings
        }
    }

    private func evaluate(_ requirement: Requirement) async -> HealthFinding {
        guard let located = await locator.locate(requirement.name,
                                                   versionArguments: requirement.versionArguments) else {
            let install = Remediation(
                explanation: "Install it with Homebrew, then re-run this check.",
                command: "brew install \(requirement.formula)")
            if requirement.optional {
                return HealthFinding(
                    id: requirement.findingID, title: requirement.title,
                    status: .skipped(reason: "\(requirement.title) is not installed. It's only needed for \(requirement.purpose)."),
                    detail: "\(requirement.title) was not found on this machine. It's only needed for \(requirement.purpose).",
                    remediation: install)
            }
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .warning,
                detail: "\(requirement.title) was not found on this machine. It's used for \(requirement.purpose).",
                remediation: install)
        }

        guard let version = located.version else {
            return HealthFinding(
                id: requirement.findingID, title: requirement.title,
                status: .unknown(reason: "Could not read a version number from \(requirement.title)'s output."),
                detail: "\(requirement.title) was found at \(located.path), but its version output was not recognisable: \(located.rawVersionOutput.isEmpty ? "(empty output)" : located.rawVersionOutput)")
        }

        let upgrade = Remediation(
            explanation: "Update it with Homebrew, then re-run this check.",
            command: "brew upgrade \(requirement.formula)")

        if let floor = requirement.hardFloor, version < floor {
            let consequence = requirement.hardFloorConsequence ?? "It's used for \(requirement.purpose)."
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .problem,
                detail: "\(requirement.title) \(version) is older than the minimum \(floor) this app supports. \(consequence)",
                remediation: upgrade)
        }
        if let floor = requirement.softFloor, version < floor {
            let context = requirement.softFloorContext.map { " (\($0))" } ?? ""
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .warning,
                detail: "\(requirement.title) \(version) is older than \(floor)\(context). It's used for \(requirement.purpose).",
                remediation: upgrade)
        }
        return HealthFinding(
            id: requirement.findingID, title: requirement.title, status: .ok,
            detail: "\(requirement.title) \(version) at \(located.path).")
    }
}
