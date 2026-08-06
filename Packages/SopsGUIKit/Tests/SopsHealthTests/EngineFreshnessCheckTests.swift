import Foundation
import Testing
@testable import SopsHealth

private struct FakeUpstream: UpstreamVersionProviding {
    var releases: [String: UpstreamRelease]
    func latestRelease(repository: String) async -> UpstreamRelease? { releases[repository] }
}

private func release(_ version: SemanticVersion) -> UpstreamRelease {
    UpstreamRelease(version: version, releaseNotesURL: URL(string: "https://example.invalid/notes")!)
}

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

@Suite("EngineFreshnessCheck")
struct EngineFreshnessCheckTests {

    @Test("an up-to-date embedded engine is OK")
    func upToDateIsOK() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let findings = await check.run()
        #expect(finding(findings, "engine.sops").status == .ok)
        #expect(finding(findings, "engine.age").status == .ok)
    }

    @Test("an outdated embedded engine warns the user to update the app, not to run brew")
    func outdatedWarnsAboutTheApp() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 12, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let sops = finding(await check.run(), "engine.sops")
        #expect(sops.status == .warning)
        // The engine is inside the app bundle; brew cannot fix it.
        #expect(sops.remediation?.command == nil)
        #expect(sops.remediation?.documentationURL != nil)
    }

    @Test("offline or without consent the verdict is unknown, never a failure")
    func offlineIsUnknown() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [:]))
        for finding in await check.run() {
            if case .unknown = finding.status {} else {
                Issue.record("\(finding.id) should be unknown when upstream is unreachable, got \(finding.status)")
            }
        }
    }

    // The app must not imply it knows whether a version is vulnerable, unsafe,
    // or that updating is urgently required for security reasons — a version
    // comparison cannot support any of those claims, only "this is behind."
    //
    // The brief's original guard only checked for "vulnerable" and "cve-",
    // which copy like "this version is unsafe" or "you should update
    // immediately for security reasons" sails straight through. This list
    // widens the net to the vocabulary that would actually assert a security
    // verdict:
    //   - direct verdicts: vulnerable, vulnerability, cve-, insecure, unsafe,
    //     not safe, security flaw, exploit, compromise(d)
    //   - hedged verdicts that still claim danger: security risk, at risk,
    //     risky, unpatched, dangerous
    //   - urgency borrowed from a security justification the check cannot
    //     back: update immediately, right away, as soon as possible, for
    //     security reasons, urgent(ly)
    // Deliberately NOT forbidden: bare "security" (the remediation legitimately
    // links to the project's public security-advisories page so the user can
    // judge for themselves — that's a pointer, not a verdict), and "update"
    // on its own (updating the app is the correct, non-security-framed action).
    @Test("never claims or implies a version is vulnerable, unsafe, or urgently needed for security")
    func makesNoSecurityClaims() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 12, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let forbidden = [
            "vulnerable", "vulnerability", "cve-", "insecure", "unsafe", "not safe",
            "security flaw", "exploit", "compromise", "compromised",
            "security risk", "at risk", "risky", "unpatched", "dangerous",
            "update immediately", "right away", "as soon as possible",
            "for security reasons", "urgent",
        ]
        for finding in await check.run() {
            let text = (finding.detail + (finding.remediation?.explanation ?? "")).lowercased()
            for word in forbidden {
                #expect(!text.contains(word),
                         "\(finding.id) copy contains forbidden word \"\(word)\": \(text)")
            }
        }
    }

    @Test("an embedded version ahead of the latest release is OK, not a warning")
    func aheadOfUpstreamIsOK() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 14, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        #expect(finding(await check.run(), "engine.sops").status == .ok)
    }
}
