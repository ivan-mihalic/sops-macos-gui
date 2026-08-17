import Foundation
import Testing
@testable import SopsHealth

private struct StubKeyStore: KeyStoreStatusProviding { let state = KeyStoreState.configured }
private struct StubBiometry: BiometryStatusProviding { let state: BiometryState }
private struct StubUpdates: AppUpdateStatusProviding { let state = AppUpdateState.upToDate(version: "1.0.0") }
private struct StubSessionTTL: SessionTTLStatusProviding { let state = SessionTTLState.enforced(minutes: 15) }

/// What the Touch ID finding is allowed to say.
///
/// It used to say "Touch ID is available for unlocking your key", and the two
/// other branches matched: "unlocking will fall back to your password",
/// "Unlocking will use your password instead." **Nothing in this app unlocks a
/// key.** `LAContext` appears in exactly one file, only to ask
/// `canEvaluatePolicy`; `evaluatePolicy` — the call that would actually put a
/// key behind Touch ID — is never called anywhere. The key is pasted into
/// process memory each session and bounded by a TTL and the sleep hook.
///
/// That made it a false security claim in a security app: a reader could
/// reasonably conclude their key sat behind biometrics and decide whether to
/// leave the Mac unlocked on that basis. `keyStoreFinding`, two findings down
/// in the same file, is careful about exactly this — its comment says
/// `"Stored in your Keychain" would overclaim … Say what is actually true
/// now.` The biometry finding was not.
///
/// So this suite pins two things. The first is the rule: while no key is
/// gated on biometrics, no biometry text may describe unlocking one. The
/// second is the tripwire — if `evaluatePolicy` ever *does* appear, this test
/// fails, because at that point the rule no longer applies and whoever added
/// it needs to revisit the wording rather than inherit a guard written for a
/// build where the feature did not exist.
@Suite("Touch ID finding claims only what is true")
struct BiometryClaimTests {

    private func findings(_ state: BiometryState) async -> [HealthFinding] {
        await SecurityPostureCheck(
            osVersion: SemanticVersion(26, 5, 2),
            minimumOSVersion: SemanticVersion(14, 0, 0),
            keyStore: StubKeyStore(),
            biometry: StubBiometry(state: state),
            appUpdates: StubUpdates(),
            legacyKeyFilePaths: ["/nonexistent/keys.txt"],
            sessionTTL: StubSessionTTL()
        ).run().filter { $0.id == "security.biometry" }
    }

    @Test("no branch says Touch ID unlocks anything",
          arguments: [BiometryState.available,
                      .notEnrolled,
                      .unavailable(reason: "No Touch ID hardware on this Mac.")])
    func neverClaimsUnlocking(_ state: BiometryState) async {
        // Narrow on purpose. "unlock" catches unlocks/unlocking/unlocked in
        // one term and is the whole of the original overclaim; the other two
        // are the specific phrases this finding reached for — a password
        // fallback for an unlock that never happens, and protection it does
        // not provide.
        //
        // A broader term like "your key" was tried first and rejected: it
        // would also block the honest replacement, which has to mention where
        // the key actually lives in order to correct the impression the old
        // text left. A guard that forbids saying the true thing is worse than
        // no guard.
        let forbidden = ["unlock", "fall back to your password", "protects your key"]

        for finding in await findings(state) {
            let text = (finding.detail
                        + " " + (finding.remediation?.explanation ?? "")
                        + " " + statusReason(finding.status)).lowercased()
            for word in forbidden {
                #expect(!text.contains(word), Comment(rawValue: """
                    The Touch ID finding says "\(word)", but nothing in this app puts a key \
                    behind Touch ID — evaluatePolicy is never called. Say what Touch ID \
                    actually does here today, or drop the finding until it does something.
                    Text was: \(finding.detail)
                    """))
            }
        }
    }

    /// The tripwire. Written as a source scan rather than a behavioural check
    /// because the thing being watched for is an *absence*, and an absence has
    /// no behaviour to observe.
    @Test("the rule above still applies — no key is gated on biometrics yet")
    func evaluatePolicyIsStillAbsent() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SopsHealthTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SopsGUIKit
            .appendingPathComponent("Sources")
        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))

        var callers: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            if try String(contentsOf: url, encoding: .utf8).contains("evaluatePolicy(") {
                callers.append(url.lastPathComponent)
            }
        }

        #expect(callers.isEmpty, Comment(rawValue: """
            evaluatePolicy is now called in \(callers) — something is finally gated on \
            Touch ID. The wording rule in this suite was written for a build where \
            nothing was, so revisit the Touch ID finding's text deliberately rather \
            than leaving a guard that no longer describes the app.
            """))
    }

    private func statusReason(_ status: HealthStatus) -> String {
        switch status {
        case .skipped(let reason), .unknown(let reason): reason
        default: ""
        }
    }
}
