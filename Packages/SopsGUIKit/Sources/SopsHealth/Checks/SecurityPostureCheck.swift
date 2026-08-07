import Foundation

public enum KeyStoreState: Equatable, Sendable {
    case configured
    case empty
    /// The store itself is not available yet — e.g. the feature has not shipped.
    case unavailable(reason: String)
}

public protocol KeyStoreStatusProviding: Sendable {
    var state: KeyStoreState { get }
}

public enum BiometryState: Equatable, Sendable {
    case available
    case notEnrolled
    case unavailable(reason: String)
}

public protocol BiometryStatusProviding: Sendable {
    var state: BiometryState { get }
}

/// What an update-check implementation is allowed to report.
///
/// A closed set of *facts*, like `KeyStoreState` and `BiometryState` above,
/// rather than a `HealthStatus`. This used to be a raw `HealthStatus`, which
/// let the provider choose its own verdict — so a Sparkle implementation in M5
/// could return `.ok` without ever having checked anything, and nothing in the
/// type system would notice. The other two providers cannot do that: they can
/// only say what is true, and `SecurityPostureCheck` decides what each fact
/// deserves. This one now has the same shape, so a fabricated all-clear is not
/// expressible.
public enum AppUpdateState: Equatable, Sendable {
    /// A check completed: this is the latest release.
    case upToDate(version: String)
    /// A check completed: a newer release exists.
    case updateAvailable(version: String)
    /// A check was attempted and reached no verdict.
    case couldNotCheck(reason: String)
    /// The user has not turned update checks on. Distinct from
    /// `couldNotCheck` — nothing was attempted, and the app knows why.
    case checksDisabled
    /// The subject does not exist yet: the feature has not shipped.
    case unavailable(reason: String)
}

public protocol AppUpdateStatusProviding: Sendable {
    var state: AppUpdateState { get }
}

/// PROPOSAL.md §6 C. Everything here is read-only inspection of the local
/// machine and the app's own configuration.
///
/// The single most valuable thing this check does is flag a plaintext age key
/// file left behind by `age-keygen`/`sops` conventions at
/// `~/.config/sops/age/keys.txt` — the app's whole security model is that the
/// key lives in the Keychain behind Touch ID instead. That finding reports
/// only the file's *existence* (via `FileManager.fileExists`, a `stat`, not a
/// read). It never opens, parses, or logs the file's contents, and it never
/// deletes it — the app never mutates the system; it explains, and the user
/// acts.
public struct SecurityPostureCheck: HealthCheck {
    public let id = "security-posture"
    public let category = HealthCategory.security

    private let osVersion: SemanticVersion
    private let minimumOSVersion: SemanticVersion
    private let keyStore: any KeyStoreStatusProviding
    private let biometry: any BiometryStatusProviding
    private let appUpdates: any AppUpdateStatusProviding
    private let legacyKeyFilePath: String

    public init(osVersion: SemanticVersion,
                minimumOSVersion: SemanticVersion,
                keyStore: any KeyStoreStatusProviding,
                biometry: any BiometryStatusProviding,
                appUpdates: any AppUpdateStatusProviding,
                legacyKeyFilePath: String) {
        self.osVersion = osVersion
        self.minimumOSVersion = minimumOSVersion
        self.keyStore = keyStore
        self.biometry = biometry
        self.appUpdates = appUpdates
        self.legacyKeyFilePath = legacyKeyFilePath
    }

    public func run() async -> [HealthFinding] {
        [osFinding, biometryFinding, keyStoreFinding, legacyKeyFileFinding, appUpdateFinding]
    }

    private var osFinding: HealthFinding {
        osVersion >= minimumOSVersion
            ? HealthFinding(id: "security.os", title: "macOS version", status: .ok,
                            detail: "macOS \(osVersion).")
            : HealthFinding(id: "security.os", title: "macOS version", status: .problem,
                            detail: "macOS \(osVersion) is below the minimum \(minimumOSVersion) this app supports.",
                            remediation: Remediation(
                                explanation: "Update macOS in System Settings › General › Software Update."))
    }

    private var biometryFinding: HealthFinding {
        switch biometry.state {
        case .available:
            HealthFinding(id: "security.biometry", title: "Touch ID", status: .ok,
                          detail: "Touch ID is available for unlocking your key.")
        case .notEnrolled:
            HealthFinding(id: "security.biometry", title: "Touch ID", status: .warning,
                          detail: "No fingerprint is enrolled, so unlocking will fall back to your password.",
                          remediation: Remediation(
                              explanation: "Add a fingerprint in System Settings › Touch ID & Password."))
        case .unavailable(let reason):
            HealthFinding(id: "security.biometry", title: "Touch ID",
                          status: .skipped(reason: reason),
                          detail: "Unlocking will use your password instead.")
        }
    }

