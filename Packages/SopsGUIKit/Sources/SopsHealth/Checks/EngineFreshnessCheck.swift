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
        let embedded: SemanticVersion
        /// Shown only when upstream could not be reached — there is no
        /// specific release to link to, so this points at the project's
        /// general security-advisories page instead.
        let advisoriesURL: URL
    }

    private let embeddedSops: SemanticVersion
    private let embeddedAge: SemanticVersion
    private let upstream: any UpstreamVersionProviding

    public init(embeddedSops: SemanticVersion, embeddedAge: SemanticVersion,
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
        guard let latest = await upstream.latestRelease(repository: component.repository) else {
            return HealthFinding(
                id: component.findingID, title: component.title,
                status: .unknown(reason: "Could not check for a newer \(component.title) release. "
                    + "This may be because update checks are turned off, this Mac is offline, "
                    + "or GitHub did not respond — this app can't tell which."),
                detail: "This app has \(component.title) \(component.embedded) built in. "
                    + "The latest available release is not known right now, so no comparison could be made.",
                remediation: Remediation(
                    explanation: "You can review the project's public security advisories page yourself and judge whether anything there matters to you.",
                    command: nil,
                    documentationURL: component.advisoriesURL))
        }

        guard component.embedded < latest.version else {
            return HealthFinding(
                id: component.findingID, title: component.title, status: .ok,
                detail: "This app has \(component.title) \(component.embedded) built in. "
                    + "The latest known release is \(latest.version).")
        }

        return HealthFinding(
            id: component.findingID, title: component.title, status: .warning,
            detail: "This app has \(component.title) \(component.embedded) built in, "
                + "and \(latest.version) has since been released.",
            remediation: Remediation(
                explanation: "The \(component.title) ships inside this app rather than as a separate install, "
                    + "so updating the app is what brings in the newer version. Read the release notes "
                    + "to see what changed and judge for yourself whether it matters to you.",
                command: nil,
                documentationURL: latest.releaseNotesURL))
    }
}
