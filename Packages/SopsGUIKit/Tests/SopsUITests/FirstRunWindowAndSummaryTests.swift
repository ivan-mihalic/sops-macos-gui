import Foundation
import SopsHealth
import Testing

@testable import SopsUI

/// Three defects a user hit within a minute of launching the first signed
/// build. All three are about the app stating or presenting something without
/// the user being able to act on it.
///
/// Written before any of them was touched, and each one was watched failing
/// first.

@Suite("The main window opens at a size a person chose")
struct MainWindowSizeTests {

    /// The bug as reported: on a large display the window opened
    /// "strašně moc široké". Nothing in the app asked for a size, so SwiftUI
    /// sized the window from the content's ideal widths — which, for a
    /// `NavigationSplitView` with a sidebar, an inspector and a detail pane
    /// that all say `maxWidth: .infinity`, is as much as the screen allows.
    ///
    /// A window's default size is a design decision, so it must not scale with
    /// whatever monitor happens to be attached. It is the same 1180 pt on a
    /// laptop and on a 5K display.
    @Test("a huge display does not produce a huge window")
    func hugeDisplayDoesNotProduceHugeWindow() {
        let onStudioDisplay = MainWindowMetrics.defaultSize(
            forVisibleFrame: CGSize(width: 5120, height: 2880))
        #expect(onStudioDisplay == MainWindowMetrics.idealSize)
        #expect(onStudioDisplay.width < 1400,
                "the window scaled with the display instead of using a chosen size")
    }

    /// The other direction, which the fix must not break: on a display the
    /// ideal size does not fit on, the window has to come down to fit. A
    /// window opening larger than the screen puts its own controls off-screen.
    @Test("a small display gets a window that fits on it", arguments: [
        CGSize(width: 1280, height: 700),
        CGSize(width: 1024, height: 640),
        CGSize(width: 800, height: 500),
    ])
    func smallDisplayGetsAWindowThatFits(visible: CGSize) {
        let size = MainWindowMetrics.defaultSize(forVisibleFrame: visible)
        #expect(size.width <= visible.width)
        #expect(size.height <= visible.height)
    }

    /// A laptop is the common case and must not be squeezed to the minimum.
    @Test("a 13-inch laptop still gets the full ideal size")
    func laptopGetsIdealSize() {
        let size = MainWindowMetrics.defaultSize(
            forVisibleFrame: CGSize(width: 1440, height: 847))
        #expect(size == MainWindowMetrics.idealSize)
    }

    /// The second half of the report: "nejde to vůbec resizovat".
    ///
    /// `WindowGroup`'s default resizability is `.automatic`, which for a plain
    /// content view means the window is bounded by the content's own ideal
    /// size. The window therefore has to be told it may be resized freely
    /// above a minimum, and the content has to be allowed to grow into it.
    /// Neither is expressible as a value a test can call, so this reads the
    /// scene's source — the same technique `OuterSidebarSwitchTests` uses, and
    /// with the same limitation: it proves the modifier is written, not that
    /// AppKit honoured it.
    @Test("the window scene asks to be resizable and picks its own default size")
    func sceneIsResizable() throws {
        let source = try String(contentsOf: Self.repositoryRoot
            .appendingPathComponent("App/SopsGUIApp.swift"), encoding: .utf8)

        #expect(source.contains(".windowResizability(.contentMinSize)"),
                Comment(rawValue: "the window is not resizable above its content's ideal size"))
        #expect(source.contains(".defaultSize("),
                Comment(rawValue: "nothing asks for a default size, so SwiftUI invents one"))
        #expect(source.contains("MainWindowMetrics"),
                Comment(rawValue: "the size is hardcoded at the scene instead of being the tested one"))
    }

    /// `Tests/SopsUITests/<this file>` → four levels up is the repository root.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SopsUITests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // SopsGUIKit
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // repository root
}

@Suite("The wizard's verdict comes with the findings behind it")
struct OnboardingSummaryEvidenceTests {

    private func finding(_ id: String, _ status: HealthStatus) -> HealthFinding {
        HealthFinding(id: id, title: id, status: status, detail: "detail for \(id)")
    }

