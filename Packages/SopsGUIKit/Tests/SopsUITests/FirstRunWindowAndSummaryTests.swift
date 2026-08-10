import SopsProjects
import SwiftUI
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

@Suite("A sidebar row is clickable across its whole width")
@MainActor
struct SidebarHitAreaTests {

    /// Measured on the running app with `Scripts/ui-probe.swift` before the
    /// fix:
    ///
    ///     AXButton "About"     58x16
    ///     AXButton "Settings"  73x16
    ///     AXRow    "Projects"  220x32
    ///
    /// The two bottom rows were hand-rolled `Button`s in a `safeAreaInset`,
    /// clickable only on the glyph and the word; the row above them, being a
    /// real `List` row, took a click anywhere. After rebuilding the sidebar as
    /// one `List` with two sections, the same probe reads `204x24` for both —
    /// full width, like every other row.
    ///
    /// This asserts the *structure* that guarantees it, because a `List` row's
    /// hit area is SwiftUI's business and testing it would be testing SwiftUI.
    /// What is this app's business is not hand-rolling rows again.
    @Test("the bottom sections are List rows, not hand-rolled buttons")
    func bottomRowsAreListRows() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent("Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift"),
            encoding: .utf8)

        #expect(!source.contains("struct PinnedSidebarRow"),
                Comment(rawValue: "the hand-rolled row is back; its hit area is its text"))
        #expect(!source.contains(".safeAreaInset(edge: .bottom)"),
                Comment(rawValue: """
                    the sidebar pins rows in a bottom inset again — that is what stopped it                     compressing vertically and left the split group 1301 pt tall in a 612 pt window
                    """))
        #expect(source.contains("ForEach(Section.pinnedToBottom"),
                Comment(rawValue: "the About/Settings rows are not in the sidebar list at all"))
    }
}


@Suite("Click targets are the size of the control, not of its glyph")
@MainActor
struct ClickTargetTests {

