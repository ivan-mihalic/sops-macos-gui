import Foundation
import ScratchCleanup
import Testing
@testable import SopsHealth

/// A GUI app launched from Finder inherits a minimal environment. `ToolLocator`
/// exists in this same module for exactly that reason and says so in its header
/// — "so `which sops` reports 'missing' on a machine that has it" — and
/// PROPOSAL §6 A requires the fix for tools. The key-file probe never got it.
///
/// The consequence is not a missing tool but a **security all-clear**: with
/// `export SOPS_AGE_KEY_FILE=~/keys/prod.txt` in a shell profile, the app looks
/// at two paths that variable overrides, finds nothing, and reports "No
/// unprotected age key file was found at any of the places sops reads one
/// from" — a sentence about sops's resolution order, over a list computed with
/// an empty environment. Settings then disables the import button saying there
/// is no key file to import.
@Suite("The key-file probe sees the login shell, not just the launch environment")
struct AgeKeyFileEnvironmentTests {

    /// The Finder case: nothing in the process environment, the override only
    /// in the login shell.
    @Test("SOPS_AGE_KEY_FILE set only in the login shell is still searched")
    func loginShellOverrideIsSearched() {
        let paths = AgeKeyFileLocations.candidates(
            environment: [:],
            homeDirectory: "/Users/probe",
            loginShellEnvironment: { ["SOPS_AGE_KEY_FILE": "/Users/probe/keys/prod.txt"] })

        #expect(paths.first == "/Users/probe/keys/prod.txt",
                "sops reads SOPS_AGE_KEY_FILE first, so it must be searched first: \(paths)")
    }

    @Test("XDG_CONFIG_HOME set only in the login shell moves the search")
    func loginShellXDGIsHonoured() {
        let paths = AgeKeyFileLocations.candidates(
            environment: [:],
            homeDirectory: "/Users/probe",
            loginShellEnvironment: { ["XDG_CONFIG_HOME": "/Users/probe/xdg"] })

        #expect(paths.contains("/Users/probe/xdg/sops/age/keys.txt"),
                "the darwin branch of sops's getUserConfigDir was not followed: \(paths)")
    }

    /// The process environment is the more specific answer — launched from a
    /// terminal that set it, that is the value sops would see.
    @Test("the launch environment wins over the login shell")
    func processEnvironmentTakesPrecedence() {
        let paths = AgeKeyFileLocations.candidates(
            environment: ["SOPS_AGE_KEY_FILE": "/Users/probe/launch.txt"],
            homeDirectory: "/Users/probe",
            loginShellEnvironment: { ["SOPS_AGE_KEY_FILE": "/Users/probe/shell.txt"] })

        #expect(paths.first == "/Users/probe/launch.txt")
        #expect(!paths.contains("/Users/probe/shell.txt"))
    }

    /// A login shell that says nothing must leave the ordinary answer alone,
    /// or every Mac without these variables gains phantom paths.
    @Test("a silent login shell changes nothing")
    func silentLoginShellIsHarmless() {
        let withShell = AgeKeyFileLocations.candidates(
            environment: [:], homeDirectory: "/Users/probe", loginShellEnvironment: { [:] })
        let withoutShell = AgeKeyFileLocations.candidates(
            environment: [:], homeDirectory: "/Users/probe", loginShellEnvironment: { [:] })

        #expect(withShell == withoutShell)
        #expect(withShell == [
            "/Users/probe/Library/Application Support/sops/age/keys.txt",
            "/Users/probe/.config/sops/age/keys.txt",
        ])
    }

    /// `SOPS_AGE_KEY` holds key *material*, not a path. It is deliberately not
    /// read here, and asking the login shell must not start reading it by
    /// accident — a variable whose value is a secret must never enter this
    /// process as a side effect of looking for file paths.
    @Test("the login shell probe never asks for the variable that holds key material")
    func keyMaterialVariableIsNeverRequested() {
        var requested: [String] = []
        _ = AgeKeyFileLocations.loginShellPathVariables { names, _ in
            requested = names
            return [:]
        }
        #expect(!requested.contains("SOPS_AGE_KEY"),
                "the probe asked the login shell for a variable that holds an age private key")
        #expect(Set(requested) == ["SOPS_AGE_KEY_FILE", "XDG_CONFIG_HOME"],
                "the probe asks for something other than the two path variables: \(requested)")
    }

    /// The real machine, end to end: whatever this Mac's login shell says, the
    /// probe must return the same answer as asking that shell directly.
    /// Against a real shell, named explicitly.
    ///
    /// **Not** `$SHELL`: `ToolLocatorTests` calls `setenv("SHELL", …)` with a
    /// path that does not exist, process-wide, and Swift Testing runs suites in
    /// one process in parallel — so a test that reads `$SHELL` is reading
    /// whichever sibling wrote to it last. That is the same class of defect as
    /// the login-shell probe itself and it made this test fail against a shell
    /// nobody chose.
    @Test("against a real login shell",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/zsh"), "zsh is required"))
    func realLoginShellAgrees() throws {
        let shell = "/bin/zsh"
        guard let probed = AgeKeyFileLocations.readFromLoginShell(
            ["SOPS_AGE_KEY_FILE", "XDG_CONFIG_HOME"], shell) else {
            Issue.record(Comment(rawValue:
                "inconclusive: the login-shell probe did not finish inside its timeout on this run"))
            return
        }

        for name in ["SOPS_AGE_KEY_FILE", "XDG_CONFIG_HOME"] {
            #expect(probed[name] ?? "" == Self.ask(shell, name),
                    Comment(rawValue: "the probe and the login shell disagree about \(name)"))
        }
    }

    private static func ask(_ shell: String, _ name: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "printf %s \"${\(name)-}\""]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The probe spawns a login shell, and `KeyImportView` resolves its key-file
