import Combine
import Foundation
import Sparkle
import SwiftUI
import SopsHealth
import SopsUI

/// Sparkle, wired so that the health check can report what it actually knows
/// rather than a stub.
///
/// ## Why this lives in the app target and not in `SopsGUIKit`
///
/// `SopsHealth` declares `AppUpdateStatusProviding` and knows nothing about
/// how the answer is obtained — that is the seam this file finally fills, and
/// it is the reason `UnshippedAppUpdates` could be tested from day one. Putting
/// Sparkle behind the seam here keeps the framework dependency out of the
/// package, so `swift test` still builds and runs without fetching Sparkle.
///
/// ## What it is allowed to do on its own: nothing
///
/// `SUEnableAutomaticChecks` is `false` in `Info.plist` and
/// `automaticallyDownloadsUpdates` is forced off below. The appcast is fetched
/// only when either
///
/// - the user has turned on Settings › Updates (`UpdateCheckConsent`, the same
///   flag that gates the engine-freshness lookup — one toggle, both network
///   requests, because two consent flags with one label is how a user ends up
///   surprised), or
/// - the user picks "Check for Updates…" from the app menu, which is consent
///   for that one check and nothing more.
///
/// Nothing is ever installed without the user pressing Install in Sparkle's own
/// dialog. That is not the same claim as "the app never mutates the system"
/// (CLAUDE.md) — replacing its own bundle is exactly what an updater does — but
/// it stays inside the app's own bundle: no installer, no package manager, no
/// `sudo`, no privileged helper.
@MainActor
final class AppUpdater {
    private let controller: SPUStandardUpdaterController
    private let statusBox: AppUpdateStatusBox
    /// Strong, because `SPUStandardUpdaterController` holds its updater
    /// delegate weakly — without this the delegate is deallocated on the way
    /// out of `init` and every callback below is silently never delivered.
    private let delegate: UpdaterDelegate

    /// The provider handed to `HealthReport.standard`. Reads the same box this
    /// updater's delegate writes.
    let statusProvider: any AppUpdateStatusProviding

    var updater: SPUUpdater { controller.updater }

    init(defaults: UserDefaults = .standard) {
        let box = AppUpdateStatusBox()
        statusBox = box
        statusProvider = box
        let delegate = UpdaterDelegate(box: box)
        self.delegate = delegate
        // `startingUpdater: false`, then started explicitly below — the
        // difference matters, because starting the updater is also what
        // schedules the first automatic check, and that must not happen before
        // `automaticallyChecksForUpdates` has been set from the user's consent.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: delegate,
            userDriverDelegate: nil)

        let consented = UpdateCheckConsent.isEnabled(in: defaults)
        controller.updater.automaticallyChecksForUpdates = consented
        // Never. An update this app downloaded on its own, sitting on disk
        // ready to swap itself in, is a decision the user did not make.
        controller.updater.automaticallyDownloadsUpdates = false
        box.setChecksEnabled(consented)
        controller.startUpdater()
    }

    /// Re-reads the consent flag. Called when Settings changes it, so the
    /// toggle takes effect in the session that flipped it rather than after a
    /// relaunch — the same staleness this app already fixed once for the
    /// engine-freshness lookup (`HealthReport.standard`'s closure parameter).
    func refreshConsent(defaults: UserDefaults = .standard) {
        let consented = UpdateCheckConsent.isEnabled(in: defaults)
        updater.automaticallyChecksForUpdates = consented
        statusBox.setChecksEnabled(consented)
    }
}

/// The bridge between Sparkle's delegate callbacks and
/// `AppUpdateStatusProviding`, which is a synchronous `Sendable` getter that
/// the health report may read from any isolation.
///
/// Sparkle calls its delegate on the main actor — `SPUUpdaterDelegate` is
/// main-actor-isolated, and a single class conforming to both protocols does
/// not compile for exactly that reason. So the state lives here, behind a
/// lock, and `UpdaterDelegate` below writes to it: a health run must never
/// have to hop to the main actor to find out that no update check has
/// happened.
///
/// It reports only what a callback actually told it. There is deliberately no
/// "probably fine" default — see `AppUpdateState`'s own comment on why the
/// provider cannot fabricate an all-clear.
private final class AppUpdateStatusBox: AppUpdateStatusProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var checksEnabled = false
    /// `nil` until a check reaches a verdict. Not an implied `.upToDate`.
    private var lastVerdict: AppUpdateState?

    var state: AppUpdateState {
        lock.lock()
        defer { lock.unlock() }
        if let lastVerdict { return lastVerdict }
        if !checksEnabled {
            return .checksDisabled
        }
        return .couldNotCheck(
            reason: "Update checks are on, but this app has not completed one yet in this session.")
    }

    func setChecksEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        checksEnabled = enabled
        // Turning checks off does not un-know a verdict already reached, but
        // it does make an old one stale, and a stale "you are up to date" is
        // the one sentence this finding must never show. Dropping it puts the
        // finding back to `.checksDisabled`, which is true.
        if !enabled { lastVerdict = nil }
    }

    func record(_ verdict: AppUpdateState) {
        lock.lock()
        defer { lock.unlock() }
        lastVerdict = verdict
    }
}