    /// The bug as reported: the last step of the wizard said something was
    /// wrong and the user could not tell what.
    ///
    /// "Some things need fixing." is the whole summary today. The findings
    /// that produced it live on the four steps behind, so the user has to walk
    /// back through all of them and compare. A verdict with no evidence in
    /// sight is exactly what this app's own rule against unsupported claims is
    /// about — it just happens to be an unsupported *bad* claim rather than an
    /// unsupported all-clear.
    @Test("a problem verdict names the finding that caused it")
    func problemVerdictNamesItsCause() {
        let findings = [
            finding("tool.sops", .ok),
            finding("security.keystore", .problem),
            finding("engine.freshness", .warning),
        ]

        let evidence = OnboardingSummaryState.evidence(in: findings)

        #expect(evidence.map(\.id) == ["security.keystore", "engine.freshness"],
                "worst first, and nothing that is already fine")
    }

    /// `.skipped` and `.unknown` are not problems — see `OnboardingWizard`'s
    /// own reasoning for why they get a neutral glyph. Listing them here would
    /// put "nothing to look at" under a heading that says something needs
    /// attention.
    @Test("a clean run lists nothing")
    func cleanRunListsNothing() {
        let findings = [
            finding("tool.sops", .ok),
            finding("project.none", .skipped(reason: "no projects added")),
            finding("security.app-updates", .unknown(reason: "checks are off")),
        ]
        #expect(OnboardingSummaryState.evidence(in: findings).isEmpty)
    }

    /// A finding whose id matches no category prefix appears on none of the
    /// four category steps, so the summary is the *only* place it can be
    /// seen — and it still drives the verdict. `OnboardingWizard` already has
    /// an "Other" section for that reason; the evidence list must not
    /// reintroduce the hole by filtering on category.
    @Test("an uncategorized problem is still listed")
    func uncategorizedProblemIsListed() {
        let evidence = OnboardingSummaryState.evidence(in: [finding("mystery.check", .problem)])
        #expect(evidence.map(\.id) == ["mystery.check"])
    }
}

@Suite("The wizard can re-run the checks without being restarted")
struct OnboardingRecheckTests {

    /// The request: having installed the command-line tools by hand while the
    /// wizard was open, there was no way to make it look again. The findings
    /// were from a scan that ran before the install, and the only way to a
    /// fresh one was to close the wizard and re-open it from the menu.
    ///
    /// A source assertion, for the same reason as the window one: the button
    /// is a view, and this project cannot drive a real one. It checks the
    /// three things that make the button do its job — that it exists, that it
    /// re-runs the scan, and that it sits to the left of Continue where the
    /// report asked for it.
    @Test("a re-check button sits left of Continue and re-runs the scan")
    func recheckButtonExists() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent(
                "Packages/SopsGUIKit/Sources/SopsUI/Health/OnboardingWizard.swift"),
            encoding: .utf8)

        let recheck = try #require(source.range(of: "actionCheckAgain"),
                                   "the wizard has no re-check button")
        let continueButton = try #require(source.range(of: "actionContinue"))
        #expect(recheck.lowerBound < continueButton.lowerBound,
                "the re-check button is not to the left of Continue")
        #expect(source.contains("await health.refresh()"),
                Comment(rawValue: "the button does not actually re-run the checks"))
    }
}

@Suite("About and Settings are not dead rows")
struct AboutAndSettingsTests {

    /// Reported from the first signed build: clicking About or Settings in the
    /// sidebar showed nothing. Both were selectable rows whose detail pane
    /// rendered the same "nothing selected" placeholder the app shows when
    /// literally nothing is selected — so the two rows PROPOSAL §4 pins to the
    /// bottom of the sidebar were, in the shipped app, decoration.
    @Test("About reports what it can read and never invents a version")
    func aboutFactsAreHonest() {
        let empty = Bundle(for: EmptyBundleMarker.self)
        let facts = AboutFacts.read(from: empty, sops: "3.13.0", age: "1.2.1")

        // A test bundle has no CFBundleShortVersionString of the app's, so
        // this is the missing-key path. It must say so rather than print an
        // empty string or a plausible-looking default like "1.0" — the whole
        // point of the pane is telling a user which build they are running
        // when they file a report.
        #expect(facts.version == AboutFacts.unknownValue)
        #expect(facts.build == AboutFacts.unknownValue)
        #expect(facts.commit == nil)
        #expect(facts.sops == "3.13.0")
        #expect(facts.age == "1.2.1")
    }

    @Test("About reads the real keys when the bundle has them")
    func aboutReadsRealKeys() {
        let facts = AboutFacts(version: "0.1.0", build: "123", commit: "d85cae8",
                               sops: "3.13.0", age: "1.2.1")
        #expect(facts.versionLine == "0.1.0 (123) · d85cae8")
    }

    /// The build number alone is not a version anyone quotes, and a missing
    /// commit must not leave a dangling separator.
    @Test("a missing commit does not leave a dangling separator")
    func missingCommitReadsCleanly() {
        let facts = AboutFacts(version: "0.1.0", build: "123", commit: nil,
                               sops: "3.13.0", age: "1.2.1")
        #expect(facts.versionLine == "0.1.0 (123)")
    }

    @Test("the About row shows the About pane")
    func aboutRowShowsThePane() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent("Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift"),
            encoding: .utf8)
        #expect(source.contains("AboutView()"),
                Comment(rawValue: "About still renders the no-selection placeholder"))
    }
}

/// Only here so `Bundle(for:)` can name a bundle that has none of the app's
/// Info.plist keys.
private final class EmptyBundleMarker {}

