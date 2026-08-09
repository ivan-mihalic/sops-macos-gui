import Foundation
import Testing
@testable import SopsHealth

private struct FakeKeyStore: KeyStoreStatusProviding { let state = KeyStoreState.configured }
private struct FakeBiometry: BiometryStatusProviding { let state = BiometryState.available }
private struct FakeUpdates: AppUpdateStatusProviding {
    let state = AppUpdateState.upToDate(version: "1.0.0")
}

private func check(_ paths: [String]) -> SecurityPostureCheck {
    SecurityPostureCheck(osVersion: SemanticVersion(26, 5, 2),
                         minimumOSVersion: SemanticVersion(14, 0, 0),
                         keyStore: FakeKeyStore(), biometry: FakeBiometry(),
                         appUpdates: FakeUpdates(), legacyKeyFilePaths: paths)
}

private func legacyFinding(_ findings: [HealthFinding]) -> HealthFinding {
    findings.first { $0.id == "security.legacy-key-file" }!
}

/// An M1 defect in the same honesty family as the §6 D project work.
///
/// `HealthReport.standard` built one path — `NSHomeDirectory() +
/// "/.config/sops/age/keys.txt"` — and `SecurityPostureCheck` stated "No
/// unprotected age key file was found" on the strength of one `stat` of it,
/// without naming the path it had checked. On macOS that is not where the
/// embedded sops reads a key file from, so the all-clear was about a place
/// sops does not use, and a real plaintext key in the place it *does* use went
/// unmentioned.
@Suite("age key file locations")
struct AgeKeyFileLocationTests {

