import Foundation
import SopsProjects
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

// MARK: - M5: one project root, not two

/// `AppShell` is a `View` struct whose state is all `private @State`, so there
/// is no seam a runtime test can reach to ask it which project root it handed
/// each Access panel. What can be checked is the source itself — the same
/// technique `ProjectScopeDisclosureStructureTests` and the engine's
/// `exports_test.go` use where the property is structural rather than
/// behavioural.
///
/// The defect: the per-file panel took its registry root from an ID lookup in
/// `projects.groups`, while the project-wide panel took `fileListModel
/// .projectRoot`. Those disagree whenever the lookup comes back empty — the
/// project dropped out of the sidebar, or the store has not settled — and the
/// visible result was the same project showing recipients *with* labels in one
/// panel and *without* them in the other, at the same moment.
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

    /// The argument text after `marker`, up to the closing paren or newline.
    private static func argument(after marker: String) -> String? {
        guard let range = source.range(of: marker) else { return nil }
        let rest = source[range.upperBound...]
        let raw = rest.prefix { $0 != ")" && $0 != "," && !$0.isNewline }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    /// Resolves one alias hop: a single-line `private var name: URL? { expr }`,
    /// or the one helper that takes a root as a parameter. Anything deeper is
    /// left alone deliberately — a root that needs more than one hop to explain
    /// is the thing this test exists to notice.
    private static func resolved(_ token: String) -> String {
        if let range = source.range(of: "private var \(token): URL? { ") {
            let body = source[range.upperBound...].prefix { $0 != "}" }
            return body.trimmingCharacters(in: .whitespaces)
        }
        if token == "projectRoot", let range = source.range(of: "projectAccessBar(projectRoot: ") {
            return String(source[range.upperBound...].prefix { $0 != ")" })
        }
        return token
    }

    @Test("the per-file panel's registry root and the project panel's root are the same source")
    func bothPanelsShareOneRoot() throws {
        try #require(!Self.source.isEmpty, "could not read AppShell.swift")

        let perFile = try #require(
            Self.argument(after: "projectURL:"),
            "AppShell no longer passes a projectURL to RecipientAccessContext")
        let projectWide = try #require(
            Self.argument(after: "ProjectAccessModel(projectRoot: "),
            "AppShell no longer constructs a ProjectAccessModel")

        let perFileRoot = Self.resolved(perFile)
        let projectWideRoot = Self.resolved(projectWide)

        #expect(perFileRoot.contains("fileListModel"),
                "the per-file panel derives its registry root from \(perFileRoot), not from the file list model the project panel uses")
        #expect(projectWideRoot.contains("fileListModel"),
                "the project panel derives its root from \(projectWideRoot)")
    }

    /// And the discarded source stays discarded: a second derivation reappearing
    /// is the whole defect, whatever it gets named next time.
    ///
    /// Written as "exactly one, and it is *that* one" rather than "no more than
    /// one". The earlier version accepted zero *or* one, which meant a single
    /// re-introduction — the defect itself, before anyone compounds it — passed
    /// here and was caught only by `bothPanelsShareOneRoot` next door. Counting
    /// alone would not be enough either: two derivations is not the failure, a
    /// derivation feeding something other than `fileListModel` is, and a diff
    /// that adds one to a panel while deleting the legitimate one keeps the
    /// count at one. So the line is checked, not just the tally.
    @Test("the one project-root derivation in AppShell is the one that feeds the file list model")
    func noSecondDerivation() throws {
        try #require(!Self.source.isEmpty)
        let marker = "URL(fileURLWithPath: project.rootPath)"
        let derivations = Self.source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.contains(marker) }

        #expect(derivations.count == 1,
                "AppShell builds a project root URL from projects.groups \(derivations.count) times; there is one legitimate derivation and every panel reads it through fileListModel")
        #expect(derivations.first?.contains("fileListModel = FileListModel(projectRoot:") == true,
                "the one project-root derivation no longer feeds fileListModel directly, so whatever reads it now may be a second source of truth: \(String(derivations.first ?? "")) — if this line was extracted deliberately and fileListModel still receives it, update this pin rather than working around it")
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

    private static var fileListViewSource: String {
        get throws {
            try String(
                contentsOfFile: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Sources/SopsUI/Projects/FileListView.swift").path,
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
            body.contains("requestFileSwitch(to: created)"),
            "the created file's completion no longer calls requestFileSwitch(to: created) — a dirty open document would lose its guard")
        #expect(
            !body.contains("activateFile("),
            "the created file's completion calls activateFile directly, bypassing WorkspaceSwitchDecision entirely — an open dirty document would be torn down with no prompt")
        #expect(
            !body.contains("selectedFileURL ="),
            "the created file's completion writes selectedFileURL directly, bypassing requestFileSwitch — the one property it is documented to be the sole writer of")
    }

    @Test("the file list is refreshed on completion, so the new file is there to select")
    func refreshesFileListOnCreate() throws {
        let source = try Self.appShellSource
        let body = try #require(Self.onCreatedClosureBody(in: source))
        #expect(
            body.contains("fileListModel?.refresh()") || body.contains("fileListModel.refresh()"),
            "the file list model is never refreshed when a file is created — the new file would not appear to be selected")
    }

    @Test("the new-file request is built through the project gate, not constructed directly")
    func newFileRequestGoesThroughTheGate() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains("AppShell.makeNewFileModel("),
            "the new-file request handler no longer calls the pure project gate — a call site could build a NewSecretFileModel with no project selected")
    }

    @Test("FileListView presents its + / ⌘N through a caller-supplied action, not a decision of its own")
    func fileListViewForwardsTheAction() throws {
        let source = try Self.fileListViewSource
        #expect(
            source.contains("onNewFile"),
            "FileListView no longer takes an onNewFile action — Task 7's toolbar button has nowhere to route its click")
        #expect(
            source.contains("keyboardShortcut(\"n\", modifiers: .command)"),
            "FileListView no longer wires ⌘N onto the new-file action")
    }
}
