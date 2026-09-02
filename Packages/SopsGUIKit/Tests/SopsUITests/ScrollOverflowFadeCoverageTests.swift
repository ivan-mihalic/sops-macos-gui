import Foundation
import Testing
@testable import SopsUI

/// Which scrollable lists carry `scrollOverflowFade()`.
///
/// ## Why this reads source text
/// Because nothing else can. The fade is an `overlay` gated on a scroll
/// geometry read: it draws no accessibility element on purpose
/// (`EdgeFade.accessibilityHidden(true)`), so `AccessibilityTreeTests`' probe
/// cannot see it, and a `ViewModifier` applied inside a `body` is not
/// reachable by reflection. The only real verification is looking at the PNG
/// `Scripts/snapshots.sh` renders — which is what was done for this change,
/// with a sidebar that overflows and one that does not.
///
/// A snapshot is a thing a person reads once, though, and Task 9 shipped the
/// fade to four lists and missed the fifth for a whole milestone precisely
/// because nothing failed when it did. This is the cheap guard that turns
/// "somebody has to notice" into "the suite says so": it is a `grep` with a
/// name, and it claims nothing more than that the call is present.
@Suite("scroll overflow fade coverage")
struct ScrollOverflowFadeCoverageTests {

    /// `Tests/SopsUITests/…` → package root → `Sources/SopsUI`. Resolved from
    /// source rather than from a build product, the same way
    /// `LocalizationTests` reaches `Localizable.xcstrings`, so this works
    /// under either build system.
    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/SopsUITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/SopsUI")

    /// Every view whose `List` can be handed more rows than fit it.
    ///
    /// `ProjectSidebar` and `FileListView` were two of these until SOPS-39
    /// task 6 folded both into `Shell/ProjectTreeSidebar.swift` — one list
    /// holding every project *and* every one of their files, so it overflows
    /// sooner than either of the two it replaced, not later.
    static let viewsWithAnOverflowableList = [
        "Shell/ProjectTreeSidebar.swift",
        "Health/HealthPanel.swift",
        "Health/OnboardingWizard.swift",
        "Editor/SecretEditorView.swift",
    ]

    /// Comments stripped first, and this is not hypothetical tidying: the
    /// same attack has now beaten a source-text test in this suite three
    /// separate rounds — check the name, gut the setter; check the setter
    /// text, comment it out with `//`; strip `//`, use `/* */`. Verified here
    /// by mutation: replacing the real call in `HealthPanel.swift` with
    /// `// FIXME: temporarily dropped .scrollOverflowFade() while reworking`
    /// left this test, and all 231 tests in the target, green.
    ///
    /// `OuterSidebarWiringTests.strippingComments` rather than a second copy —
    /// that one already carries the scars and the doc comment explaining them.
    @Test("every list that can overflow signals it",
          arguments: ScrollOverflowFadeCoverageTests.viewsWithAnOverflowableList)
    func listHasTheFade(relativePath: String) throws {
        let url = Self.sourceRoot.appendingPathComponent(relativePath)
        let source = OuterSidebarWiringTests.strippingComments(
            try String(contentsOf: url, encoding: .utf8))

        // Sanity first, so a renamed or moved file fails as a missing list
        // rather than passing as a file with no `List` to fade. Both call
        // shapes count: `List(items) { … }` and `List { … }`.
        #expect(source.contains("List(") || source.contains("List {"),
                "\(relativePath) no longer contains a List")
        #expect(source.contains(".scrollOverflowFade()"),
                "\(relativePath) has a scrollable list with no overflow fade")
    }
}
