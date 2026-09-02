import Foundation
import SopsProjects
import Testing
@testable import SopsUI

/// The destinations the sidebar can select.
///
/// `AppShell.Section` (projects/about/settings) is gone with the four-column
/// window — `WorkspaceSelection` replaced it, and About/Settings being
/// *rows of the one sidebar list* is asserted where it now lives,
/// `OuterSidebarWiringTests.aboutAndSettingsAreRows` (which also pins them
/// below the projects, PROPOSAL §4). What is left to say here is that the
/// two screens are reachable as selections at all.
@Test("About and Settings are selections, not separate windows")
func aboutAndSettingsAreSelections() {
    #expect(WorkspaceSelection.about.projectID == nil)
    #expect(WorkspaceSelection.settings.projectID == nil)
    #expect(!WorkspaceSelection.about.isDocument)
    #expect(!WorkspaceSelection.settings.isDocument)
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
    #expect(LocalizedKey.sidebarAbout.text == "About")
    #expect(LocalizedKey.sidebarSettings.text == "Settings")
    #expect(LocalizedKey.sidebarAccess.text == "Access")
}

// MARK: - M5: one project root, not two

/// The defect: the per-file Access panel took its registry root from an ID
/// lookup in `projects.groups`, while the project-wide panel took
/// `fileListModel.projectRoot`. Those disagree whenever the lookup comes back
/// empty — the project dropped out of the sidebar, or the store has not
/// settled — and the visible result was the same project showing recipients
/// *with* labels in one panel and *without* them in the other, at the same
/// moment.
///
/// Since SOPS-39 task 6 both panels start from the same place: the selection
/// carries a `StoredProject.ID`, `AppShell.project(for:)` resolves it once,
/// and the per-file panel is handed `FileListModel.projectRoot` built from
/// that same project. This pins that there is still exactly one derivation,
/// because a second one reappearing is the whole defect whatever it gets
/// named next time.
@Suite("AppShell — both Access panels read one project root")
struct AppShellProjectRootSourceTests {

    private static let source: String = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/SopsUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/SopsUI/AppShell.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    @Test("every project root in the shell is resolved through the one project lookup")
    func oneProjectLookup() throws {
        try #require(!Self.source.isEmpty, "could not read AppShell.swift")

        let marker = "URL(fileURLWithPath: project.rootPath)"
        let derivations = Self.source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(marker) }

