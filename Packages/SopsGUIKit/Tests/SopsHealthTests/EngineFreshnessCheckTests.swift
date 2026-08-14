import Foundation
import Testing
@testable import SopsHealth

private struct FakeUpstream: UpstreamVersionProviding {
    var releases: [String: UpstreamRelease] = [:]
    /// What a repository with no release entry reports. Defaults to a failed
    /// lookup; set to `.checksDisabled` to exercise the consent branch.
    var missing: UpstreamLookupResult = .lookupFailed

    func latestRelease(repository: String) async -> UpstreamLookupResult {
        releases[repository].map { .release($0) } ?? missing
    }
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

    @Test("offline the verdict is unknown, never a failure")
    func offlineIsUnknown() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(missing: .lookupFailed))
        for finding in await check.run() {
            guard case .unknown(let reason) = finding.status else {
                Issue.record("\(finding.id) should be unknown when upstream is unreachable, got \(finding.status)")
                continue
            }
            // I1: the app must not pretend it cannot tell consent from a
            // failed request. When the request really was attempted, the
            // reason must say that, not hedge across all three causes.
            #expect(!reason.lowercased().contains("can't tell"))
            #expect(!reason.lowercased().contains("cannot tell"))
            #expect(reason.lowercased().contains("turned off") == false,
                    "a failed lookup must not be blamed on the consent setting")
        }
    }

    /// I1. Consent is the app's own flag; it always knows when that is the
    /// reason, and the remediation is the setting rather than a link to read
    /// something else instead.
    @Test("with update checks turned off the finding names the setting and offers it as the fix")
    func consentOffNamesTheSetting() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(missing: .checksDisabled))

        for finding in await check.run() {
            guard case .unknown(let reason) = finding.status else {
                Issue.record("\(finding.id) should be unknown, got \(finding.status)")
                continue
            }
            #expect(reason.lowercased().contains("turned off"))
            #expect(!reason.lowercased().contains("offline"))
            #expect(!reason.lowercased().contains("can't tell"))
            #expect(finding.remediation?.explanation.lowercased().contains("settings") == true,
                    "the remediation must offer the setting: \(finding.remediation?.explanation ?? "nil")")
        }
    }

    /// I2. An engine version the bridge could not report must fail loudly. The
    /// old code substituted 0.0.0, which compares unfavourably against
    /// everything and produced a confident warning about a number nobody read
    /// — and, on the tool-check side, a confident OK.
    @Test("an unknown embedded version is a problem, never a comparison against a stand-in")
    func unknownEmbeddedVersionIsAProblem() async {
        let check = EngineFreshnessCheck(
            embeddedSops: nil,
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))

        let sops = finding(await check.run(), "engine.sops")
        #expect(sops.status == .problem)
        // The stand-in must not appear anywhere in the copy.
        #expect(!sops.detail.contains("0.0.0"))
        #expect(sops.detail.lowercased().contains("cannot tell")
                || sops.detail.lowercased().contains("could not"))
        // The healthy component is unaffected — one unknown does not poison
        // the other.
        #expect(finding(await check.run(), "engine.age").status == .ok)
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

    // Ticket #22, claim 2: the outdated-engine warning had `remediation.command
    // == nil` (correctly — no CLI command updates an embedded engine) but also
    // never mentioned the app's own "Check for Updates…" action
    // (`App/SopsGUIApp.swift:391,481-482`), even though that is exactly how a
    // user would act on this finding without leaving the app.
    @Test("an outdated engine's remediation points at the app's own Check for Updates action")
    func outdatedRemediationMentionsCheckForUpdates() async {
        let check = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 12, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let sops = finding(await check.run(), "engine.sops")
        #expect(sops.status == .warning)
        // Still no command: nothing here can be run in a terminal — see the
        // file's own header comment. The explanation names the in-app action
        // instead.
        #expect(sops.remediation?.command == nil)
        #expect(sops.remediation?.explanation.lowercased().contains("check for updates") == true,
                "\(sops.remediation?.explanation ?? "nil")")
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

    // Ticket #22, claim 3. The file's own header says "this is a version
    // comparison, not CVE matching" — but that lived only in a source
    // comment; no user-visible string said it. A green panel reads as "the
    // engine is safe", which this check does not and cannot claim. Both
    // branches that actually complete a comparison (`.ok` and `.warning`)
    // must disclose that in the copy the user reads.
    @Test("every completed comparison discloses that it is not a CVE verdict")
    func discloseComparisonIsNotCVEMatching() async {
        let upToDate = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 13, 3),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        let outdated = EngineFreshnessCheck(
            embeddedSops: SemanticVersion(3, 12, 0),
            embeddedAge: SemanticVersion(1, 3, 1),
            upstream: FakeUpstream(releases: [
                "getsops/sops": release(SemanticVersion(3, 13, 3)),
                "FiloSottile/age": release(SemanticVersion(1, 3, 1)),
            ]))
        for check in [upToDate, outdated] {
            for finding in await check.run() {
                #expect(finding.status == .ok || finding.status == .warning,
                        "test fixture produced an unexpected status: \(finding.status)")
                #expect(finding.detail.lowercased().contains("not cve matching"),
                        "\(finding.id) reached a verdict without disclosing it isn't a CVE verdict: \(finding.detail)")
            }
        }
    }
}