@Suite("A restored window frame that makes no sense is corrected")
struct RestoredWindowFrameTests {

    /// The frame actually found in `cz.mihalic.SopsGUI` after the user's first
    /// two launches:
    ///
    ///     NSWindow Frame …AppShell, SheetPresentationModifier…,
    ///       ConfirmationDialogModifier…, AlertModifier…-1-AppWindow-1
    ///       = "1950 774 2177 450 0 0 3360 1859"
    ///
    /// 2177 pt wide and 450 pt tall. That is where "obrovské okno" came from,
    /// and it is why `.defaultSize` did nothing: SwiftUI derives the frame
    /// autosave *name* from the content view's type, modifiers included. Adding
    /// `.confirmationDialog` and `.alert` to the root renamed the key, the
    /// user's size was forgotten, and SwiftUI invented that one — and
    /// `.defaultSize` is only consulted when there is no saved frame at all.
    ///
    /// So the fix cannot live in the scene. It is AppKit: a stable autosave
    /// name so the key stops moving, and this function to reject a frame that
    /// was never a size anyone chose.
    @Test("the frame the user actually got is rejected")
    func theObservedBadFrameIsRejected() {
        let corrected = MainWindowMetrics.correctedSize(
            for: CGSize(width: 2177, height: 450),
            visibleFrame: CGSize(width: 3360, height: 1859))
        #expect(corrected == MainWindowMetrics.idealSize)
    }

    /// The whole point of restoring a frame is honouring what the user chose.
    /// A wide window is a legitimate choice on a wide display and must survive.
    @Test("a large but sane frame the user chose is left alone")
    func aSaneFrameSurvives() {
        #expect(MainWindowMetrics.correctedSize(
            for: CGSize(width: 2177, height: 1400),
            visibleFrame: CGSize(width: 3360, height: 1859)) == nil)
        #expect(MainWindowMetrics.correctedSize(
            for: MainWindowMetrics.idealSize,
            visibleFrame: CGSize(width: 3360, height: 1859)) == nil)
    }

    /// Unplugging the external display leaves a saved frame larger than the
    /// laptop screen. The window has to come back down or its title bar is off
    /// the top of the display and cannot be grabbed.
    @Test("a frame from a bigger display is brought back on screen")
    func frameFromABiggerDisplayIsClamped() {
        let corrected = try? #require(MainWindowMetrics.correctedSize(
            for: CGSize(width: 2600, height: 1500),
            visibleFrame: CGSize(width: 1440, height: 847)))
        #expect(corrected?.width ?? .infinity <= 1440)
        #expect(corrected?.height ?? .infinity <= 847)
    }

    /// Too small is as unusable as too large — below the minimum the three
    /// panes overlap into nothing.
    @Test("a frame below the usable minimum is grown")
    func tooSmallIsGrown() {
        #expect(MainWindowMetrics.correctedSize(
            for: CGSize(width: 300, height: 300),
            visibleFrame: CGSize(width: 1440, height: 847)) == MainWindowMetrics.idealSize)
    }

    /// The two AppKit facts SwiftUI would not guarantee. Read from source for
    /// the same reason as the other scene assertions — and specifically
    /// because the last attempt at this bug *was* a SwiftUI modifier, it
    /// passed its own test, and the window stayed 2177 pt wide.
    @Test("the window gets a stable autosave name and is forced resizable")
    func windowIsConfiguredInAppKit() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent("App/SopsGUIApp.swift"), encoding: .utf8)

        #expect(source.contains("setFrameAutosaveName"),
                Comment(rawValue: "the autosave key is still derived from the view type, so it moves on every release"))
        #expect(source.contains("styleMask.insert(.resizable)"),
                Comment(rawValue: "nothing guarantees the window can be resized"))
        #expect(source.contains("MainWindowMetrics.correctedSize"),
                Comment(rawValue: "a restored nonsense frame is never corrected"))
    }
}

@Suite("Settings and About are panes in the main window")
struct InlineSettingsTests {

    /// Reported after 0.1.1: clicking Settings opened a separate window.
    /// `SettingsLink` was the fix for "the row does nothing", but the row
    /// should show the panes in the detail column like About does, not send
    /// the user to another window.
    @Test("the Settings row fills the detail column instead of opening a window")
    func settingsRendersInline() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent("Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift"),
            encoding: .utf8)
        // `SettingsLink {` — the call, not the word. Both this file and
        // AppShell's own comment explain why the link was removed, so a bare
        // substring match reads its own explanation and fails. Exactly the
        // trap `OuterSidebarSwitchTests` records for `#filePath` assertions.
        #expect(!source.contains("SettingsLink {"),
                Comment(rawValue: "the Settings row still opens a separate window"))
        #expect(source.contains("SettingsPaneView("),
                Comment(rawValue: "the detail column has no settings pane"))
        #expect(source.contains("AboutView()"))
    }
}
