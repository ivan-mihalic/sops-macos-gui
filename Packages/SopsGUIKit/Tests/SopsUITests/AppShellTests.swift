import Testing
@testable import SopsUI

@Test("the shell exposes the navigation sections the sidebar renders")
func shellSections() {
    #expect(AppShell.Section.allCases.map(\.rawValue) == ["projects", "about", "settings"])
}

@Test("about and settings are pinned to the bottom of the sidebar")
func pinnedSections() {
    #expect(AppShell.Section.pinnedToBottom == [.about, .settings])
}

// Bundle-based, like `LocalizationTests.everyKeyResolves`: `.text` only resolves
// real English under a build system that compiles Localizable.xcstrings (xcodebuild,
// or `swift test --build-system swiftbuild`), not plain `swift test`'s native build
// system. See LocalizationTests.swift for the full explanation and the fast-loop
// guard (`everyKeyHasCatalogEntry`) that covers these same keys independent of the
// bundle.
@Test("the sidebar labels come from the string catalog",
      .enabled(if: LocalizationTests.bundleHasMacOSLayout,
               "swift test's native build system never compiles .xcstrings; run under xcodebuild or swift test --build-system swiftbuild to exercise this"))
func sidebarLabelsAreLocalized() {
    #expect(LocalizedKey.sidebarProjects.text == "Projects")
    #expect(LocalizedKey.sidebarAbout.text == "About")
    #expect(LocalizedKey.sidebarSettings.text == "Settings")
}
