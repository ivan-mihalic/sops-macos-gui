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

@Test("the sidebar labels come from the string catalog")
func sidebarLabelsAreLocalized() {
    #expect(LocalizedKey.sidebarProjects.text == "Projects")
    #expect(LocalizedKey.sidebarAbout.text == "About")
    #expect(LocalizedKey.sidebarSettings.text == "Settings")
}