    /// The macOS branch of the pinned v3.13.3's own `getUserConfigDir`:
    /// `os.UserConfigDir()` when `XDG_CONFIG_HOME` is unset, which on this
    /// platform is `$HOME/Library/Application Support`.
    @Test("with no environment set, the Library path sops actually reads is checked")
    func libraryPathIsTheDefault() {
        let paths = AgeKeyFileLocations.candidates(environment: [:], homeDirectory: "/Users/probe")

        #expect(paths.first == "/Users/probe/Library/Application Support/sops/age/keys.txt",
                "sops reads os.UserConfigDir() on macOS, not ~/.config: \(paths)")
        #expect(paths.contains("/Users/probe/.config/sops/age/keys.txt"),
                "the conventional path is still a plaintext key on disk: \(paths)")
    }

    /// sops's darwin special case: `XDG_CONFIG_HOME` wins over
    /// `os.UserConfigDir()` when it is set and non-empty.
    @Test("XDG_CONFIG_HOME replaces the Library path, as it does for sops")
    func xdgConfigHomeWins() {
        let paths = AgeKeyFileLocations.candidates(
            environment: ["XDG_CONFIG_HOME": "/elsewhere/cfg"], homeDirectory: "/Users/probe")

        #expect(paths.contains("/elsewhere/cfg/sops/age/keys.txt"))
        #expect(!paths.contains("/Users/probe/Library/Application Support/sops/age/keys.txt"))
    }

    /// An empty value is not a value — `os.LookupEnv` reports it as present,
    /// and sops explicitly requires it to be non-empty before using it.
    @Test("an empty XDG_CONFIG_HOME is ignored, as sops ignores it")
    func emptyXDGIsIgnored() {
        let paths = AgeKeyFileLocations.candidates(
            environment: ["XDG_CONFIG_HOME": ""], homeDirectory: "/Users/probe")

        #expect(paths.contains("/Users/probe/Library/Application Support/sops/age/keys.txt"))
    }

    @Test("SOPS_AGE_KEY_FILE is checked, and checked first")
    func explicitEnvironmentPathIsFirst() {
        let paths = AgeKeyFileLocations.candidates(
            environment: ["SOPS_AGE_KEY_FILE": "/opt/keys/age.txt"], homeDirectory: "/Users/probe")

        #expect(paths.first == "/opt/keys/age.txt")
        #expect(paths.count == 3, "the other two are still worth stat-ing: \(paths)")
    }

    @Test("a path named twice is stat'd once")
    func duplicatesCollapse() {
        let paths = AgeKeyFileLocations.candidates(
            environment: ["SOPS_AGE_KEY_FILE": "/Users/probe/.config/sops/age/keys.txt"],
            homeDirectory: "/Users/probe")

        #expect(Set(paths).count == paths.count, "\(paths)")
    }

    // MARK: - The shared existence question and the shared remediation

    /// `SecurityPostureCheck` and `KeyImportView`'s import control both need
    /// "is there a regular file here?", and this is the one place that answers
    /// it. A second copy is how the path list itself came to disagree with
    /// itself — see this type's doc comment.
    @Test("a directory sitting where a key file would be is not a key file")
    func directoryIsNotAKeyFile() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-" + UUID().uuidString)
        let directory = home.appendingPathComponent(".config/sops/age/keys.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AgeKeyFileLocations.candidates(environment: [:], homeDirectory: home.path)
        #expect(AgeKeyFileLocations.existingFiles(among: paths).isEmpty,
                "a `mkdir -p keys.txt` is not a plaintext key")
        #expect(!AgeKeyFileLocations.isRegularFile(directory.path))
    }

    @Test("existingFiles keeps the order it was given")
    func existingFilesPreservesOrder() {
        let paths = ["/a/keys.txt", "/b/keys.txt", "/c/keys.txt"]
        let found = AgeKeyFileLocations.existingFiles(among: paths) { $0 != "/b/keys.txt" }

        #expect(found == ["/a/keys.txt", "/c/keys.txt"])
    }

    /// One `chmod 600`, built in one place, so the health finding's
    /// remediation and the import view's post-import callout cannot say
    /// different things about the same file.
    @Test("the protect command single-quotes every path it names")
    func protectCommandQuotes() throws {
        let command = try #require(
            AgeKeyFileLocations.protectCommand(for: ["/Users/probe/a b/keys.txt", "/x/keys.txt"]))

        #expect(command == "chmod 600 '/Users/probe/a b/keys.txt' '/x/keys.txt'")
    }

    /// `ShellQuoting` refuses a name no single-line command can carry, and
    /// this must pass that refusal along rather than emit a command that
    /// silently spans two lines. Reachable: `SOPS_AGE_KEY_FILE` is a user
    /// -settable environment variable and may hold anything.
    @Test("a path no single-line command can name yields no command")
    func protectCommandRefusesUnquotablePath() {
        #expect(AgeKeyFileLocations.protectCommand(for: ["/x/keys\n.txt"]) == nil)
    }

    // MARK: - What the finding says

    /// The defect this suite exists for. An all-clear that names nothing is
    /// indistinguishable from an all-clear produced by looking in the wrong
    /// place, which is exactly what was happening.
    @Test("the all-clear names every path it checked")
    func allClearNamesWhatItChecked() async {
        let paths = ["/nonexistent/a/keys.txt", "/nonexistent/b/keys.txt"]
        let finding = legacyFinding(await check(paths).run())

        #expect(finding.status == .ok)
        for path in paths {
            #expect(finding.detail.contains(path),
                    "an all-clear must say where it looked: \(finding.detail)")
        }
    }

    /// A key file in the Library location — the one the old single-path check
    /// could not see — is a warning that names it.
    @Test("a key file only in the Library location is still found")
    func keyFileInLibraryLocationIsFound() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-" + UUID().uuidString)
        let library = home.appendingPathComponent("Library/Application Support/sops/age")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let keyFile = library.appendingPathComponent("keys.txt")
        try "# created by age-keygen\n".write(to: keyFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AgeKeyFileLocations.candidates(environment: [:], homeDirectory: home.path)
        let finding = legacyFinding(await check(paths).run())

        #expect(finding.status == .warning)
        #expect(finding.detail.contains(keyFile.path))
        #expect(finding.remediation?.command?.contains("chmod 600") == true)
    }

    /// Two files at once, both named, and one command that covers both.
    @Test("two key files are both named, in one remediation")
    func twoKeyFilesAreBothNamed() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-" + UUID().uuidString)
        var written: [String] = []
        for relative in ["Library/Application Support/sops/age", ".config/sops/age"] {
            let directory = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let keyFile = directory.appendingPathComponent("keys.txt")
            try "# created by age-keygen\n".write(to: keyFile, atomically: true, encoding: .utf8)
            written.append(keyFile.path)
        }
        defer { try? FileManager.default.removeItem(at: home) }

        let paths = AgeKeyFileLocations.candidates(environment: [:], homeDirectory: home.path)
        let finding = legacyFinding(await check(paths).run())

        #expect(finding.status == .warning)
        for path in written { #expect(finding.detail.contains(path), "\(finding.detail)") }
        let command = try #require(finding.remediation?.command)
        for path in written { #expect(command.contains(path), "\(command)") }
    }

    /// "Nowhere to look" is not "nothing there". Unreachable through
    /// `HealthReport.standard`, pinned so it stays unreachable *and* honest.
    @Test("an empty list of places to look is not an all-clear")
    func noPathsIsNotAnAllClear() async {
        let finding = legacyFinding(await check([]).run())

        #expect(finding.status != .ok)
        guard case .unknown(let reason) = finding.status else {
            Issue.record("expected unknown, got \(finding.status)")
            return
        }
        #expect(!reason.isEmpty)
    }

    /// The report the app actually builds must be pointed at the real
    /// locations, not just the helper that computes them.
    @Test("the standard report checks the Library path")
    func standardReportUsesTheRealLocations() {
        let expected = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Application Support/sops/age/keys.txt")

        #expect(AgeKeyFileLocations.candidates().contains(expected)
                    || ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] != nil,
                "the default candidate list must include the path sops reads on macOS")
    }
}
