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
        /// Below this, the tool is not merely old but *wrong* — it accepts the
        /// snippet and silently produces different output.
        ///
        /// PROPOSAL.md §6 A reserves this for exactly one tool, `yq` below v4.
        /// Everything else is a warning, however old. `git` used to carry a
        /// hard floor of 2.30, which made an outdated git a `.problem` while a
        /// git that was missing altogether was only a `.warning` — absence
        /// ranked as less serious than staleness, and the spec says "warn
        /// below 2.30" in any case.
        let hardFloor: SemanticVersion?
        /// Extra sentence appended when `hardFloor` is breached, explaining
        /// *why* the old version is actively wrong rather than just stale.
        let hardFloorConsequence: String?
        /// Below this, the tool still works but should be updated.
        let softFloor: SemanticVersion?
        /// How to describe `softFloor` in the warning, e.g. "the version
        /// built into this app" for sops, vs. nil for a plain recommendation.
        let softFloorContext: String?
        /// Appended to the OK detail when this requirement *should* have had a
        /// soft floor but the value could not be established. Without it, a
        /// comparison that never happened is indistinguishable from one that
        /// passed.
        let missingSoftFloorNote: String?
        /// Absence is informational rather than a warning.
        let optional: Bool
        let versionArguments: [String]
        let formula: String
    }

    private let locator: any ToolLocating
    /// nil when the bridge could not report which sops it embeds. Then there
    /// is simply no floor to compare the CLI against, and the OK detail says
    /// so — see `missingSoftFloorNote`. Substituting 0.0.0, as this used to,
    /// makes every installed sops look current.
    private let embeddedSopsVersion: SemanticVersion?

    public init(locator: any ToolLocating, embeddedSopsVersion: SemanticVersion?) {
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
                missingSoftFloorNote: embeddedSopsVersion == nil
                    ? "This app could not determine which sops version it has built in, so it could not tell you whether this CLI is older than that."
                    : nil,
                optional: false, versionArguments: ["--version"], formula: "sops"),
            Requirement(
                name: "age", findingID: "tool.age", title: "age",
                purpose: "generating age keys outside this app, e.g. on a server",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: SemanticVersion(1, 3, 0), softFloorContext: nil,
                missingSoftFloorNote: nil,
                optional: false, versionArguments: ["--version"], formula: "age"),
            Requirement(
                name: "git", findingID: "tool.git", title: "git",
                purpose: "worktree detection and commit hygiene",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: SemanticVersion(2, 30, 0), softFloorContext: nil,
                missingSoftFloorNote: nil,
                optional: false, versionArguments: ["--version"], formula: "git"),
            Requirement(
                name: "yq", findingID: "tool.yq", title: "yq",
                purpose: "generating a .env file from these secrets",
                hardFloor: SemanticVersion(4, 0, 0),
                hardFloorConsequence: "Its -o=props syntax accepts versions below v4 silently but produces different output there, which would generate a wrong .env file.",
                softFloor: nil, softFloorContext: nil,
                missingSoftFloorNote: nil,
                optional: false, versionArguments: ["--version"], formula: "yq"),
            Requirement(
                name: "docker", findingID: "tool.docker", title: "Docker",
                purpose: "running the docker-compose snippets in Help",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: nil, softFloorContext: nil,
                missingSoftFloorNote: nil,
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
                // The row renders the skip reason and the detail one after the
                // other, so these two must not say the same thing twice: the
                // reason states the fact, the detail states what it costs.
                return HealthFinding(
                    id: requirement.findingID, title: requirement.title,
                    status: .skipped(reason: "\(requirement.title) was not found on this machine."),
                    detail: "It's only needed for \(requirement.purpose), so nothing here depends on it.",
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
            // Not "the minimum this app supports": this file's own header says
            // none of these tools are needed for the app to work — the engine
            // is compiled in. What breaks is the snippet the user copies out
            // of Help and runs in their own terminal, and the copy now says
            // that instead of contradicting the check's own premise.
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .problem,
                detail: "\(requirement.title) \(version) is older than \(floor), which the snippets in Help are written against. \(consequence)",
                remediation: upgrade)
        }
        if let floor = requirement.softFloor, version < floor {
            let context = requirement.softFloorContext.map { " (\($0))" } ?? ""
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .warning,
                detail: "\(requirement.title) \(version) is older than \(floor)\(context). It's used for \(requirement.purpose).",
                remediation: upgrade)
        }
        let note = requirement.missingSoftFloorNote.map { " " + $0 } ?? ""
        return HealthFinding(
            id: requirement.findingID, title: requirement.title, status: .ok,
            detail: "\(requirement.title) \(version) at \(located.path)." + note)
    }
}
