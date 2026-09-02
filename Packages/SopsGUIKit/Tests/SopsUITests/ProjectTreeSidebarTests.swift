import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

/// The one sidebar (SOPS-39 task 6).
///
/// Before this, the window had four columns and the file list only ever
/// showed *one* project — whichever the middle column had selected. The tree
/// replaces both: every added project is a row, its encrypted files are its
/// children, and an Access row sits under them. About and Settings stay
/// pinned at the bottom (PROPOSAL §4).
///
/// Asserted on the rendered accessibility tree rather than on source text,
/// for the reason `FileListViewWiringTests`' header records: a value the
/// model carries and the view never draws is invisible to a user, and every
/// source-level substitute for that check has been defeated in this repo at
/// least once.
@Suite("The project tree sidebar")
@MainActor
struct ProjectTreeSidebarTests {

    /// A project with real sops ciphertext in it, plus the store and sidebar
    /// model wired the way `AppShell` wires them. Real bridge output, never a
    /// hand-written `ENC[...]` lookalike: the tree decides what to show by
    /// scanning these files.
    struct Fixture {
        let root: URL
        let store: ProjectStore
        let project: StoredProject
        var projectID: StoredProject.ID { project.id }
    }

    static func makeProject(files: [String]) throws -> Fixture {
        let key = try TreeSidebarAgeKeyPair.generate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-tree-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try """
            creation_rules:
              - path_regex: .*
                age: \(key.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        for relativePath in files {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SopsBridge.encrypt("TOKEN=placeholder\n", format: .dotenv, recipients: [key.public])
                .write(to: url, atomically: true, encoding: .utf8)
        }

        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("project-tree-store-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: storeDirectory.appendingPathComponent("projects.json"))
        let project = try store.add(path: root.path)
        return Fixture(root: root, store: store, project: project)
    }

    @Test("the sidebar lists each project's files and an Access row under it")
    func treeShowsFilesAndAccess() async throws {
        let fixture = try Self.makeProject(files: ["secrets/local.sops.env", "secrets/prod.sops.env"])
        let projects = ProjectSidebarModel(store: fixture.store)
        projects.selection = fixture.projectID
        let trees = ProjectTreeStore(keyStore: SessionKeyStore())
        await trees.refresh(fixture.project)

        // Precondition rather than an implicit assumption: if the scan
        // itself found nothing, every assertion below would be about a view
        // that had nothing to draw, and the failure would read as a view bug.
        let scanned = trees.model(for: fixture.project)
        try #require(scanned.files.count == 2,
                     "the scan found \(scanned.files.map { $0.url.lastPathComponent }) — the view has nothing to be wrong about")

        let nodes = AXProbe.tree(size: CGSize(width: 300, height: 1000)) {
            ProjectTreeSidebar(
                projects: projects, trees: trees, selection: .constant(nil),
                onNewFile: { _ in }, onAddProjectAtPath: { _ in })
        }
        // Label *and* value *and* help, not `label` alone: SwiftUI reports a
        // `List` row built from a `Label` inside an `HStack` with its text in
        // the element's **value**, leaving `label` empty. Asserting on
        // `label` alone finds nothing and reads as "the row is missing" —
        // measured here first, and it is why the sibling suite
        // (`ProjectHomeViewWiringTests`) has always joined all three.
        let shown = nodes.map { $0.label + " " + $0.value + " " + $0.help }
            .joined(separator: "\n")

        #expect(shown.contains("secrets/local.sops.env"),
                "the tree did not list the project's first encrypted file")
        #expect(shown.contains("secrets/prod.sops.env"),
                "the tree did not list the project's second encrypted file")
        #expect(shown.contains(LocalizedKey.sidebarAccess.text),
                "the project has no Access row, so its recipients are unreachable from the sidebar")
        #expect(shown.contains(LocalizedKey.sidebarAbout.text)
                && shown.contains(LocalizedKey.sidebarSettings.text),
                "About and Settings are no longer pinned in the sidebar (PROPOSAL §4)")
    }
}

/// Key generation for this suite's fixtures. Shells out because there is no
/// in-process keygen — the same shape `FourFormatProjectIntegrationTests`
/// uses, and for the same reason.
struct TreeSidebarAgeKeyPair {
    let `private`: String
    let `public`: String

    struct Failure: Error, CustomStringConvertible { let description: String }

    static func generate() throws -> TreeSidebarAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { throw Failure(description: "age-keygen not found in \(candidates)") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") { priv = String(line) }
            else if line.hasPrefix("# public key: ") { pub = String(line.dropFirst("# public key: ".count)) }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw Failure(description: "age-keygen produced no usable key pair")
        }
        return TreeSidebarAgeKeyPair(private: priv, public: pub)
    }
}

/// What the tree's **file rows** show — the half of the old
/// `FileListViewWiringTests` that was about individual files rather than
/// about the scan (that half is `ProjectHomeViewWiringTests` now).
///
/// Same discipline, same reason: a flag the model computes and the view never
/// draws is invisible to a user, and the whole suite stays green either way.
/// Fixtures are hand-written sops-shaped text rather than bridge output —
/// these are claims about the *view*, not about sops's file formats.
@Suite("What the tree's file rows show")
@MainActor
struct ProjectTreeSidebarRowTests {

    private static let size = CGSize(width: 300, height: 600)

    /// Everything the rendered tree would say, for one project already
    /// scanned into the store.
    private func text(root: URL, keyStore: SessionKeyStore? = nil) async throws -> String {
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-rows-store-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: storeDirectory.appendingPathComponent("projects.json"))
        let project = try store.add(path: root.path)

        let projects = ProjectSidebarModel(store: store)
        projects.selection = project.id
        let trees = ProjectTreeStore(keyStore: keyStore ?? SessionKeyStore())
        await trees.refresh(project)

        return AXProbe.tree(size: Self.size) {
            ProjectTreeSidebar(
                projects: projects, trees: trees, selection: .constant(nil),
                onNewFile: { _ in }, onAddProjectAtPath: { _ in })
        }
        .map { $0.label + " " + $0.value + " " + $0.help }
        .joined(separator: "\n")
    }

    private func project(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-rows-\(name)-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// The JSON counterpart — hand-written text carrying the structural shape
    /// `SopsMetadataShape.isJSONMetadata` requires (a `sops` object with `mac`
    /// and `version`).
    private func writeJSONSopsLike(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {"key":"ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]","sops":{"age":[{"recipient":"age1exampleexampleexampleexampleexampleexampleexampleexamplex","enc":"-----BEGIN AGE ENCRYPTED FILE-----\\n-----END AGE ENCRYPTED FILE-----\\n"}],"mac":"ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]","version":"3.13.3"}}
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The canary. Without a populated tree every assertion here would pass
    /// by finding nothing — the trap `AXProbe`'s own doc comment describes.
    @Test("the probe renders the tree's file rows at all")
    func theTreePopulates() async throws {
        let root = try project("canary")
        try writeSopsLike(root, at: "config/secrets.yaml")

        #expect(try await text(root: root).contains("config/secrets.yaml"),
                "the tree rendered no file rows — every other test in this suite would be vacuous")
    }

    /// A project whose only sops file is JSON used to hit the empty
    /// placeholder with the "other format" note rendered in a branch it could
    /// never reach — this test used to pin exactly that. SOPS-38 phase F2
    /// task 3 closed the gap: `ProjectScanner.classify` routes JSON into
    /// `tree.encrypted` and `EncryptedFileMetadata` reads its recipients, so
    /// JSON is listed and openable exactly like YAML and dotenv are. The test
    /// pins the opposite of what it used to, over the same fixture, rather
    /// than being deleted and losing the "json used to be the one" history.
    @Test("a project holding only a json sops file gets a row for it")
    func jsonFileIsListed() async throws {
        let root = try project("json-listed")
        try writeJSONSopsLike(root, at: "config/secrets.json")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        #expect(model.otherFormatCount == 0,
                "json stopped being \"another format\" as of SOPS-38 phase F2 task 3")
        #expect(!model.files.isEmpty, "a json sops file must be listed exactly like yaml and dotenv are")

        #expect(try await text(root: root).contains("config/secrets.json"),
                "a json sops file must appear as a row in the tree, not behind a note about a format nothing here produces any more")
    }

    // MARK: - SOPS-38 phase F3: the read-only badge

    /// `FileListModelTests` proves `ListedFile.isReadOnly` itself — this is
    /// the view half: a flag the model computes and the view never shows is
    /// invisible to a user, and the whole suite stays green either way.
    @Test("a file this session's key cannot decrypt shows a read-only badge")
    func readOnlyBadgeIsShown() async throws {
        let root = try project("read-only-badge")
        try writeSopsLike(root, at: "config/secrets.yaml")
        let stranger = try AgeKeyPairForTests.generate()
        let store = SessionKeyStore()
        try store.importKey(stranger.private)

        let model = FileListModel(projectRoot: root, keyStore: store)
        await model.refresh()
        try #require(model.files.first?.isReadOnly == true,
                     "precondition: the model itself must flag this file read-only")

        #expect(try await text(root: root, keyStore: store)
                    .contains(LocalizedKey.filesReadOnlyBadge.text),
                "the model flagged the file read-only and the tree never said so")
    }

    /// The negative case a hardcoded badge would sail past: the same
    /// sops-shaped file over a store with no key at all —
    /// `ListedFile.isReadOnly`'s own conservative default.
    @Test("a session with no key configured shows no read-only badge")
    func noBadgeWithoutASessionKey() async throws {
        let root = try project("no-key-no-badge")
        try writeSopsLike(root, at: "config/secrets.yaml")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try #require(model.files.first?.isReadOnly == false,
                     "precondition: no key store means the model itself must not claim read-only")

        #expect(!(try await text(root: root).contains(LocalizedKey.filesReadOnlyBadge.text)),
                "a session with no key must not show the read-only badge")
    }
}