    private var keyStoreFinding: HealthFinding {
        switch keyStore.state {
        case .configured:
            HealthFinding(id: "security.keystore", title: "Your age key", status: .ok,
                          detail: "An age key is stored in your Keychain.")
        case .empty:
            // Scoped to this app, deliberately. "nothing can be decrypted" is
            // a claim about the whole machine, and the app has no basis for
            // it: the user may well hold keys in a `keys.txt`, in a password
            // manager, on a YubiKey, or on another machine entirely, and
            // decrypt with the sops CLI perfectly happily. The only fact here
            // is about this app's own Keychain entry.
            HealthFinding(id: "security.keystore", title: "Your age key", status: .problem,
                          detail: "No age key is configured in this app, so this app cannot decrypt anything. Keys you hold elsewhere are unaffected — this says nothing about them.",
                          remediation: Remediation(
                              explanation: "Generate a new key, or import an existing one, from the Keys section of this app."))
        case .unavailable(let reason):
            // The row renders the skip reason and the detail back to back, so
            // printing the same sentence into both read as a stutter.
            HealthFinding(id: "security.keystore", title: "Your age key",
                          status: .skipped(reason: reason),
                          detail: "Nothing about your key has been checked, and nothing here is a verdict on it.")
        }
    }

    /// A plaintext key file on disk defeats the point of Keychain storage.
    /// Only its existence is checked — via `fileExists`, which stats the path
    /// and needs no read permission on the file itself. The contents are
    /// never opened, read, or logged.
    ///
    /// `fileExists(atPath:isDirectory:)` — not the plain overload — because a
    /// directory happening to sit at this path (e.g. an empty
    /// `~/.config/sops/age/keys.txt` someone `mkdir -p`'d by mistake) is not a
    /// key file. The plain overload can't tell the two apart, so it would
    /// produce a false "An age key file sits unencrypted at …" about a path
    /// that holds no file at all. This still costs only a `stat`, so it keeps
    /// the never-opened guarantee the type doc comment promises.
    private var legacyKeyFileFinding: HealthFinding {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: legacyKeyFilePath, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            return HealthFinding(id: "security.legacy-key-file", title: "Plaintext key file",
                                 status: .ok,
                                 detail: "No unprotected age key file was found.")
        }
        return HealthFinding(
            id: "security.legacy-key-file", title: "Plaintext key file", status: .warning,
            detail: "An age key file sits unencrypted at \(legacyKeyFilePath). Anything that can read your home directory — including any process you run — can read that key.",
            remediation: Remediation(
                explanation: "Import it into the Keychain from the Keys section of this app. Once the import is verified, delete the file yourself; this app will not delete it for you."))
    }

    /// The provider states a fact; this decides what it is worth. See
    /// `AppUpdateState` for why the provider cannot pick the status itself.
    private var appUpdateFinding: HealthFinding {
        switch appUpdates.state {
        case .upToDate(let version):
            HealthFinding(id: "security.app-updates", title: "App updates", status: .ok,
                          detail: "This app is version \(version), which is the latest release.")
        case .updateAvailable(let version):
            HealthFinding(id: "security.app-updates", title: "App updates", status: .warning,
                          detail: "Version \(version) has been released and this Mac is not running it yet.",
                          remediation: Remediation(
                              explanation: "Install the update from the About window. Updating the app is also what updates the encryption engine compiled into it."))
        case .couldNotCheck(let reason):
            HealthFinding(id: "security.app-updates", title: "App updates",
                          status: .unknown(reason: reason),
                          detail: "This app tried to find out whether it is current and could not, so it is not telling you either way.")
        case .checksDisabled:
            HealthFinding(id: "security.app-updates", title: "App updates",
                          status: .unknown(reason: "Update checks are turned off, so this app did not look for a newer version of itself."),
                          detail: "Nothing was sent anywhere. This is not a statement about whether an update exists.",
                          remediation: Remediation(
                              explanation: "Turn on \"Check for engine updates\" in Settings › Updates if you want this app to look."))
        case .unavailable(let reason):
            HealthFinding(id: "security.app-updates", title: "App updates",
                          status: .skipped(reason: reason),
                          detail: "Until then, this app does not check whether it is current, and says nothing about whether it is.")
        }
    }
}
