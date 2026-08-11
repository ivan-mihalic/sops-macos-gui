import Foundation
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
    @Test("no second project-root derivation survives in AppShell")
    func noSecondDerivation() throws {
        try #require(!Self.source.isEmpty)
        #expect(!Self.source.contains("URL(fileURLWithPath: project.rootPath)")
                || Self.source.components(separatedBy: "URL(fileURLWithPath: project.rootPath)").count == 2,
                "AppShell builds a project root URL from projects.groups in more than one place")
    }
}
