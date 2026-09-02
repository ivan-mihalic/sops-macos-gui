import ScratchCleanup
import AppKit
import SopsHealth
import SopsProjects
import SwiftUI
import Testing
@testable import SopsUI

/// `FileListModelTests` asserts that the *model* carries `incompleteScanReason`
/// and `skippedDirectoryNames`. That is half the story, and the half that
/// cannot fail usefully on its own: deleting every line of the view that puts
/// those two values in front of a user left the entire 628-test suite green.
/// The model knew; the view threw it away; nothing noticed.
///
/// The view is `ProjectHomeView` since SOPS-39 task 6 — the file rows moved to
/// the sidebar tree, and their assertions with them (to
/// `ProjectTreeSidebarTests`), while everything describing the *scan* rather
/// than a single file stayed together and moved here.
///
/// Demonstrated by mutation, not supposed. So these assert on the rendered
/// accessibility tree — what an assistive client would actually be told — which
/// is the closest this project can get to "the user saw it" without launching
/// the app.
@Suite("What a project detail pane actually shows")
@MainActor
struct ProjectHomeViewWiringTests {

    private static let size = CGSize(width: 360, height: 520)

    private func text(of model: FileListModel) -> String {
        AXProbe.tree(size: Self.size) {
            ProjectHomeView(model: model, onNewFile: {})
        }
        .map { $0.label + " " + $0.value + " " + $0.help }
        .joined(separator: "\n")
    }

    private func project(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-home-\(name)-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        return root
    }

    private func writeSopsLike(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
        sops:
            age:
                - recipient: age1exampleexampleexampleexampleexampleexampleexampleexamplex
            mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            version: 3.13.3
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The JSON counterpart to `writeSopsLike` — hand-written text carrying
    /// the structural shape `SopsMetadataShape.isJSONMetadata` requires
    /// (a `sops` object with `mac` and `version`), for the same reason
    /// `writeSopsLike` is hand-written rather than bridge-encrypted: this
    /// suite is about `FileListView`'s own wiring, not sops's file format.
    private func writeJSONSopsLike(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"key":"ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]","sops":{"age":[{"recipient":"age1exampleexampleexampleexampleexampleexampleexampleexamplex","enc":"-----BEGIN AGE ENCRYPTED FILE-----\\n-----END AGE ENCRYPTED FILE-----\\n"}],"mac":"ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]","version":"3.13.3"}}
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The canary. Without a populated tree every assertion here would pass by
    /// finding nothing — the same trap `AXProbe`'s own doc comment describes.
    @Test("the probe renders this view at all")
    func theTreePopulates() async throws {
        let root = try project("canary")
        try writeSopsLike(root, at: "config/secrets.yaml")
        let model = FileListModel(projectRoot: root)
        await model.refresh()

        #expect(text(of: model).contains(LocalizedKey.filesNewFileButton.text),
                "the detail pane rendered nothing — every other test in this suite would be vacuous")
    }

    @Test("a scan that could not cover the tree says so on screen")
    func incompleteScanIsShown() async throws {
        let root = try project("incomplete")
        let vault = root.appendingPathComponent("vault")
        try writeSopsLike(root, at: "vault/secrets.yaml")
        try writeSopsLike(root, at: "config/secrets.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) == nil,
                     "the lock denied nothing — running as root would make this test vacuous")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        let reason = try #require(model.incompleteScanReason, "precondition: the model knows the scan fell short")

        let shown = text(of: model)
        #expect(shown.contains(LocalizedKey.filesScanIncompleteTitle.text),
                "the model knew the scan was incomplete and the view did not say so")
        #expect(shown.contains(reason), "the banner did not carry the reason")
    }

    /// The claim that must not be made. This is the sentence the whole
    /// `incompleteScanReason` design exists to prevent.
    ///
    /// The bare "no encrypted files found" claim this test used to check
    /// against directly (`files.empty.title`) no longer exists in the
    /// catalog at all as of Phase 3 Task 2 — a *complete* empty scan now
    /// renders `ProjectStartHereView` instead, which never makes that claim
    /// (see that type's own doc comment). What is left to guard here is
    /// that an *incomplete* scan still gets the narrowed placeholder rather
    /// than nothing — `ProjectStartHereViewTests
    /// .FileListViewStartHereWiringTests.incompleteScanNeverShowsGuidance`
    /// covers the sibling claim, that the start-here guidance itself must
    /// not appear over this exact fixture.
    @Test("an incomplete scan never claims the project holds no encrypted files")
    func incompleteScanNeverClaimsEmptiness() async throws {
        let root = try project("empty-partial")
        let vault = root.appendingPathComponent("vault")
        try writeSopsLike(root, at: "vault/secrets.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: vault.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault.path) }
        try #require((try? FileManager.default.contentsOfDirectory(atPath: vault.path)) == nil,
                     "the lock denied nothing — running as root would make this test vacuous")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.files.isEmpty, "precondition: the scan found nothing it could reach")

        let shown = text(of: model)
        #expect(shown.contains(LocalizedKey.filesEmptyPartialTitle.text),
                "the narrowed empty state was not shown")
    }

    /// `.git` puts an entry in this list on every real repository, so an
    /// ordinary project must show it — it used to be nested inside a banner
    /// that fires only at the file-budget cap.
    @Test("directories the walk never enters are named on an ordinary scan",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "this asserts on text a *format* key produces, and swift test's native build system never compiles .xcstrings — every key falls back to its own raw value, which carries no %@ to substitute into; run under xcodebuild or swift test --build-system swiftbuild"),)
    func skippedDirectoriesAreShown() async throws {
        let root = try project("skipped")
        try writeSopsLike(root, at: "config/secrets.yaml")
        try writeSopsLike(root, at: "node_modules/pkg/secrets.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.skippedDirectoryNames.contains("node_modules"))

        #expect(text(of: model).contains("node_modules"),
                "the exclusion was recorded in the model and never shown")
    }

    /// A complete scan must not raise the banner, or "incomplete" carries no
    /// information and a hardcoded banner would pass every test above.
    @Test("a complete scan shows no warning banner")
    func completeScanShowsNoBanner() async throws {
        let root = try project("complete")
        try writeSopsLike(root, at: "config/secrets.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.incompleteScanReason == nil)

        #expect(!text(of: model).contains(LocalizedKey.filesScanIncompleteTitle.text),
                "a readable project was warned about")
    }
}