        // Two, and both from a `project` this shell resolved by ID: the
        // Access panel's model, and the new-file wizard's. Every other
        // consumer — the editor, the project home pane — reads
        // `FileListModel.projectRoot`, which `ProjectTreeStore` built from
        // the same lookup.
        #expect(derivations.count == 2, Comment(rawValue: """
            AppShell builds a project root URL \(derivations.count) times; there are two \
            legitimate derivations (the Access model and the new-file model) and every other \
            reader goes through ProjectTreeStore's FileListModel
            """))

        let lookups = Self.source.components(separatedBy: "private func project(for id: StoredProject.ID)").count - 1
        #expect(lookups == 1,
                "there is more than one way to turn a project id into a project — that is how the two panels came to disagree")
    }

    @Test("the per-file panel's registry root comes from the file list model, not a second lookup")
    func perFileRootComesFromTheModel() throws {
        try #require(!Self.source.isEmpty)
        #expect(Self.source.contains("projectURL: projectRoot"),
                "the editor's RecipientAccessContext no longer takes the root the shell resolved")
        #expect(Self.source.contains("projectRoot: model.projectRoot"),
                "FileDetailView is no longer handed FileListModel.projectRoot — a second derivation is back")
    }
}

// MARK: - Task 7 (F2): reaching the new-file wizard from the app

/// `AppShell.makeNewFileModel(projectRoot:keyStore:)` is the pure gate behind
/// the toolbar "+" and ⌘N: both call it (see `NewFileRequestWiringTests`
/// below), and it is the one place that decides whether there is a project
/// to create a file in at all.
///
/// This is the behavioural half of Step 1's "⌘N bez vybraného projektu nic
/// neotevře" — the structural half (that `FileListView`, and therefore its
/// toolbar row, is never constructed without a project) is already true by
/// construction in `ProjectWorkspaceView.fileListPane` and is not something a
/// unit test can observe further; this pins the decision the wiring is built
/// on so a future call site cannot construct a `NewSecretFileModel` for a
/// `nil` root by mistake.
@MainActor
@Suite("The new-file request needs a project, exactly like the model it builds")
struct NewFileModelGateTests {
    @Test("no project selected means no model, so ⌘N/+ have nothing to open")
    func noProjectMeansNoModel() {
        let keyStore = SessionKeyStore()
        #expect(AppShell.makeNewFileModel(projectRoot: nil, keyStore: keyStore) == nil)
    }

    @Test("a selected project produces a model rooted exactly there")
    func projectSelectedProducesModel() {
        let keyStore = SessionKeyStore()
        let root = URL(fileURLWithPath: "/tmp/does-not-need-to-exist-for-this-check")
        let model = AppShell.makeNewFileModel(projectRoot: root, keyStore: keyStore)
        #expect(model?.projectRoot == root)
    }
}

/// The wiring itself, read as source — the same technique
/// `OuterSidebarWiringTests`/`AppShellProjectRootSourceTests` use for the
/// same reason: `ProjectWorkspaceView` is a `private struct` with only
/// `private @State`, so nothing here can render it or drive its bindings
/// directly.
///
/// ## What this suite exists to catch
/// `NewSecretFileSheet`'s `onCreated` callback is the one new door this task
/// opens onto `selectedFileURL` — the property `requestFileSwitch(to:)` is
/// documented to be the *only* writer of, precisely so a switch away from a
/// dirty document is never silent. A completion handler that calls
/// `activateFile(url)` directly (because "the file is new, there's nothing
/// to lose by opening it") would be correct about the *new* file and wrong
/// about the *currently open* one — that document's unsaved edits are
/// exactly what `requestFileSwitch` exists to protect, and this task's brief
/// calls this out by name as the regression it is most likely to cause.
@Suite("Opening a newly created file goes through the same guard as every other file switch")
struct NewFileSwitchWiringTests {
    private static var appShellSource: String {
        get throws {
            try String(
                contentsOfFile: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Sources/SopsUI/AppShell.swift").path,
                encoding: .utf8)
        }
    }

    private static var sidebarSource: String {
        get throws {
            try String(
                contentsOfFile: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Sources/SopsUI/Shell/ProjectTreeSidebar.swift").path,
                encoding: .utf8)
        }
    }

    /// The text of `onCreated: { created in ... }`'s closure body, matched by
    /// counting braces rather than searching for the next `}` — the closure
    /// wraps a `Task { ... }`, and a naive search would stop at that nested
    /// block's own closing brace and silently check nothing.
    private static func onCreatedClosureBody(in source: String) -> String? {
        guard let marker = source.range(of: "onCreated: { created in") else { return nil }
        var depth = 0
        var index = marker.upperBound
        var body = ""
        while index < source.endIndex {
            let char = source[index]
            if char == "{" { depth += 1 }
            if char == "}" {
                if depth == 0 { return body }
                depth -= 1
            }
            body.append(char)
            index = source.index(after: index)
        }
        return nil
    }

    @Test("the created file is opened through requestFileSwitch, never activateFile or a direct write")
    func createdFileGoesThroughTheGuard() throws {
        let source = try Self.appShellSource
        let body = try #require(
            Self.onCreatedClosureBody(in: source),
            "AppShell no longer wires NewSecretFileSheet's onCreated as `{ created in ... }` — update this probe if the parameter was renamed")

        #expect(
            body.contains("requestSwitch(to: .file(project: request.projectID, url: created))"),
            "the created file's completion no longer goes through requestSwitch — a dirty open document would lose its guard")
        #expect(
            !body.contains("selection ="),
            "the created file's completion writes selection directly, bypassing requestSwitch — the one property it is documented to be the sole writer of")
    }

    @Test("the file list is refreshed on completion, so the new file is there to select")
    func refreshesFileListOnCreate() throws {
        let source = try Self.appShellSource
        let body = try #require(Self.onCreatedClosureBody(in: source))
        #expect(
            body.contains("trees.refresh(project)"),
            "the project tree is never refreshed when a file is created — the new file would have no row to be selected")
    }

    @Test("the new-file request is built through the project gate, not constructed directly")
    func newFileRequestGoesThroughTheGate() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains("Self.makeNewFileModel("),
            "the new-file request handler no longer calls the pure project gate — a call site could build a NewSecretFileModel with no project selected")
    }

    @Test("the sidebar presents its + / ⌘N through a caller-supplied action, not a decision of its own")
    func sidebarForwardsTheAction() throws {
        let source = try Self.sidebarSource
        #expect(
            source.contains("onNewFile(project.id)"),
            "ProjectTreeSidebar no longer routes its new-file control to the caller's action — the button has nowhere to send its click")
        #expect(
            source.contains("keyboardShortcut(\"n\", modifiers: .command)"),
            "the sidebar no longer wires ⌘N onto the new-file action")
    }

    /// Ticket #25 claim 2. `FileListView` only ever *asks* for an unfollowed
    /// symlink's target to be added as a project (see `onAddProjectAtPath`'s
    /// own doc comment) — the same "this view decides nothing" shape as
    /// `onNewFile`, checked the same way: by reading the wiring rather than
    /// pressing the button, since a second overlapping AX press probe in this
    /// same file's test process is exactly the shared-flag hazard
    /// `AccessibilityTreeTests`' doc comment (and this app's own STATE.md)
    /// records — not worth adding for one more button when the source-text
    /// check already proves the call reaches `ProjectSidebarModel.addProject`.
    @Test("the Add as Project action reaches ProjectSidebarModel.addProject, not a second implementation")
    func addProjectActionReachesTheSidebarModel() throws {
        let appShellSource = try Self.appShellSource
        let routingMessage = "AppShell no longer routes FileListView's Add-as-Project action through "
            + "ProjectSidebarModel.addProject — a symlink target could now be added by some other, "
            + "unaudited path, or not at all"
        #expect(
            appShellSource.contains("onAddProjectAtPath: { path in projects.addProject(path: path) }"),
            "\(routingMessage)")

        let homeSource = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SopsUI/Shell/ProjectHomeView.swift").path,
            encoding: .utf8)
        let parameterMessage = "ProjectHomeView no longer takes an onAddProjectAtPath action — the "
            + "unfollowed-symlink footnote's button has nowhere to route its click"
        #expect(homeSource.contains("onAddProjectAtPath"), "\(parameterMessage)")
    }
}
