import Foundation
import LocalAuthentication
import SopsEngine

/// Whether the user has agreed to let this app ask GitHub for the latest sops
/// and age releases (PROPOSAL.md §6 B, §4).
///
/// This exists because the flag it replaces was hardcoded `false` in
/// `SopsGUIApp.swift` with no way to change it anywhere in the app — so §6 B
/// never ran, for anyone, ever, and every user read "this may be because
/// update checks are turned off, this Mac is offline, or GitHub did not
/// respond — this app can't tell which" on every launch. The app knew exactly
/// which: it was its own constant.
///
/// Default off, and it stays off until the user says otherwise: this gates the
/// only network request the app makes on its own.
///
/// "On its own" is load-bearing, and it was not always true. The app also runs
/// external binaries, and `sops --version` contacts `api.github.com` by default
/// from sops 3.8 onward — so `ExternalToolCheck` used to cause a GitHub request
/// on first launch, before this consent flag had been shown to anyone, while
/// the copy below it said "Nothing was sent anywhere". The probe now passes
/// `--disable-version-check`; see `ExternalToolCheck.requirements` and
/// `ExternalToolNetworkTests`. Anything added to that check in future has to
/// clear the same bar. `UserDefaults.bool(forKey:)`
/// returns `false` for a key that was never written, so "unset" and "declined"
/// are the same thing, which is the safe direction for a consent flag.
public enum UpdateCheckConsent {
    public static let defaultsKey = "updates.engineUpdateChecksEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
    }
}

extension HealthReport {

    /// The report shown in the wizard and the Settings panel.
    ///
    /// `keyStore` and `appUpdates` take no default. Ticket #15: they used to
    /// default to `UnshippedKeyStore()` / `UnshippedAppUpdates()`, on the
    /// premise that those subjects had not shipped yet — true for the key
    /// store (M3 genuinely has not landed), false for app updates, which
    /// Sparkle has supplied since 0.1.0 (`App/SopsGUIApp.swift`). A default
    /// meant a caller that simply *forgot* one of these arguments got a
    /// stand-in silently — wrong data, no compile error, no test failure, and
    /// (for app updates) text describing a milestone that had already
    /// happened. Requiring both here makes that omission a compile error
    /// instead. A caller that genuinely wants the stand-in — most tests in
    /// this package, which exercise the other checks — still can, by naming
    /// `UnshippedKeyStore()` / `UnshippedAppUpdates()` explicitly; that
    /// keeps `SopsGUIKit` buildable and testable without wiring in a real,
    /// Sparkle-backed updater, which is what the removed defaults were
    /// actually protecting, just implicitly instead of by name.
    ///
    /// `updateChecksEnabled` is a closure, not a `Bool`: the report is built
    /// once and re-run many times, so a captured value would freeze the user's
    /// consent at whatever it was when the app launched and quietly ignore the
    /// toggle for the rest of the session.
    public static func standard(
        updateChecksEnabled: @escaping @Sendable () -> Bool,
        projects: any ProjectSourceProviding = NoProjects(),
        keyStore: any KeyStoreStatusProviding,
        biometry: any BiometryStatusProviding = SystemBiometry(),
        appUpdates: any AppUpdateStatusProviding
    ) -> HealthReport {
        // Optional, never defaulted to a version number. An unreadable engine
        // version used to become 0.0.0, which loses every comparison — see
        // `EngineVersion.unknown`.
        let embeddedSops = SemanticVersion(parsing: EngineVersion.sops)
        let embeddedAge = SemanticVersion(parsing: EngineVersion.age)

        let os = ProcessInfo.processInfo.operatingSystemVersion

        let legacyKeyFiles = AgeKeyFileLocations.resolved()

        return HealthReport(checks: [
            ExternalToolCheck(locator: ToolLocator(), embeddedSopsVersion: embeddedSops),
            EngineFreshnessCheck(
                embeddedSops: embeddedSops, embeddedAge: embeddedAge,
                upstream: GitHubReleaseSource(isEnabled: updateChecksEnabled)),
            SecurityPostureCheck(
                osVersion: SemanticVersion(os.majorVersion, os.minorVersion, os.patchVersion),
                // 26.0, matching `Package.swift`, `project.yml`
                // (`LSMinimumSystemVersion`) and `build-xcframework.sh`. This
                // said 14.0 — a fourth copy, and the only one that disagreed,
                // against CLAUDE.md's "deployment target is one variable".
                //
                // It also made the check vacuous: `LSMinimumSystemVersion` is
                // 26.0, so the app cannot launch below it, so the `.problem`
                // branch was unreachable and `security.os` could only ever
                // return `.ok`. A check that cannot fail is not a check, and
                // its "is below the minimum this app supports" text would have
                // been false if it ever appeared.
                minimumOSVersion: SemanticVersion(26, 0, 0),
                keyStore: keyStore, biometry: biometry, appUpdates: appUpdates,
                // Every place the embedded sops actually reads a key file
                // from, not the one path this used to hardcode — which was
                // `~/.config/sops/age/keys.txt`, a location sops does not read
                // on macOS at all. See `AgeKeyFileLocations`.
                legacyKeyFilePaths: legacyKeyFiles.paths,
                legacyKeyFileProbeFailed: legacyKeyFiles.loginShellUnavailable),
            ProjectHealthCheck(source: projects),
        ])
    }
}

public struct NoProjects: ProjectSourceProviding {
    public init() {}
    public let projects: [InspectedProject] = []
}

public struct UnshippedKeyStore: KeyStoreStatusProviding {
    public init() {}
    public let state = KeyStoreState.unavailable(reason: "Keychain key storage arrives in M3.")
}

/// Despite the name, app-update checking has shipped — Sparkle has supplied
/// it since 0.1.0 (`App/SopsGUIApp.swift`, `App/Updater.swift`). This type is
/// not "the feature before it existed"; it is the explicit stand-in a caller
/// passes to `HealthReport.standard` when it does not care about app-update
/// status (most tests in this package). Its reason text says exactly that,
/// rather than naming a milestone that already happened — see ticket #15.
public struct UnshippedAppUpdates: AppUpdateStatusProviding {
    public init() {}
    public let state = AppUpdateState.unavailable(
        reason: "This report was not given a real app-update status provider.")
}

public struct SystemBiometry: BiometryStatusProviding {
    public init() {}

    public var state: BiometryState {
        let context = LAContext()
        var error: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) {
            return .available
        }
        return switch error?.code {
        case LAError.biometryNotEnrolled.rawValue: .notEnrolled
        case LAError.biometryNotAvailable.rawValue:
            .unavailable(reason: "This Mac has no Touch ID hardware.")
        default: .unavailable(reason: "Touch ID is not available right now.")
        }
    }
}