/// options from `init` — which SwiftUI runs on every rebuild. An uncached probe
/// would put a ~95 ms process spawn in the render path.
@Suite("The login shell is asked once, not once per view rebuild", .serialized)
struct AgeKeyFileProbeCostTests {

    @Test("repeated calls do not repeatedly spawn a shell")
    func theProbeIsAskedOncePerProcess() {
        // Warm it, so the measurement below is of the cached path and not of
        // whichever call happened to be first in the whole test run.
        _ = AgeKeyFileLocations.cachedLoginShellPathVariables()

        let started = ContinuousClock.now
        for _ in 0..<200 { _ = AgeKeyFileLocations.cachedLoginShellPathVariables() }
        let elapsed = ContinuousClock.now - started

        // One spawn is ~95 ms; 200 of them would be ~19 s. A generous ceiling
        // that still cannot be met by spawning even once per call.
        #expect(elapsed < .milliseconds(500),
                "200 lookups took \(elapsed) — the login shell is being spawned per call")
    }

    /// Only meaningful when a fresh probe succeeds. It can fail transiently —
    /// the 3 s timeout is reachable under ThreadSanitizer, which is how the
    /// permanent-failure-caching defect was found — and comparing a good cached
    /// answer against a timed-out fresh one proves nothing about the cache.
    @Test("the cached answer is the same one the uncached probe gives")
    func cacheDoesNotChangeTheAnswer() throws {
        guard let fresh = AgeKeyFileLocations.loginShellPathVariables(
            runLoginShell: { names, _ in
                AgeKeyFileLocations.readFromLoginShell(names, "/bin/zsh") }) else {
            Issue.record(Comment(rawValue:
                "inconclusive: the login-shell probe did not finish inside its timeout on this run"))
            return
        }
        let storage = AgeKeyFileLocations.Storage()
        #expect(AgeKeyFileLocations.cachedLoginShellPathVariables(
            probe: { AgeKeyFileLocations.readFromLoginShell(
                ["SOPS_AGE_KEY_FILE", "XDG_CONFIG_HOME"], "/bin/zsh") },
            storage: storage) == fresh)
    }

    /// A probe that failed must not be remembered as "no variables set" — that
    /// is a false all-clear held for the rest of the process.
    @Test("a failed probe is not cached as an answer")
    func failureIsNotCached() {
        #expect(AgeKeyFileLocations.loginShellPathVariables { _, _ in nil } == nil,
                "a failed probe reported an answer instead of a failure")
    }
}

/// A login shell prints. The first version of the probe took the first
/// NUL-delimited field of stdout+stderr, so a greeting in `.zprofile` was
/// prepended to `SOPS_AGE_KEY_FILE` and the security all-clear went back to
/// being wrong — over a real key file, at the exported path.
@Suite("A talkative login shell does not corrupt the probe", .serialized)
struct AgeKeyFileNoisyShellTests {

    private static let zsh = "/bin/zsh"

