import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// A probe that could not run must not produce a security all-clear.
///
/// Two rounds in a row this was reported fixed and was not. The marker taught
/// the probe to distinguish failure from silence; the cache stopped
/// *remembering* a failure — and then the failure was flattened back to `[:]`
/// before it reached the finding, so `SecurityPostureCheck` still printed "No
/// unprotected age key file was found at any of the places sops reads one
/// from" on a machine with a plaintext key at the path it failed to read. Same
/// machine, same key file, opposite verdict depending on whether a shell spawn
/// timed out.
@Suite("A failed key-file probe is not an all-clear")
struct KeyFileProbeFailureFindingTests {

    private func finding(probeFailed: Bool, paths: [String]) async -> HealthFinding? {
        let check = SecurityPostureCheck(
            osVersion: SemanticVersion(26, 5, 2),
            minimumOSVersion: SemanticVersion(14, 0, 0),
            keyStore: ProbeKeyStore(), biometry: ProbeBiometry(), appUpdates: ProbeUpdates(),
            legacyKeyFilePaths: paths,
            legacyKeyFileProbeFailed: probeFailed)
        return await check.run().first { $0.id == "security.legacy-key-file" }
    }

    @Test("a failed probe reports unknown, not ok")
    func failedProbeIsUnknown() async throws {
        let found = try #require(await finding(probeFailed: true, paths: ["/no/such/keys.txt"]))

        guard case .unknown(let reason) = found.status else {
            Issue.record("a failed probe produced \(found.status): \(found.detail)")
            return
        }
        #expect(reason.contains("SOPS_AGE_KEY_FILE"),
                "the reason does not say what could not be established")
        #expect(!found.detail.contains("No unprotected age key file was found"),
                "the all-clear sentence survived a probe that never ran")
    }

    /// The other half: a probe that worked and found nothing is a real
    /// all-clear, or the fix is just "never say ok".
    @Test("a probe that worked and found nothing still reports ok")
    func successfulProbeStillReportsOK() async throws {
        let found = try #require(await finding(probeFailed: false, paths: ["/no/such/keys.txt"]))
        #expect(found.status == .ok, "a complete probe finding nothing was not an all-clear")
    }

    /// And a probe that failed but found a key anyway still warns — the
    /// unknown branch must not swallow a real finding.
    @Test("a key found despite a failed probe is still a warning")
    func foundKeyStillWarns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("probe-failure-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyFile = directory.appendingPathComponent("keys.txt")
        try "not a real key".write(to: keyFile, atomically: true, encoding: .utf8)

        let found = try #require(await finding(probeFailed: true, paths: [keyFile.path]))
        #expect(found.status == .warning,
                "a plaintext key file was hidden behind the failed-probe branch")
    }
}

private struct ProbeKeyStore: KeyStoreStatusProviding { let state = KeyStoreState.configured }
private struct ProbeBiometry: BiometryStatusProviding { let state = BiometryState.available }
private struct ProbeUpdates: AppUpdateStatusProviding {
    let state = AppUpdateState.upToDate(version: "1.0.0")
}
