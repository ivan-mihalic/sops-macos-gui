import Foundation

/// PROPOSAL.md §6 B. Compares the sops/age versions compiled into the bridge
/// against the latest upstream releases.
///
/// This is a version comparison, not CVE matching. The app must never state or
/// imply that a particular version is vulnerable, insecure, or unsafe — it
/// does not have the information to back that claim. It reports only that the
/// embedded version is behind the latest release, links to the release notes
/// and the project's public security-advisories page, and leaves the judgment
/// to the user.
///
/// There is deliberately no remediation command here (contrast
/// `ExternalToolCheck`, which offers `brew upgrade`): the engine ships inside
/// this app's bundle, not as a separate install, so no terminal command can
/// change it. Updating the app is what updates the engine.
public struct EngineFreshnessCheck: HealthCheck {
    public let id = "engine-freshness"
    public let category = HealthCategory.engine

    private struct Component {
        let findingID: String
        let title: String
        let repository: String
        /// nil when the bridge could not report which version it linked. Not
        /// a version number standing in for "unknown" — see `evaluate`.
        let embedded: SemanticVersion?
        /// Shown only when upstream could not be reached — there is no
        /// specific release to link to, so this points at the project's
        /// general security-advisories page instead.
        let advisoriesURL: URL
    }

    private let embeddedSops: SemanticVersion?
    private let embeddedAge: SemanticVersion?
    private let upstream: any UpstreamVersionProviding

    public init(embeddedSops: SemanticVersion?, embeddedAge: SemanticVersion?,
                upstream: any UpstreamVersionProviding) {
        self.embeddedSops = embeddedSops
        self.embeddedAge = embeddedAge
        self.upstream = upstream
    }

    private var components: [Component] {
        [
            Component(findingID: "engine.sops", title: "sops engine",
                      repository: "getsops/sops", embedded: embeddedSops,
                      advisoriesURL: URL(string: "https://github.com/getsops/sops/security/advisories")!),
            Component(findingID: "engine.age", title: "age library",
                      repository: "FiloSottile/age", embedded: embeddedAge,
                      advisoriesURL: URL(string: "https://github.com/FiloSottile/age/security/advisories")!),
        ]
    }

    public func run() async -> [HealthFinding] {
        await withTaskGroup(of: HealthFinding.self) { group in
            for component in components {
                group.addTask { await evaluate(component) }
            }
            var findings: [HealthFinding] = []
            for await finding in group { findings.append(finding) }
            return findings
        }
    }

    private func evaluate(_ component: Component) async -> HealthFinding {
        // No embedded version means there is nothing to compare, and this is
        // the one branch that must never be quiet about it.
        //
        // The previous code substituted 0.0.0 for an unreadable version and
        // carried on comparing. 0.0.0 loses every comparison, so the app
        // confidently reported that its engine was years out of date — a
        // statement about a number it had never read. Reporting `.problem`
        // instead is the "fail loudly" half of the rule: a build that cannot
        // say what it embeds is broken, and it says so rather than inventing
        // a plausible answer in either direction.
        guard let embedded = component.embedded else {
            return HealthFinding(
                id: component.findingID, title: component.title, status: .problem,
                detail: "This app cannot tell which version of \(component.title) is built into it. "
                    + "Without that, there is nothing to compare against the latest release, so it "
                    + "cannot tell you whether the engine it is running is current.",
                remediation: Remediation(
                    explanation: "This is a fault in this build of the app, not in your setup — nothing you can change on this machine fixes it. Reinstalling the latest release is the one thing worth trying. In the meantime you can read the project's public security advisories yourself.",
                    command: nil,
                    documentationURL: component.advisoriesURL))
        }

        let latest: UpstreamRelease
        switch await upstream.latestRelease(repository: component.repository) {
        case .release(let found):
            latest = found

        case .checksDisabled:
            // The app knows exactly why this did not happen: its own setting.
            // Saying "this app can't tell which" here was the dishonest part —
            // and the remediation is the setting, not a link to read instead.
            return HealthFinding(
                id: component.findingID, title: component.title,
                status: .unknown(reason: "Update checks are turned off, so this app did not contact GitHub to see whether a newer \(component.title) exists."),
                detail: "This app has \(component.title) \(embedded) built in. "
                    + "Nothing was sent anywhere, so there is no comparison to show.",
                remediation: Remediation(
                    explanation: "Turn on \"Check for engine updates\" in Settings › Updates to let this app ask GitHub for the latest release. It is off until you say otherwise, and it is the only network request this app makes on its own. You can also read the project's public security advisories yourself instead.",
                    command: nil,
                    documentationURL: component.advisoriesURL))

        case .lookupFailed:
            return HealthFinding(
                id: component.findingID, title: component.title,
                status: .unknown(reason: "Update checks are on, but GitHub did not answer — this Mac may be offline, or the request may have failed or been rate-limited."),
                detail: "This app has \(component.title) \(embedded) built in. "
                    + "The latest available release is not known right now, so no comparison could be made.",
                remediation: Remediation(
                    explanation: "Re-run this check when you are back online. You can also review the project's public security advisories page yourself and judge whether anything there matters to you.",
                    command: nil,
                    documentationURL: component.advisoriesURL))
        }

        guard embedded < latest.version else {
            return HealthFinding(
                id: component.findingID, title: component.title, status: .ok,
                detail: "This app has \(component.title) \(embedded) built in. "
                    + "The latest known release is \(latest.version). "
                    + "This is a version comparison, not CVE matching.")
        }

        return HealthFinding(
            id: component.findingID, title: component.title, status: .warning,
            detail: "This app has \(component.title) \(embedded) built in, "
                + "and \(latest.version) has since been released. "
                + "This is a version comparison, not CVE matching.",
            remediation: Remediation(
                explanation: "The \(component.title) ships inside this app rather than as a separate install, "
                    + "so updating the app is what brings in the newer version. Choose \"Check for Updates…\" "
                    + "from the SopsGUI menu to look for it now, or read the release notes "
                    + "to see what changed and judge for yourself whether it matters to you.",
                command: nil,
                documentationURL: latest.releaseNotesURL))
    }
}