/// Turns Sparkle's callbacks into `AppUpdateState`. Nothing else — the
/// decision about what each state is *worth* belongs to
/// `SecurityPostureCheck`, which is where it can be tested.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    private let box: AppUpdateStatusBox

    init(box: AppUpdateStatusBox) {
        self.box = box
    }

    private var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "an unknown version"
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        box.record(.updateAvailable(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        // Sparkle reports "no update" as an error object, and the distinctions
        // it carries are the whole point. Only one of them means what a user
        // reads "up to date" as meaning.
        let nsError = error as NSError
        guard nsError.code == Int(SUError.noUpdateError.rawValue) else {
            // The check itself did not get that far. Saying "up to date" over
            // it would be a claim about a feed nobody read.
            box.record(.couldNotCheck(reason: nsError.localizedDescription))
            return
        }
        let reason = (nsError.userInfo[SPUNoUpdateFoundReasonKey] as? NSNumber)
            .map { SPUNoUpdateFoundReason(rawValue: OSStatus($0.intValue)) }
        switch reason {
        case .onLatestVersion, .onNewerThanLatestVersion:
            box.record(.upToDate(version: runningVersion))
        case .systemIsTooOld:
            // A newer release exists; this Mac's macOS cannot run it. Reporting
            // "up to date" here tells a user on an unsupported OS that they are
            // current when they are stranded.
            box.record(.couldNotCheck(
                reason: "A newer version of this app exists, but it needs a newer macOS than this Mac is running."))
        case .systemIsTooNew:
            box.record(.couldNotCheck(
                reason: "The update feed offers nothing for a macOS this new."))
        case .hardwareDoesNotSupportARM64:
            // Should be unreachable: this app is arm64-only and cannot have
            // launched on hardware that isn't. Stated rather than folded into
            // the up-to-date branch, so it cannot become a false all-clear if
            // that ever stops being true.
            box.record(.couldNotCheck(
                reason: "The update feed offers nothing this Mac's processor can run."))
        default:
            box.record(.couldNotCheck(reason: nsError.localizedDescription))
        }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        // A user who closes the update window has not caused a failure, and
        // reporting one would turn "not now" into a finding.
        guard nsError.code != Int(SUError.installationCanceledError.rawValue) else { return }
        box.record(.couldNotCheck(reason: nsError.localizedDescription))
    }
}

/// The "Check for Updates…" menu item.
///
/// Disabled while a check is already in flight — Sparkle would ignore the
/// second press, and a menu item that visibly does nothing reads as a broken
/// updater.
struct CheckForUpdatesMenuItem: View {
    @StateObject private var model: CanCheckForUpdates
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _model = StateObject(wrappedValue: CanCheckForUpdates(updater: updater))
    }

    var body: some View {
        Button(LocalizedKey.actionCheckForUpdates.text) {
            updater.checkForUpdates()
        }
        .disabled(!model.canCheck)
    }
}

/// Sparkle's documented SwiftUI recipe observes `canCheckForUpdates` through
/// its Combine key-path publisher. That does not compile here: Sparkle 2.8
/// annotates the property `@MainActor`, and Swift 6 refuses to form a key path
/// to a main-actor-isolated property at all. String-keyed KVO is the remaining
/// way to observe it, so it is what this uses — the string is checked against
/// the real property once, in `init`, rather than trusted.
@MainActor
private final class CanCheckForUpdates: NSObject, ObservableObject {
    @Published var canCheck = false

    private nonisolated static let keyPath = "canCheckForUpdates"
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        super.init()
        // A renamed or misspelled key path makes `observeValue` silently never
        // fire, which leaves the menu item permanently greyed out — a failure
        // that looks like "updates are unavailable" rather than like a bug.
        // `value(forKey:)` raises for an unknown key, so this trips at the
        // first launch — `precondition`, not `assert`: Swift strips an
        // `assert`'s condition entirely in a `-O` release build (ticket #26
        // item 2), which is exactly the build a signed, notarized release
        // ships, so the renamed-property case this line exists to catch was
        // unchecked precisely where it matters. `precondition` still traps in
        // `-O`; only `-Ounchecked` — which this project's build settings
        // never enable — would silence it too.
        precondition(
            updater.value(forKey: Self.keyPath) != nil,
            "Sparkle's \"\(Self.keyPath)\" key path is missing or was renamed — "
                + "\"Check for Updates…\" would silently stop enabling and disabling correctly")
        canCheck = updater.canCheckForUpdates
        updater.addObserver(self, forKeyPath: Self.keyPath, options: [.new], context: nil)
    }

    deinit {
        updater.removeObserver(self, forKeyPath: Self.keyPath)
    }

    override nonisolated func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                           change: [NSKeyValueChangeKey: Any]?,
                                           context: UnsafeMutableRawPointer?) {
        guard keyPath == Self.keyPath,
              let value = change?[.newKey] as? Bool else { return }
        MainActor.assumeIsolated { canCheck = value }
    }
}