    /// Measured on the running app with `Scripts/ui-probe.swift`, walking the
    /// project → file list → editor flow with a seeded `ProjectStore`:
    ///
    ///     AXButton "Add Project…"            101x16
    ///     AXButton "Remove the selected key"  37x11
    ///     AXButton "Add a key"                37x20
    ///
    /// All three are `.buttonStyle(.plain)`-style controls whose hit region is
    /// whatever they draw. "Add Project…" was 101 pt of text in a 220 pt
    /// sidebar footer; the minus button was **eleven points tall**, because a
    /// `minus` glyph is a short bar — and its plus neighbour was 20, so the
    /// pair did not even match.
    @Test("the Add Project control fills the sidebar footer")
    func addProjectFillsTheFooter() throws {
        let width: CGFloat = 240
        let nodes = AXProbe.tree(size: CGSize(width: width, height: 400)) {
            ProjectSidebar(model: ProjectSidebarModel(store: ProjectStore(fileURL: Self.throwaway)))
        }
        guard let button = nodes.first(where: {
            $0.label.hasPrefix("Add Project") && $0.role.contains("Button")
        }) else {
            Issue.record("no Add Project button in the rendered tree")
            return
        }
        #expect(button.frame.width > width * 0.7, Comment(rawValue: """
            Add Project… is \(Int(button.frame.width)) pt wide in a \(Int(width)) pt sidebar, \
            so most of the footer row does nothing when clicked
            """))
    }

    /// A store in a throwaway directory — never `ProjectStore.defaultFileURL`,
    /// which is the user's real project list.
    static let throwaway = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("click-target-tests-\(UUID().uuidString)")
        .appendingPathComponent("projects.json")
}

@Suite("Status is never carried by colour alone")
@MainActor
struct ColourIndependenceTests {

    /// Increased Contrast could not be *rendered* — see `Snapshot.swift`: the
    /// high-contrast `NSAppearance` produced a byte-identical PNG, because
    /// SwiftUI takes `\.colorSchemeContrast` from the system setting and this
    /// app draws with SwiftUI colours rather than AppKit chrome.
    ///
    /// This asserts the thing that setting exists to protect instead, and it is
    /// the same requirement Apple's guidance states directly: meaning must not
    /// depend on colour. A user with Increased Contrast on, a colour-vision
    /// deficiency, or a monochrome display has to be able to tell an `.ok`
    /// finding from a `.problem` one.
    ///
    /// Two channels are checked, because either alone can regress: the glyph
    /// and the spoken/label text.
    @Test("every health status has its own glyph and its own words")
    func statusesDifferBeyondColour() {
        let statuses: [HealthStatus] = [
            .ok, .warning, .problem,
            .skipped(reason: "nothing to look at"),
            .unknown(reason: "could not tell"),
        ]

        // Asserted against the mapping, not against the rendered tree. The
        // rendered version of this test was written first and is why this
        // comment exists: SwiftUI does not publish an SF Symbol's name as an
        // accessibility label, so giving `.warning` and `.problem` the same
        // glyph left it green. A test that cannot fail is not a test.
        let glyphs = Set(statuses.map(HealthFindingRow.glyph(for:)))
        #expect(glyphs.count == statuses.count, Comment(rawValue: """
            \(statuses.count) statuses share only \(glyphs.count) glyphs, so at least two are \
            told apart by tint alone: \(glyphs.sorted())
            """))

        let words = Set(statuses.map(HealthFindingRow.statusWords(for:)))
        #expect(words.count == statuses.count, Comment(rawValue: """
            \(statuses.count) statuses share only \(words.count) descriptions
            """))
    }

    /// The other place colour could have been load-bearing: a masked value
    /// versus a revealed one. It is a different *string*, not a different
    /// shade, and the reveal control says which state it is in.
    @Test("a masked value is not merely a differently-coloured one")
    func maskingIsNotAColour() {
        #expect(SecretRowViewLogic.maskedValue(for: "correct-horse-battery")
                != "correct-horse-battery")
        #expect(SecretRowViewLogic.maskedValue(for: "a")
                == SecretRowViewLogic.maskedValue(for: "a-much-longer-secret"),
                "a fixed-width mask, so the glyph count does not leak the length")
    }
}

@Suite("A detail page never pins the window's height")
struct DetailPageHeightTests {

    /// The About row grew the window to 1382 pt and then would not let it
    /// shrink — at any width, gradually or in one jump. Measured on the running
    /// app after 0.1.5 shipped, so this was a live defect, not a regression
    /// from the work that found it.
    ///
    /// Nothing about the view in isolation predicts it: `AboutView`'s own
    /// `fittingSize` is 358 pt. It only appears in the split view's detail
    /// column, and substituting a plain `Text` there let the same window
    /// shrink to 700 immediately — which is how it was pinned down after the
    /// app icon, the frame modifiers and the three-column restructure had each
    /// been ruled out by measurement.
    ///
    /// The fix is that a page which might not fit scrolls. A `ScrollView`
    /// proposes no minimum height, so the window is free; and a user with
    /// larger text or a short window needs it to scroll anyway.
    ///
    /// Asserted on the source because the failure is a *window* property and
    /// this package cannot open one — the live measurement is in
    /// `docs/ui-review-2026-08-10.md`, finding 14.
    @Test("the About page is scrollable, so it cannot set a floor on the window")
    func aboutPageScrolls() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent("Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift"),
            encoding: .utf8)
        #expect(source.contains("ScrollView { AboutView() }"), Comment(rawValue: """
            AboutView sits directly in the detail column again — it pinned the window's \
            minimum height at 1382 pt the last time it did
            """))
    }
}

@Suite("Moving the project list to its own column did not unwire its guard")
struct ThreeColumnGuardWiringTests {

    /// The project list moved out of `ProjectWorkspaceView`'s `HSplitView` and
    /// into the window's `content:` column, to make the app a real
    /// three-column `NavigationSplitView` — measured effect: the minimum window
    /// width fell from 1138 pt to 910 pt, and columns collapse natively.
    ///
    /// The whole reason that move was safe is that it changed *where a view
    /// sits*, not *who asks before discarding a document*. `ProjectSidebar`
    /// writes `projects.selection`; `ProjectWorkspaceView` observes it and
    /// routes through `requestProjectSwitch`. Both halves are asserted here,
    /// because the failure if they ever come apart is silent: a click on
    /// another project would take the open dirty document with it, which is
    /// the defect `WorkspaceSwitchDecision` exists for and which this
    /// milestone has already produced three times by other routes.
    @Test("the project list writes the selection and the workspace still guards it")
    func projectGuardStillWired() throws {
        let source = try String(contentsOf: MainWindowSizeTests.repositoryRoot
            .appendingPathComponent("Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift"),
            encoding: .utf8)

        #expect(source.contains("} content: {"),
                Comment(rawValue: "the app is back to a two-column split view"))
        #expect(source.contains(".onChange(of: projects.selection, initial: true)"),
                Comment(rawValue: """
                    nothing observes the project selection any more — a click on another \
                    project would discard an open dirty document with no prompt
                    """))
        #expect(source.contains("requestProjectSwitch(to: newValue)"),
                Comment(rawValue: "the project selection no longer routes through its guard"))
    }
}
