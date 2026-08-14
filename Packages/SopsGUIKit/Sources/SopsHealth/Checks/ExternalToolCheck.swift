import Foundation

/// PROPOSAL.md §6 A. None of these tools are needed for the app to work — the
/// SOPS engine is compiled into the app and runs in-process. They matter only
/// if you use these same files yourself outside the app — in your own
/// terminal, in CI, or in scripts — where a compatible version of the tool
/// this app itself relies on keeps that usage correct.
///
/// PROPOSAL.md §5 describes an in-app Help section with copy-paste snippets
/// built against these tools; that section does not exist yet (no menu item,
/// no view — ticket #14), and `docs/GUIDE.md` on disk is not in the app
/// bundle either. Until there is somewhere in the app to point a user with a
/// missing tool, a missing tool is purely informational, never a warning —
/// see `evaluate`, and `HealthReport.worstStatus`, which a `.warning` would
/// otherwise be able to degrade. The one exception is `yq` below v4: its
/// `-o=props` mode silently produces different output there, which would
/// generate a wrong `.env` file for anyone piping decrypted output through
/// it — a real, version-specific defect independent of whether this app ever
/// ships that workflow in-app.
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
        /// hard floor of 2.30, which made an outdated git a `.problem`, and
        /// the spec says "warn below 2.30" in any case.
        ///
        /// A *present but outdated* tool deliberately outranks an *absent*
        /// one (see `evaluate`'s "not found" branch, and ticket #14): if you
        /// actually run this tool against these files, an old version can
        /// misbehave in ways this app can name, where "you don't have it at
        /// all" is not, on its own, something the user can act on from here.
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
        let versionArguments: [String]
        /// Set when `versionArguments` carries a flag the tool only learned in
        /// a known release. A tool that *rejects* the flag is therefore
        /// provably older than this version — which is a real verdict, not a
        /// failure to reach one. See `evaluate` for why that matters.
        let versionArgumentsSupportedSince: SemanticVersion?
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

    /// Internal rather than private so the tests can assert on the argument
    /// list this check actually builds. `ExternalToolCheckTests` drives the
    /// check through a `FakeLocator`, which discards `versionArguments`
    /// entirely — that blind spot is how `sops --version` shipped without
    /// `--disable-version-check`. See `ExternalToolNetworkTests`.
    var requirements: [Requirement] {
        [
            Requirement(
                name: "sops", findingID: "tool.sops", title: "sops CLI",
                purpose: "decrypting these files in your terminal and in CI",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: embeddedSopsVersion, softFloorContext: "the version built into this app",
                missingSoftFloorNote: embeddedSopsVersion == nil
                    ? "This app could not determine which sops version it has built in, so it could not tell you whether this CLI is older than that."
                    : nil,
                // `--disable-version-check` first, then `--version`: sops's own
                // deprecation notice spells the invocation that way, and it is
                // the position urfave/cli documents for a global flag. Both
                // orders are accepted by sops 3.13.3, but only one of them is
                // the one upstream tells you to use.
                //
                // Without it, `sops --version` contacts api.github.com to
                // compare itself against the latest release — sops 3.11
                // deprecated that default but kept it. This check runs
                // unattended on first launch, before the user has been asked
                // about anything, so a plain `--version` here made the app
                // issue an unconsented network request while its own copy said
                // the GitHub release lookup was the only one it ever makes.
                versionArguments: ["--disable-version-check", "--version"],
                versionArgumentsSupportedSince: SemanticVersion(3, 8, 0),
                formula: "sops"),
            Requirement(
                name: "age", findingID: "tool.age", title: "age",
                purpose: "generating age keys outside this app, e.g. on a server",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: SemanticVersion(1, 3, 0), softFloorContext: nil,
                missingSoftFloorNote: nil,
                versionArguments: ["--version"], versionArgumentsSupportedSince: nil,
                formula: "age"),
            Requirement(
                name: "git", findingID: "tool.git", title: "git",
                purpose: "worktree detection and commit hygiene",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: SemanticVersion(2, 30, 0), softFloorContext: nil,
                missingSoftFloorNote: nil,
                versionArguments: ["--version"], versionArgumentsSupportedSince: nil,
                formula: "git"),
            Requirement(
                name: "yq", findingID: "tool.yq", title: "yq",
                purpose: "generating a .env file from these secrets",
                hardFloor: SemanticVersion(4, 0, 0),
                hardFloorConsequence: "Its -o=props syntax accepts versions below v4 silently but produces different output there, which would generate a wrong .env file.",
                softFloor: nil, softFloorContext: nil,
                missingSoftFloorNote: nil,
                versionArguments: ["--version"], versionArgumentsSupportedSince: nil,
                formula: "yq"),
            Requirement(
                name: "docker", findingID: "tool.docker", title: "Docker",
                purpose: "running docker-compose workflows against these files",
                hardFloor: nil, hardFloorConsequence: nil,
                softFloor: nil, softFloorContext: nil,
                missingSoftFloorNote: nil,
                versionArguments: ["--version"], versionArgumentsSupportedSince: nil,
                formula: "docker"),
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

    /// Whether a tool's output is a command-line parser complaining about an
    /// argument it does not know, rather than a version.
    ///
    /// Deliberately narrow: these are the exact phrases Go's `flag` package
    /// and `urfave/cli` (which `sops` uses) print, and no tool prints them
    /// while succeeding. A wrong answer here only ever downgrades a `.warning`
    /// to the `.unknown` it would otherwise have been, or the reverse — it can
    /// never manufacture an `.ok`.
    static func rejectedAnArgument(_ output: String) -> Bool {
        let lowered = output.lowercased()
        return lowered.contains("flag provided but not defined")
            || lowered.contains("incorrect usage")
            || lowered.contains("unknown flag")
            || lowered.contains("unknown option")
    }

    private func upgradeRemediation(_ requirement: Requirement) -> Remediation {
        Remediation(explanation: "Update it with Homebrew, then re-run this check.",
                    command: "brew upgrade \(requirement.formula)")
    }

    private func evaluate(_ requirement: Requirement) async -> HealthFinding {
        guard let located = await locator.locate(requirement.name,
                                                   versionArguments: requirement.versionArguments) else {
            let install = Remediation(
                explanation: "Install it with Homebrew, then re-run this check.",
                command: "brew install \(requirement.formula)")
            // Always informational, never a `.warning`, for every one of the
            // five tools this check knows about — see the header comment.
            // There is nowhere in the app today (no Help section) to send a
            // user who is missing one, so absence alone must never be able to
            // degrade `HealthReport.worstStatus`. The row renders the skip
            // reason and the detail one after the other, so these two must
            // not say the same thing twice: the reason states the fact, the
            // detail states what it costs.
            return HealthFinding(
                id: requirement.findingID, title: requirement.title,
                status: .skipped(reason: "\(requirement.title) was not found on this machine."),
                detail: "It's used for \(requirement.purpose). Nothing in this app depends on it.",
                remediation: install)
        }

        // Checked *before* `located.version`, not after, because a usage dump
        // is not version-free text. sops's own help screen contains the token
        // `85D...B3F21"` (a fingerprint in an example), and `parseVersion`
        // anchors on the first digit-leading token — so an unrecognised
        // argument yields a confident `sops 85.0.0 … [OK]`. Measured against
        // the real binary. Whatever else this branch decides, it must decide
        // it before that number is believed.
        if Self.rejectedAnArgument(located.rawVersionOutput) {
            // A tool that *rejected* one of our own arguments is not an
            // unreadable tool — for `sops` the rejection is itself a fact
            // about its version, and a useful one: `--disable-version-check`
            // arrived in sops 3.8.0, so a sops that refuses it is provably
            // older than that.
            //
            // Retrying without the flag is the obvious alternative and is
            // exactly what must not happen: on those versions sops has no way
            // to report its version without contacting GitHub, so the retry
            // would reintroduce the unconsented request this argument list
            // exists to remove. Reporting what the refusal proves costs
            // nothing and stays offline.
            if let since = requirement.versionArgumentsSupportedSince {
                let context = requirement.softFloorContext.map { " (\($0))" } ?? ""
                let comparison = requirement.softFloor.map { floor in
                    " \(since) is in turn older than \(floor)\(context)."
                } ?? ""
                return HealthFinding(
                    id: requirement.findingID, title: requirement.title, status: .warning,
                    detail: "\(requirement.title) at \(located.path) does not accept the \(requirement.versionArguments.first ?? "") option, which \(requirement.name) added in \(since). This app did not ask it for its exact version, because \(requirement.name) versions without that option cannot report their version without contacting GitHub, and this app makes no network request you have not asked for. What the refusal does establish: this \(requirement.name) is older than \(since).\(comparison) It's used for \(requirement.purpose).",
                    remediation: upgradeRemediation(requirement))
            }
            return HealthFinding(
                id: requirement.findingID, title: requirement.title,
                status: .unknown(reason: "\(requirement.title) did not accept the options this app asked it for, so it never printed a version."),
                detail: "\(requirement.title) was found at \(located.path) and rejected `\(requirement.versionArguments.joined(separator: " "))`. This app is not guessing a version out of the usage text that came back.")
        }

        guard let version = located.version else {
            return HealthFinding(
                id: requirement.findingID, title: requirement.title,
                status: .unknown(reason: "Could not read a version number from \(requirement.title)'s output."),
                detail: "\(requirement.title) was found at \(located.path), but its version output was not recognisable: \(located.rawVersionOutput.isEmpty ? "(empty output)" : located.rawVersionOutput)")
        }

        let upgrade = upgradeRemediation(requirement)

        if let floor = requirement.hardFloor, version < floor {
            let consequence = requirement.hardFloorConsequence ?? "It's used for \(requirement.purpose)."
            // Not "the minimum this app supports": this file's own header says
            // none of these tools are needed for the app to work — the engine
            // is compiled in. `hardFloorConsequence` says what actually breaks
            // for whoever runs this tool themselves, instead of pointing at a
            // Help section that does not exist.
            return HealthFinding(
                id: requirement.findingID, title: requirement.title, status: .problem,
                detail: "\(requirement.title) \(version) is older than \(floor). \(consequence)",
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
