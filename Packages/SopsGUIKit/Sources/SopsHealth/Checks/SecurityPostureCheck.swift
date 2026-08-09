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
/// file left behind by `age-keygen`/`sops` conventions — the app's whole
/// security model is that the key lives in the Keychain behind Touch ID
/// instead. *Which* paths those are is `AgeKeyFileLocations`' job, and it is
/// not the single `~/.config/sops/age/keys.txt` this check used to stat: on
/// macOS the embedded sops reads `SOPS_AGE_KEY_FILE`, then
/// `$HOME/Library/Application Support/sops/age/keys.txt`. That finding reports
/// only each file's *existence* (via `FileManager.fileExists`, a `stat`, not a
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
    private let legacyKeyFilePaths: [String]
    /// The login shell could not be asked where else sops would look, so the
    /// path list below is short by an unknown amount.
    private let legacyKeyFileProbeFailed: Bool

    public init(osVersion: SemanticVersion,
                minimumOSVersion: SemanticVersion,
                keyStore: any KeyStoreStatusProviding,
                biometry: any BiometryStatusProviding,
                appUpdates: any AppUpdateStatusProviding,
                legacyKeyFilePaths: [String],
                legacyKeyFileProbeFailed: Bool = false) {
        self.osVersion = osVersion
        self.minimumOSVersion = minimumOSVersion
        self.keyStore = keyStore
        self.biometry = biometry
        self.appUpdates = appUpdates
        self.legacyKeyFilePaths = legacyKeyFilePaths
        self.legacyKeyFileProbeFailed = legacyKeyFileProbeFailed
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
            // "Stored in your Keychain" would overclaim: M2's key lives in
            // memory for the running session only (`SessionKeyStore`), not
            // in the Keychain — that's M3. Say what is actually true now.
            HealthFinding(id: "security.keystore", title: "Your age key", status: .ok,
                          detail: "An age key is imported for this session.")
        case .empty:
            // Scoped to this app, deliberately. "nothing can be decrypted" is
            // a claim about the whole machine, and the app has no basis for
            // it: the user may well hold keys in a `keys.txt`, in a password
            // manager, on a YubiKey, or on another machine entirely, and
            // decrypt with the sops CLI perfectly happily. The only fact here
            // is about this app's own key store.
            HealthFinding(id: "security.keystore", title: "Your age key", status: .problem,
                          detail: "No age key is configured in this app, so this app cannot decrypt anything. Keys you hold elsewhere are unaffected — this says nothing about them.",
                          // Was "Generate a new key, or import an existing
                          // one, from the Keys section of this app." — wrong
                          // on both counts: this app cannot generate a key
                          // yet, and there was no "Keys section" for it to
                          // point at (the sibling finding below had the same
                          // defect before it was fixed). Settings › Key is
                          // real as of this task, and only import exists.
                          //
                          // This sentence used to end "…or import it from
                          // ~/.config/sops/age/keys.txt." — the third copy of
                          // the wrong path, in the one place a user reading a
                          // health report would take as authoritative. It
                          // names no path now, for the reason
                          // `LegacyKeyFileImportOptions` states at length:
                          // this check cannot know which file, if any, that
                          // button will offer, and naming one it might not
                          // use is how the app told the user to look
                          // somewhere it was not looking.
                          remediation: Remediation(
                              explanation: "Import an existing age key in Settings › Key — paste it directly, or import it from a key file this app finds on disk."))
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
    /// directory happening to sit at one of these paths (e.g. an empty
    /// `keys.txt` someone `mkdir -p`'d by mistake) is not a key file. The plain
    /// overload can't tell the two apart, so it would produce a false "An age
    /// key file sits unencrypted at …" about a path that holds no file at all.
    /// This still costs only a `stat`, so it keeps the never-opened guarantee
    /// the type doc comment promises.
    ///
    /// **Plural, and the `.ok` branch names what it checked.** This used to
    /// stat exactly one path — `~/.config/sops/age/keys.txt` — and then say
    /// "No unprotected age key file was found", full stop, naming nothing. On
    /// macOS that is the wrong path: the sops build compiled into this app
    /// reads `$HOME/Library/Application Support/sops/age/keys.txt`, and
    /// `SOPS_AGE_KEY_FILE` before either. See `AgeKeyFileLocations` for the
    /// source citation. An all-clear that does not say what it looked at is
    /// the same failure class as the project check's "found none" over a tree
    /// it had not walked: the user cannot tell a real all-clear from a check
    /// that was pointed somewhere else.
    private var legacyKeyFileFinding: HealthFinding {
        guard !legacyKeyFilePaths.isEmpty else {
            // Nothing to stat means nothing was established. This is not
            // reachable through `HealthReport.standard`, which always supplies
            // `AgeKeyFileLocations.candidates()`, but "no paths" must never
            // read as "no key file".
            return HealthFinding(id: "security.legacy-key-file", title: "Plaintext key file",
                                 status: .unknown(reason: "This app was not told where to look for a plaintext age key file, so it did not look."),
                                 detail: "Nothing here is a statement about whether one exists.")
        }

        // `AgeKeyFileLocations.existingFiles`, not an inline filter: this is
        // the same "does a regular file sit here?" question `KeyImportView`'s
        // import control asks, and answering it twice is how the path list
        // itself came to have two copies.
        let found = AgeKeyFileLocations.existingFiles(among: legacyKeyFilePaths)

        guard !found.isEmpty else {
            // An all-clear is a claim about *every* place sops reads a key
            // from, and `SOPS_AGE_KEY_FILE` moves that set. When the login
            // shell could not be asked, the paths below are the ones this app
            // can name unaided, and they may not be the ones sops would use.
            //
            // Saying `.ok` here is the defect two rounds running: the probe was
            // made to distinguish failure from silence, and then the failure
            // was flattened back to "no variables set" before it reached this
            // sentence. Same machine, same plaintext key file on disk, opposite
            // verdict depending on whether a shell spawn happened to time out.
            guard !legacyKeyFileProbeFailed else {
                return HealthFinding(
                    id: "security.legacy-key-file", title: "Plaintext key file",
                    status: .unknown(reason: "This app could not ask your login shell whether "
                        + "SOPS_AGE_KEY_FILE points somewhere else, so it does not know every place "
                        + "sops would look."),
                    detail: "Nothing was found at " + Self.pathList(legacyKeyFilePaths)
                        + ", which is not the same as there being nothing.")
            }
            return HealthFinding(
                id: "security.legacy-key-file", title: "Plaintext key file", status: .ok,
                detail: "No unprotected age key file was found at any of the places sops reads one from: "
                    + Self.pathList(legacyKeyFilePaths) + ".")
        }

        let command = AgeKeyFileLocations.protectCommand(for: found)
        return HealthFinding(
            id: "security.legacy-key-file", title: "Plaintext key file", status: .warning,
            detail: (found.count == 1
                ? "An age key file sits unencrypted at \(found[0])."
                : "Age key files sit unencrypted at \(Self.pathList(found)).")
                + " Anything that can read your home directory — including any process you run — can read "
                + (found.count == 1 ? "that key." : "those keys."),
            // Was "Import it into the Keychain from the Keys section of this
            // app." — a sibling of the .sops.yaml wizard defect found
            // elsewhere in this task, and the more serious of the two: that
            // one only fires on a project with no .sops.yaml, this one fires
            // on any machine that actually has a legacy key file, which is
            // true of the machine this was found on. There is no Keys
            // section — Keychain key storage is `UnshippedKeyStore` until
            // M3 (see HealthReport+Standard.swift). Say what's actually
            // true today: this app cannot import it yet, and the one thing
            // the user can do without this app's help is narrow who can
            // read the file in the meantime.
            remediation: Remediation(
                explanation: "This app can't import it into the Keychain yet — key management arrives in a later update. Until then, make sure only you can read the file.",
                command: command))
    }

    /// Paths as a sentence fragment. Plain and comma-separated: a path is
    /// already long enough that "and" between the last two buys nothing.
    private static func pathList(_ paths: [String]) -> String {
        paths.joined(separator: ", ")
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
