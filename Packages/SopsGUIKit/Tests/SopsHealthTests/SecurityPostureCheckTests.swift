import Foundation
import Testing
@testable import SopsHealth

private struct FakeKeyStore: KeyStoreStatusProviding { let state: KeyStoreState }
private struct FakeBiometry: BiometryStatusProviding { let state: BiometryState }
private struct FakeUpdates: AppUpdateStatusProviding {
    let state: HealthStatus
    let detail: String
}

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

private func makeCheck(
    os: SemanticVersion = SemanticVersion(26, 5, 2),
    keyStore: KeyStoreState = .configured,
    biometry: BiometryState = .available,
    updates: HealthStatus = .ok,
    legacyKeyFilePath: String = "/nonexistent/keys.txt"
) -> SecurityPostureCheck {
    SecurityPostureCheck(
        osVersion: os,
        minimumOSVersion: SemanticVersion(14, 0, 0),
        keyStore: FakeKeyStore(state: keyStore),
        biometry: FakeBiometry(state: biometry),
        appUpdates: FakeUpdates(state: updates, detail: "up to date"),
        legacyKeyFilePath: legacyKeyFilePath)
}

@Suite("SecurityPostureCheck")
struct SecurityPostureCheckTests {

    @Test("a fully configured machine reports OK across the board")
    func healthyMachine() async {
        for finding in await makeCheck().run() {
            #expect(finding.status == .ok, "\(finding.id) was \(finding.status)")
        }
    }

    @Test("no age key configured is a problem — the app cannot decrypt anything")
    func missingKeyIsAProblem() async {
        let keystore = finding(await makeCheck(keyStore: .empty).run(), "security.keystore")
        #expect(keystore.status == .problem)
    }

    @Test("biometry not enrolled is a warning, not a problem — a password still works")
    func biometryNotEnrolledWarns() async {
        let biometry = finding(await makeCheck(biometry: .notEnrolled).run(), "security.biometry")
        #expect(biometry.status == .warning)
    }

    // The whole point of the Keychain model is that the key is not sitting in a
    // plaintext file. Finding one is the single most valuable thing this check does.
    @Test("a plaintext keys.txt still on disk is a warning that explains the risk")
    func legacyKeyFileWarns() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "# created by age-keygen\n".write(to: keyFile, atomically: true, encoding: .utf8)

        let legacy = finding(await makeCheck(legacyKeyFilePath: keyFile.path).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .warning)
        #expect(legacy.detail.contains(keyFile.path))
        #expect(legacy.remediation != nil)
    }

    @Test("no plaintext key file on disk is OK")
    func noLegacyKeyFileIsOK() async {
        #expect(finding(await makeCheck().run(), "security.legacy-key-file").status == .ok)
    }

    // A directory at the legacy key file's path (e.g. an empty
    // ~/.config/sops/age/keys.txt someone `mkdir -p`'d) is not a plaintext key
    // file. `FileManager.fileExists(atPath:)` alone can't distinguish a
    // directory from a regular file, so a naive check would report the false
    // "An age key file sits unencrypted at …" about a path holding no file at
    // all.
    @Test("a directory at the legacy key file path is not mistaken for a key file")
    func legacyKeyFilePathAsDirectoryIsOK() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-dir-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = finding(await makeCheck(legacyKeyFilePath: dir.path).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .ok)
    }

    @Test("an unsupported macOS version is a problem")
    func oldOSIsAProblem() async {
        let os = finding(await makeCheck(os: SemanticVersion(13, 0, 0)).run(), "security.os")
        #expect(os.status == .problem)
    }

    @Test("features that have not shipped report skipped with a reason, never a false OK")
    func unshippedFeaturesAreSkipped() async {
        let findings = await makeCheck(
            keyStore: .unavailable(reason: "Keychain storage arrives in M3."),
            updates: .skipped(reason: "Update checking arrives with Sparkle in M5.")
        ).run()

        for id in ["security.keystore", "security.app-updates"] {
            guard case .skipped(let reason) = finding(findings, id).status else {
                Issue.record("\(id) should be skipped, got \(finding(findings, id).status)")
                continue
            }
            #expect(!reason.isEmpty, "a skipped check must say why")
        }
    }

    @Test("no finding ever contains key material")
    func neverLeaksKeyMaterial() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQ\n".write(to: keyFile, atomically: true, encoding: .utf8)

        for finding in await makeCheck(legacyKeyFilePath: keyFile.path).run() {
            let text = finding.detail + finding.title + (finding.remediation?.explanation ?? "")
            #expect(!text.contains("AGE-SECRET-KEY-1QQQ"))
        }
    }

    // The test above proves a specific string didn't leak — it does NOT prove the
    // file was never opened. A check that reads the file and merely fails to echo
    // its contents back would still pass it. This test proves the stronger claim:
    // the file is never *read* at all, only stat'd. We do that by making the file
    // unreadable (mode 000, no read permission for anyone, including the owner)
    // and confirming the check still produces its correct, fully-detailed warning.
    // A check that calls e.g. `String(contentsOf:)` or `Data(contentsOf:)` would
    // throw on a mode-000 file; only a check that limits itself to
    // `FileManager.fileExists`/`stat` (which needs no read permission on the file
    // itself, only search permission on its containing directory) can pass this.
    @Test("the legacy key file is never opened — only its existence is checked")
    func legacyKeyFileWarnsEvenWhenUnreadable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "AGE-SECRET-KEY-1QUNREADABLEUNREADABLEUNREADABLE\n".write(
            to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyFile.path)
        defer {
            // Restore permissions so the temp-directory cleanup that follows this
            // test (and the OS's own tmp-dir sweep) can actually delete the file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        }

        let legacy = finding(await makeCheck(legacyKeyFilePath: keyFile.path).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .warning)
        #expect(legacy.detail.contains(keyFile.path))
        #expect(legacy.remediation != nil)
    }
}
