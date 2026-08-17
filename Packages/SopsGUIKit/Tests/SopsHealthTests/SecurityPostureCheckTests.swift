import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

private struct FakeKeyStore: KeyStoreStatusProviding { let state: KeyStoreState }
private struct FakeBiometry: BiometryStatusProviding { let state: BiometryState }
private struct FakeUpdates: AppUpdateStatusProviding {
    let state: AppUpdateState
}
private struct FakeSessionTTL: SessionTTLStatusProviding { let state: SessionTTLState }

private func finding(_ findings: [HealthFinding], _ id: String) -> HealthFinding {
    findings.first { $0.id == id }!
}

private func makeCheck(
    os: SemanticVersion = SemanticVersion(26, 5, 2),
    keyStore: KeyStoreState = .configured,
    biometry: BiometryState = .available,
    updates: AppUpdateState = .upToDate(version: "1.0.0"),
    legacyKeyFilePaths: [String] = ["/nonexistent/keys.txt"],
    sessionTTL: SessionTTLState = .enforced(minutes: 15)
) -> SecurityPostureCheck {
    SecurityPostureCheck(
        osVersion: os,
        minimumOSVersion: SemanticVersion(14, 0, 0),
        keyStore: FakeKeyStore(state: keyStore),
        biometry: FakeBiometry(state: biometry),
        appUpdates: FakeUpdates(state: updates),
        legacyKeyFilePaths: legacyKeyFilePaths,
        sessionTTL: FakeSessionTTL(state: sessionTTL))
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

    /// The third copy of the wrong path, and the one a user would trust most.
    ///
    /// This remediation used to end "…or import it from
    /// ~/.config/sops/age/keys.txt" — a place the embedded sops does not read
    /// on macOS (`AgeKeyFileLocations`) and a place the import control may
    /// well not offer. A health report telling the user to go to a file that
    /// is not there, next to a sibling finding that correctly named
    /// `Library/Application Support`, is worse than saying nothing: it
    /// contradicts the app's own check. It names no path now — which file, if
    /// any, exists is `LegacyKeyFileImportOptions`' answer at the moment the
    /// user is standing in front of the control.
    @Test("the missing-key remediation points at the app, never at a guessed path")
    func missingKeyRemediationNamesNoPath() async throws {
        let keystore = finding(await makeCheck(keyStore: .empty).run(), "security.keystore")
        let explanation = try #require(keystore.remediation?.explanation)

        #expect(explanation.contains("Settings"), "it must still say where to go: \(explanation)")
        for fragment in ["keys.txt", "~/.config", "sops/age", "Application Support"] {
            #expect(!explanation.contains(fragment),
                    "this check cannot know which key file exists, so it must name none: \(explanation)")
        }
    }

    /// Deliberately rewritten from asserting `.warning`, and the reason is the
    /// point rather than a detail.
    ///
    /// A warning is a claim: *this is worth your attention now.* Nothing in
    /// this build depends on an enrolled fingerprint — `evaluatePolicy` is
    /// never called, so no key is gated on biometrics — which made the warning
    /// part of the same overclaim as the wording beside it (`BiometryClaimTests`).
    /// It also coloured the whole report's headline, since the headline is the
    /// single worst finding.
    ///
    /// `.skipped` is what is true: the subject this would be about does not
    /// exist yet. The remediation stays, so a user who wants to be ready for
    /// Keychain storage still gets told where to enrol one.
    @Test("biometry not enrolled is skipped — nothing here depends on it yet")
    func biometryNotEnrolledIsSkipped() async {
        let biometry = finding(await makeCheck(biometry: .notEnrolled).run(), "security.biometry")
        guard case .skipped = biometry.status else {
            Issue.record("expected .skipped, got \(biometry.status)")
            return
        }
        // Still actionable: the user is told where to enrol a fingerprint.
        #expect(biometry.remediation?.explanation.contains("System Settings") == true)
    }

    // The whole point of the Keychain model is that the key is not sitting in a
    // plaintext file. Finding one is the single most valuable thing this check does.
    //
    // Ticket #7: mode set explicitly to 0644 rather than left at whatever this
    // machine's umask produces — the point of this test is "world-readable
    // key file", and that must not depend on an ambient default that varies
    // by machine.
    @Test("a world-readable plaintext keys.txt is a problem, not merely a warning")
    func legacyKeyFileWorldReadableIsAProblem() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "# created by age-keygen\n".write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)

        let legacy = finding(await makeCheck(legacyKeyFilePaths: [keyFile.path]).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .problem)
        #expect(legacy.detail.contains(keyFile.path))
        #expect(legacy.detail.lowercased().contains("other account"),
                "a world-readable file must say so specifically: \(legacy.detail)")
        #expect(legacy.remediation?.command?.contains("chmod 600") == true)
    }

    /// The softer half of the same distinction: a `keys.txt` already
    /// restricted to its owner is still a finding — it is still an
    /// unencrypted key on disk — but it is not the same severity as one any
    /// account on the Mac can read, and there is nothing left for a `chmod`
    /// command to fix.
    @Test("an owner-only plaintext keys.txt still warns, but is not elevated and offers no command")
    func legacyKeyFileOwnerOnlyStaysAWarning() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "# created by age-keygen\n".write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)

        let legacy = finding(await makeCheck(legacyKeyFilePaths: [keyFile.path]).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .warning)
        #expect(legacy.detail.contains(keyFile.path))
        #expect(legacy.remediation?.command == nil,
                "chmod 600 on an already-0600 file fixes nothing and should not be offered")
    }

    /// Two files, opposite permissions: the worse one must win the overall
    /// severity, and only the actually-exposed path gets a command.
    @Test("a mix of world-readable and owner-only files is a problem, and only the exposed one gets a command")
    func mixedPermissionsElevatesAndNamesOnlyTheExposedFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let exposed = dir.appendingPathComponent("exposed-keys.txt")
        let safe = dir.appendingPathComponent("safe-keys.txt")
        try "a".write(to: exposed, atomically: true, encoding: .utf8)
        try "b".write(to: safe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exposed.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: safe.path)

        let legacy = finding(
            await makeCheck(legacyKeyFilePaths: [exposed.path, safe.path]).run(),
            "security.legacy-key-file")
        #expect(legacy.status == .problem)
        let command = try #require(legacy.remediation?.command)
        #expect(command.contains(exposed.path))
        #expect(!command.contains(safe.path),
                "the command must not suggest chmod-ing a file that is already owner-only: \(command)")
    }

    /// `AgeKeyFileLocations.protectCommand` refuses a path it cannot quote
    /// safely (a newline anywhere in it — `ShellQuoting.singleQuoted`) — this
    /// check must still tell the user *something* rather than silently
    /// dropping the command with no replacement, which is the defect ticket
    /// #7 exists to close (`SecurityPostureCheckTests` I8's twin,
    /// `AgeKeyFileLocationTests.protectCommandRefusesUnquotablePath`, proves
    /// `protectCommand` itself returns nil; this proves the check does not
    /// just drop the advice when that happens).
    ///
    /// A real file with a newline in its name — POSIX filenames may contain
    /// any byte but `/` and NUL, so this is a real file, not a synthetic
    /// path a `stat` would never actually see.
    @Test("a path no command can safely name still gets a usable explanation, not silence")
    func unquotablePathStillExplainsWhatToDo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-unquotable-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyFile = dir.appendingPathComponent("keys\n.txt")
        try "a".write(to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: keyFile.path)

        let legacy = finding(await makeCheck(legacyKeyFilePaths: [keyFile.path]).run(),
                             "security.legacy-key-file")
        #expect(legacy.remediation?.command == nil, "this path cannot be safely quoted")
        let explanation = try #require(legacy.remediation?.explanation)
        #expect(!explanation.isEmpty)
        #expect(explanation.lowercased().contains("chmod"),
                "the fallback must still tell the user which command to run by hand: \(explanation)")
        #expect(explanation.lowercased().contains("terminal") || explanation.lowercased().contains("by hand"),
                "the fallback must say the user has to run it themselves: \(explanation)")
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
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = finding(await makeCheck(legacyKeyFilePaths: [dir.path]).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .ok)
    }

    @Test("an unsupported macOS version is a problem")
    func oldOSIsAProblem() async {
        let os = finding(await makeCheck(os: SemanticVersion(13, 0, 0)).run(), "security.os")
        #expect(os.status == .problem)
    }

    // I6. "No age key is configured, so nothing can be decrypted" is a claim
    // about the whole machine. The user may hold keys in a keys.txt, a
    // password manager, a YubiKey or another Mac and decrypt with the sops CLI
    // perfectly well. The only fact this app has is about its own store.
    @Test("the missing-key finding is scoped to this app, not to the machine")
    func missingKeyClaimIsScopedToThisApp() async {
        let keystore = finding(await makeCheck(keyStore: .empty).run(), "security.keystore")
        let text = keystore.detail.lowercased()
        #expect(!text.contains("nothing can be decrypted"))
        #expect(text.contains("this app"))
    }

    // The row renders the skip reason and the detail one after the other.
    @Test("a skipped key store's reason and detail do not say the same thing")
    func skipReasonAndDetailAreNotDuplicated() async {
        let keystore = finding(
            await makeCheck(keyStore: .unavailable(reason: "Keychain storage arrives in M3.")).run(),
            "security.keystore")
        guard case .skipped(let reason) = keystore.status else {
            Issue.record("expected skipped, got \(keystore.status)")
            return
        }
        #expect(reason != keystore.detail)
        #expect(!keystore.detail.contains(reason))
    }

    // I7. The provider states a fact; this check decides what it is worth. A
    // provider that has checked nothing cannot express an all-clear.
    @Test("every app-update fact maps to a status this check chose, and only a completed check can be OK")
    func updateStatesMapHonestly() async {
        let cases: [(AppUpdateState, HealthStatus)] = [
            (.upToDate(version: "1.2.3"), .ok),
            (.updateAvailable(version: "1.3.0"), .warning),
            (.couldNotCheck(reason: "GitHub did not answer."),
             .unknown(reason: "GitHub did not answer.")),
        ]
        for (state, expected) in cases {
            let found = finding(await makeCheck(updates: state).run(), "security.app-updates")
            #expect(found.status == expected, "\(state) produced \(found.status)")
            #expect(!found.detail.isEmpty, "\(state) produced an empty detail")
        }

        // Neither "not shipped" nor "turned off" may present as OK.
        for state in [AppUpdateState.checksDisabled,
                      .unavailable(reason: "Update checking arrives with Sparkle in M5.")] {
            let found = finding(await makeCheck(updates: state).run(), "security.app-updates")
            #expect(found.status != .ok, "\(state) presented as OK")
            #expect(!found.detail.isEmpty)
        }
    }

    @Test("features that have not shipped report skipped with a reason, never a false OK")
    func unshippedFeaturesAreSkipped() async {
        let findings = await makeCheck(
            keyStore: .unavailable(reason: "Keychain storage arrives in M3."),
            updates: .unavailable(reason: "Update checking arrives with Sparkle in M5.")
        ).run()

        for id in ["security.keystore", "security.app-updates"] {
            guard case .skipped(let reason) = finding(findings, id).status else {
                Issue.record("\(id) should be skipped, got \(finding(findings, id).status)")
                continue
            }
            #expect(!reason.isEmpty, "a skipped check must say why")
        }
    }

    // MARK: - Session TTL (ticket #4)

    /// The provider states the policy in force; this check turns it into an
    /// informational finding. `.enforced` is the only outcome
    /// `SessionKeyStore.ttlHealthSource` can ever produce — the store has no
    /// "no TTL" mode — but the provider is still a protocol, not a `let`, for
    /// the same reason `KeyStoreStatusProviding` is: a fact a check depends on
    /// belongs behind a seam a test can fake, not a concrete type reaching
    /// into `SessionTTLPreference` itself.
    @Test("an enforced TTL is reported OK, naming the number of minutes")
    func enforcedTTLIsOK() async {
        let found = finding(await makeCheck(sessionTTL: .enforced(minutes: 15)).run(), "security.session-ttl")
        #expect(found.status == .ok)
        #expect(found.detail.contains("15"), "the finding must name the configured minutes: \(found.detail)")
    }

    @Test("an unavailable TTL provider is skipped, never a false OK")
    func unavailableTTLProviderIsSkipped() async {
        let found = finding(
            await makeCheck(sessionTTL: .unavailable(reason: "no session key store was wired in")).run(),
            "security.session-ttl")
        guard case .skipped(let reason) = found.status else {
            Issue.record("expected skipped, got \(found.status)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("no finding ever contains key material")
    func neverLeaksKeyMaterial() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("posture-" + UUID().uuidString)
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQ\n".write(to: keyFile, atomically: true, encoding: .utf8)

        for finding in await makeCheck(legacyKeyFilePaths: [keyFile.path]).run() {
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
        ScratchDirectoryRegistry.shared.register(dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
        let keyFile = dir.appendingPathComponent("keys.txt")
        try "AGE-SECRET-KEY-1QUNREADABLEUNREADABLEUNREADABLE\n".write(
            to: keyFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: keyFile.path)
        defer {
            // Restore permissions so the temp-directory cleanup that follows this
            // test (and the OS's own tmp-dir sweep) can actually delete the file.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyFile.path)
        }

        let legacy = finding(await makeCheck(legacyKeyFilePaths: [keyFile.path]).run(),
                             "security.legacy-key-file")
        #expect(legacy.status == .warning)
        #expect(legacy.detail.contains(keyFile.path))
        #expect(legacy.remediation != nil)
    }
}
