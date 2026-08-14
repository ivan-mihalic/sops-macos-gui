import Foundation
import Testing

/// #26 item 2: `CanCheckForUpdates.init` probes Sparkle's string-keyed KVO
/// path (`"canCheckForUpdates"`) once, so a future Sparkle version that
/// renames or removes that property is caught rather than leaving "Check for
/// Updates…" permanently, silently disabled. The probe used to be wrapped in
/// `assert(…)` — and Swift strips an `assert`'s condition entirely in a `-O`
/// release build, which is exactly the configuration a signed, notarized
/// release ships (`xcodebuild … -configuration Release`, `drivers/
/// swift-xcodegen.sh` in `mac-release`). So the one build that actually goes
/// out the door never ran the check the comment above it describes.
///
/// `App/` is an Xcode application target, not a SwiftPM library — nothing in
/// `Packages/SopsGUIKit` links it, and no `.xctest` bundle can construct a
/// real `SPUUpdater` to drive `CanCheckForUpdates.init` at runtime from here.
/// This is therefore a source-text guard, the same shape `DeploymentTargetTests`
/// and `ProcessSpawningChokepointTests` already use for the identical kind of
/// problem: a property this repository cannot exercise through a normal
/// black-box test, where what actually matters is which Swift standard
/// library entry point the source calls.
@Suite("Updater.swift's KVO key-path probe survives a release build")
struct AppUpdaterReleaseGuardTests {

    /// `Tests/SopsHealthTests/…` → package root → repository root → `App/`.
    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SopsHealthTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Packages/SopsGUIKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("App/Updater.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @Test("the key-path probe uses precondition, which still traps in -O, not assert, which does not")
    func probeUsesPrecondition() throws {
        let stripped = GitIgnoreOracleSafetyTests.strippingComments(Self.source)
        try #require(!stripped.isEmpty, "could not read App/Updater.swift — is the repository layout as expected?")

        let missingPreconditionMessage = "expected `precondition(updater.value(forKey: Self.keyPath) …)` in "
            + "App/Updater.swift — the probe that catches a renamed Sparkle KVO property must use a "
            + "check the optimizer does not strip in a release build"
        #expect(
            stripped.contains("precondition(") && stripped.contains("updater.value(forKey: Self.keyPath)"),
            "\(missingPreconditionMessage)")

        // The specific failure mode this test exists to close: `assert(…)`
        // wrapping the exact same call. A stray unrelated `assert(` elsewhere
        // in the file would not trip this — the check is scoped to the one
        // call site that matters.
        let strippedAssertMessage = "App/Updater.swift still wraps the KVO key-path probe in `assert(…)`, "
            + "whose condition Swift never evaluates in a -O release build — a renamed Sparkle property "
            + "would ship silently unchecked in exactly the build users receive"
        #expect(
            !stripped.contains("assert(updater.value(forKey: Self.keyPath)"),
            "\(strippedAssertMessage)")
    }
}
