import Foundation
import LocalAuthentication
import SopsEngine

extension HealthReport {

    /// The report shown in the wizard and the Settings panel.
    ///
    /// Subjects that have not shipped yet are injected as stubs that report
    /// `.skipped` with a reason, so the check is real and tested from day one.
    public static func standard(
        updateChecksEnabled: Bool,
        projects: any ProjectSourceProviding = NoProjects(),
        keyStore: any KeyStoreStatusProviding = UnshippedKeyStore(),
        biometry: any BiometryStatusProviding = SystemBiometry(),
        appUpdates: any AppUpdateStatusProviding = UnshippedAppUpdates()
    ) -> HealthReport {
        let embeddedSops = SemanticVersion(parsing: EngineVersion.sops) ?? SemanticVersion(0, 0, 0)
        let embeddedAge = SemanticVersion(parsing: EngineVersion.age) ?? SemanticVersion(0, 0, 0)

        let os = ProcessInfo.processInfo.operatingSystemVersion

        return HealthReport(checks: [
            ExternalToolCheck(locator: ToolLocator(), embeddedSopsVersion: embeddedSops),
            EngineFreshnessCheck(
                embeddedSops: embeddedSops, embeddedAge: embeddedAge,
                upstream: GitHubReleaseSource(isEnabled: { updateChecksEnabled })),
            SecurityPostureCheck(
                osVersion: SemanticVersion(os.majorVersion, os.minorVersion, os.patchVersion),
                minimumOSVersion: SemanticVersion(14, 0, 0),
                keyStore: keyStore, biometry: biometry, appUpdates: appUpdates,
                legacyKeyFilePath: NSHomeDirectory() + "/.config/sops/age/keys.txt"),
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

public struct UnshippedAppUpdates: AppUpdateStatusProviding {
    public init() {}
    public let state = HealthStatus.skipped(reason: "Update checking arrives with Sparkle in M5.")
    public let detail = ""
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
