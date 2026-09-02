import AppKit
import Testing
@testable import SopsUI

/// How the Add Project panel is configured.
///
/// Reported from use: the panel offered no way to make a folder, so adding a
/// project you had not created yet meant leaving the app, making the folder in
/// Finder, and coming back. `NSOpenPanel.canCreateDirectories` defaults to
/// `false` — unlike `NSSavePanel`, where it defaults to `true` — so the New
/// Folder button was missing because nobody turned it on, not because macOS
/// withholds it from open panels.
///
/// Asserted on the configuration rather than through the panel, because
/// `runModal()` blocks on a real window this package cannot open. That is why
/// `ProjectOpenPanel.make()` exists as a separate function: the thing worth
/// checking is what the panel is set to, and a panel built inline inside the
/// method that immediately runs it is unreachable from a test.
@Suite("Add Project open panel")
@MainActor
struct ProjectOpenPanelTests {

    @Test("the panel offers New Folder, so a project can be created while choosing it")
    func offersNewFolder() {
        #expect(ProjectOpenPanel.make().canCreateDirectories)
    }

    /// The rest of the configuration, pinned in the same place — these decide
    /// that the panel picks exactly one directory, and each of them being
    /// wrong is a different, quieter kind of broken than a missing button.
    @Test("it picks exactly one directory, never a file")
    func picksOneDirectory() {
        let panel = ProjectOpenPanel.make()
        #expect(panel.canChooseDirectories)
        #expect(!panel.canChooseFiles)
        #expect(!panel.allowsMultipleSelection)
    }

    /// The button says what it does. Checked because the panel is built in
    /// code rather than a nib, so nothing else would notice it going back to
    /// the system default "Open".
    @Test("the accept button is named for adding a project")
    func promptNamesTheAction() {
        #expect(ProjectOpenPanel.make().prompt == LocalizedKey.actionAddProject.text)
    }
}
