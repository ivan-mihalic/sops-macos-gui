import Foundation
import Testing

/// #27 claim 1: the app's name is spelled six times with no single source —
/// `CFBundleName` ("SOPS GUI", with a space), the XcodeGen project name and
/// its own target key ("SopsGUI"), `release.conf`'s `APP_NAME`, the
/// `bundleIdPrefix`, the window frame-autosave key
/// (`App/SopsGUIApp.swift`'s `configureMainWindow`), and the Sparkle keychain
/// account name.
///
/// The goal stated in the ticket is explicitly **not** to make all six
/// identical — a display name with a space and a target name without one are
/// not the same string by nature, and the keychain account is a stable
/// identifier that must survive a rename of the display name. So this file
/// is two different tests rather than one blanket equality check:
///
/// - `coreIdentifierAgreesEverywhereItMustAgree` reads the identifier that
///   genuinely is duplicated for no reason — the XcodeGen project name, its
///   own target key one line below, `release.conf`'s `APP_NAME`, and the
///   window autosave key built from `bundleIdPrefix` + that same
///   identifier — and requires them to be the same value, read dynamically
///   rather than hardcoded, so a deliberate rename that updates all four
///   still passes and a rename that misses one does not.
/// - `deliberatelyIndependentNamesStayPinned` pins `CFBundleName` and the
///   Sparkle keychain account to their current literal values. Not because
///   they must equal the core identifier — they must not, and the point of
///   pinning them separately is that an editor "fixing" one to match a
///   renamed core identifier (the exact accidental-convergence mistake this
///   ticket's own example warns about for the keychain account) is caught
///   here instead of shipping unnoticed.
@Suite("The app's name is one identifier where it must be, and pinned-independent where it must not")
struct AppIdentityTests {

    /// `Tests/SopsHealthTests/…` → package root → repository root.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SopsHealthTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Packages/SopsGUIKit
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repository root

    private static func read(_ relativePath: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func firstMatch(_ pattern: String, in text: String) throws -> String? {
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }

    @Test("the XcodeGen project name, its target key, release.conf's APP_NAME, and the window autosave key all name the same identifier")
    func coreIdentifierAgreesEverywhereItMustAgree() throws {
        let projectSpec = try Self.read("project.yml")
        let releaseConf = try Self.read("release.conf")
        let appSwift = try Self.read("App/SopsGUIApp.swift")

        let projectName = try #require(
            try Self.firstMatch(#"(?:^|\n)name:\s*(\S+)"#, in: projectSpec),
            "could not find the top-level `name:` in project.yml")
        let targetKey = try #require(
            try Self.firstMatch(#"targets:\s*\n\s*([A-Za-z0-9_]+):"#, in: projectSpec),
            "could not find the targets: key in project.yml")
        let appName = try #require(
            try Self.firstMatch(#"APP_NAME="([^"]+)""#, in: releaseConf),
            "could not find APP_NAME in release.conf")
        let bundleIdPrefix = try #require(
            try Self.firstMatch(#"bundleIdPrefix:\s*(\S+)"#, in: projectSpec),
            "could not find bundleIdPrefix in project.yml")
        let autosaveKey = try #require(
            try Self.firstMatch(#"setFrameAutosaveName\("([^"]+)"\)"#, in: appSwift),
            "could not find setFrameAutosaveName(\"…\") in App/SopsGUIApp.swift")

        #expect(projectName == targetKey,
                "project.yml's project name ('\(projectName)') and its own target key ('\(targetKey)') disagree")
        #expect(projectName == appName,
                "project.yml's project name ('\(projectName)') and release.conf's APP_NAME ('\(appName)') disagree")

        let expectedAutosaveKey = "\(bundleIdPrefix).\(projectName).main"
        let autosaveMessage = "the window autosave key ('\(autosaveKey)') is not bundleIdPrefix + the core "
            + "identifier + \".main\" (expected '\(expectedAutosaveKey)') — a rename of bundleIdPrefix or "
            + "the core identifier that misses App/SopsGUIApp.swift orphans a user's saved window frame, "
            + "the exact bug that key exists to fix (see that function's own doc comment)"
        #expect(autosaveKey == expectedAutosaveKey, "\(autosaveMessage)")
    }

    @Test("CFBundleName and the Sparkle keychain account are pinned, independent identifiers — a change to either is a deliberate decision")
    func deliberatelyIndependentNamesStayPinned() throws {
        let projectSpec = try Self.read("project.yml")
        let releaseConf = try Self.read("release.conf")

        let bundleDisplayName = try #require(
            try Self.firstMatch(#"CFBundleName:\s*([^\n]+)"#, in: projectSpec),
            "could not find CFBundleName in project.yml")
        let keychainAccount = try #require(
            try Self.firstMatch(#"SPARKLE_KEY_ACCOUNT="([^"]+)""#, in: releaseConf),
            "could not find SPARKLE_KEY_ACCOUNT in release.conf")

        // Pinned literals, not derived from the core identifier above — a
        // failure here means one of these two was edited, which this test
        // exists to surface rather than let pass silently. `CFBundleName`
        // (the Dock/Finder display name) is free to change as a deliberate
        // product decision — out of scope per the ticket — but that is a
        // conscious edit to this test, not a side effect of an unrelated
        // rename.
        let displayNameMessage = "CFBundleName changed to '\(bundleDisplayName)' — if this is a deliberate "
            + "display-name change, update this pinned value; if it happened as a side effect of renaming "
            + "the core identifier, that is exactly the accidental coupling this test exists to catch"
        #expect(bundleDisplayName.trimmingCharacters(in: .whitespaces) == "SOPS GUI", "\(displayNameMessage)")

        // The keychain account specifically must NOT track a renamed core
        // identifier — see release.conf's own comment: "Vlastní pár, ne
        // sdílený s ui-testerem" and the ACL note below it. Changing it
        // invalidates the keychain ACL grant this project's release process
        // depends on (ticket #26 item 3) independently of anything else.
        let keychainMessage = "SPARKLE_KEY_ACCOUNT changed to '\(keychainAccount)' — this is a stable "
            + "identifier the release process's keychain ACL grant is bound to; it must not move just "
            + "because the app's display name or XcodeGen project name did"
        #expect(keychainAccount == "sops-macos-gui", "\(keychainMessage)")
    }
}