    private func sandbox(profile: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("noisy-shell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(directory)
        try profile.write(to: directory.appendingPathComponent(".zprofile"),
                          atomically: true, encoding: .utf8)
        return directory
    }

    /// `ZDOTDIR` makes zsh read our `.zprofile` instead of the machine's, so
    /// this exercises a real login shell without touching the user's own.
    ///
    /// **Calls `readFromLoginShell`.** The version this replaces built its own
    /// `Process`, its own script and its own copy of the marker-strip — so the
    /// test named after the defect asserted against a private reimplementation
    /// of the fix, and deleting the entire marker mechanism from production
    /// left it, and all 26 tests in this file, green.
    private func probe(in directory: URL) -> [String: String]? {
        AgeKeyFileLocations.readFromLoginShell(
            ["SOPS_AGE_KEY_FILE", "XDG_CONFIG_HOME"], Self.zsh,
            environment: ["ZDOTDIR": directory.path, "HOME": directory.path])
    }

    @Test("a profile that greets the user does not become part of the key path",
          .enabled(if: FileManager.default.isExecutableFile(atPath: AgeKeyFileNoisyShellTests.zsh),
                   "zsh is required"))
    func greetingDoesNotCorruptThePath() throws {
        let keyFile = "/Users/probe/keys/prod.txt"
        let directory = try sandbox(profile: """
            echo "=== welcome to my mac ==="
            export SOPS_AGE_KEY_FILE="\(keyFile)"
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = probe(in: directory)

        #expect(found?["SOPS_AGE_KEY_FILE"] == keyFile,
                "the profile's greeting was read as part of the key file path: \(found as Any)")
    }

    /// A shell that cannot run the script at all must yield nothing, not turn
    /// its own usage message into a path. `/bin/tcsh` ships with macOS, is in
    /// `/etc/shells`, and does not accept `-lc`.
    @Test("a shell that cannot run the probe yields nothing",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/bin/tcsh"), "tcsh is required"))
    func unusableShellYieldsNothing() {
        #expect(AgeKeyFileLocations.readFromLoginShell(
            ["SOPS_AGE_KEY_FILE", "XDG_CONFIG_HOME"], "/bin/tcsh") == nil,
            "an unusable shell's error output became a key file path")
    }

    @Test("a shell that does not exist yields nothing") 
    func missingShellYieldsNothing() {
        #expect(AgeKeyFileLocations.readFromLoginShell(
            ["SOPS_AGE_KEY_FILE"], "/no/such/shell") == nil)
    }

    /// The marker was a fixed constant and `range(of:)` takes the **first**
    /// match, so a profile that printed it took over every field — verified
    /// with a real zsh, which returned the profile's decoy paths and never saw
    /// the genuinely exported value. `.backwards` is not the fix; a nonce the
    /// profile cannot know is.
    @Test("a profile that prints the marker cannot hijack the fields",
          .enabled(if: FileManager.default.isExecutableFile(atPath: AgeKeyFileNoisyShellTests.zsh),
                   "zsh is required"))
    func markerCannotBeSpoofed() throws {
        let real = "/Users/probe/keys/REAL-prod.txt"
        let guessed = AgeKeyFileLocations.freshProbeMarker()
        let directory = try sandbox(profile: """
            printf %s '\(guessed)'
            printf %s '/Users/probe/keys/DECOY.txt'; printf '\\0'
            printf %s '/Users/probe/DECOY-XDG'; printf '\\0'
            export SOPS_AGE_KEY_FILE="\(real)"
            """)
        defer { try? FileManager.default.removeItem(at: directory) }

        let found = probe(in: directory)

        #expect(found?["SOPS_AGE_KEY_FILE"] == real,
                "a profile printing a marker took over the probe's fields: \(found as Any)")
    }
}

/// The cache, reached through its injection seam. Without one, its failure
/// branch is unreachable from any test and reverting the successes-only rule
/// leaves the suite green.
@Suite("The login-shell cache remembers successes only")
struct AgeKeyFileCacheTests {

    @Test("a failed probe is not stored as an answer")
    func failureIsNotStored() {
        let storage = AgeKeyFileLocations.Storage()
        var calls = 0
        let first = AgeKeyFileLocations.cachedLoginShellPathVariables(
            probe: { calls += 1; return nil }, storage: storage)
        #expect(first == nil, "a failed probe was reported as an answer")

        let second = AgeKeyFileLocations.cachedLoginShellPathVariables(
            probe: { calls += 1; return ["SOPS_AGE_KEY_FILE": "/Users/probe/late.txt"] }, storage: storage)
        #expect(second?["SOPS_AGE_KEY_FILE"] == "/Users/probe/late.txt",
                "the failure was remembered, so a single unlucky probe holds a false all-clear for the session")
        #expect(calls == 2)
    }

    @Test("a successful probe is stored")
    func successIsStored() {
        let storage = AgeKeyFileLocations.Storage()
        var calls = 0
        _ = AgeKeyFileLocations.cachedLoginShellPathVariables(
            probe: { calls += 1; return ["XDG_CONFIG_HOME": "/Users/probe/xdg"] }, storage: storage)
        _ = AgeKeyFileLocations.cachedLoginShellPathVariables(probe: { calls += 1; return [:] }, storage: storage)
        #expect(calls == 1, "the cache re-probed after a success")
    }
}
