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

/// The per-file status dot, which nothing behavioural covered until this
/// suite existed.
///
/// A coloured dot is the easiest thing in this app to compute correctly and
/// never draw — `AccessInventory` had full coverage of the *statuses*
/// (`AccessInventoryTests`) and the sidebar drew them with no test looking,
/// which is exactly the model-knew-view-dropped-it shape this repo has been
/// bitten by twice already.
///
/// It also pins the half that matters more than the colour: a dot's meaning
/// reaches an assistive client as words. Colour alone is never a message
/// here (`ColourIndependenceTests` states the rule), so `.ruleDiffers` and
/// `.ungoverned` each carry their sentence as an accessibility label and a
/// tooltip, and `.inSync` — the ordinary state — deliberately carries
/// neither. Asserting that third case is what stops a future "just label
/// every dot" change from turning a long list into noise.
@Suite("The per-file status dot says what it means")
@MainActor
struct ProjectTreeSidebarStatusDotTests {

    /// One project holding all three states at once, over a `.sops.yaml`
    /// whose single rule governs `governed/` only:
    ///
    /// | file | wrapped for | status |
    /// |---|---|---|
    /// | `governed/in-sync.sops.env` | the rule's own recipient | `.inSync` |
    /// | `governed/drift.sops.env` | a stranger | `.ruleDiffers` |
    /// | `loose/ungoverned.sops.env` | the rule's recipient | `.ungoverned` |
    ///
    /// The third one matters: it is wrapped for the *same* key the rule
    /// declares, so a test that only compared recipients would call it in
    /// sync. It is ungoverned because no rule's `path_regex` matches it at
    /// all, which is a different claim and gets a different sentence.
    private func threeStatusProject() throws -> ProjectTreeSidebarTests.Fixture {
        let owner = try TreeSidebarAgeKeyPair.generate()
        let stranger = try TreeSidebarAgeKeyPair.generate()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-status-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try """
            creation_rules:
              - path_regex: ^governed/
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"),
                      atomically: true, encoding: .utf8)

        func write(_ relativePath: String, for recipient: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try SopsBridge.encrypt("TOKEN=placeholder\n", format: .dotenv, recipients: [recipient])
                .write(to: url, atomically: true, encoding: .utf8)
        }
        try write("governed/in-sync.sops.env", for: owner.public)
        try write("governed/drift.sops.env", for: stranger.public)
        try write("loose/ungoverned.sops.env", for: owner.public)

        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tree-status-store-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(storeDirectory)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: storeDirectory.appendingPathComponent("projects.json"))
        let project = try store.add(path: root.path)
        return ProjectTreeSidebarTests.Fixture(root: root, store: store, project: project)
    }

    @Test("a drifted file and an ungoverned one each say why; an in-sync file says nothing")
    func statusDotsAnnounceThemselves() async throws {
        let fixture = try threeStatusProject()
        let projects = ProjectSidebarModel(store: fixture.store)
        projects.selection = fixture.projectID
        let trees = ProjectTreeStore(keyStore: SessionKeyStore())
        await trees.refresh(fixture.project)

        // Precondition on the inventory itself. Without it a view drawing no
        // dots at all would fail below in a way that reads like a view bug,
        // when the real answer would be that the statuses never got computed.
        let inventory = try #require(trees.inventory(for: fixture.projectID))
        func status(_ suffix: String) throws -> AccessInventory.FileStatus {
            try #require(inventory.files.first { $0.relativePath.hasSuffix(suffix) }?.status,
                         "no inventory entry for \(suffix)")
        }
        #expect(try status("in-sync.sops.env") == .inSync)
        if case .ruleDiffers = try status("drift.sops.env") {} else {
            Issue.record("the drifted file is not reported as drifted; the view has nothing to draw")
        }
        #expect(try status("ungoverned.sops.env") == .ungoverned)

        let nodes = AXProbe.tree(size: CGSize(width: 300, height: 600)) {
            ProjectTreeSidebar(
                projects: projects, trees: trees, selection: .constant(nil),
                onNewFile: { _ in }, onAddProjectAtPath: { _ in })
        }

        // Counted, not merely present. Three files are on screen and exactly
        // one of them is drifted, so a view that labelled *every* dot with
        // the drift sentence would pass a bare `contains` and be wrong about
        // two rows — including the in-sync one, which must stay silent.
        let rewrap = nodes.filter {
            $0.help == LocalizedKey.sidebarFileNeedsRewrap.text
                || $0.label == LocalizedKey.sidebarFileNeedsRewrap.text
        }
        let ungoverned = nodes.filter {
            $0.help == LocalizedKey.sidebarFileUngoverned.text
                || $0.label == LocalizedKey.sidebarFileUngoverned.text
        }

        #expect(!rewrap.isEmpty,
                "the drifted file's dot says nothing — a user sees a colour and no reason, and an assistive client sees neither")
        #expect(!ungoverned.isEmpty,
                "the ungoverned file's dot says nothing")
        #expect(rewrap.count == 1,
                "\(rewrap.count) rows claim to need re-wrapping; exactly one file in this project does")
        #expect(ungoverned.count == 1,
                "\(ungoverned.count) rows claim to be ungoverned; exactly one file in this project is")
    }
}

/// The Access panel's model outlives a re-render.
///
/// ## The defect this exists to forbid
/// `ProjectAccessView` holds its model as `@Bindable` and loads it from a
/// bare `.task { await model.load() }` — no `id:`, so it runs once per view
/// *identity*. The identity of the Access pane does not change when
/// `AppShell`'s body is merely re-evaluated (another project's scan
/// finishing, `lastError` clearing, a window resize). A model constructed
/// inline in that body would therefore be swapped for a fresh, **unloaded**
/// one while the view stayed put and never re-ran its `.task`: staged
/// recipients gone, panel blank, nothing logged. That is the SOPS-37 shape —
/// a panel that takes a recipient and silently drops it.
///
/// ## What this can and cannot assert
/// `AppShell`'s body cannot be evaluated in a test, so "two body evaluations
/// see the same instance" is asserted where the instance actually comes
/// from: two calls to the store, which is what a second body evaluation
/// makes. The other half — that `AppShell` asks the store rather than
/// building one itself — is the source check below, and it is the half a
/// future edit is most likely to get wrong.
@Suite("The Access panel's model survives a re-render")
@MainActor
struct ProjectAccessModelIdentityTests {

    private func fixture() throws -> ProjectTreeSidebarTests.Fixture {
        try ProjectTreeSidebarTests.makeProject(files: ["secrets/local.sops.env"])
    }

    @Test("asking twice for the same project's Access model returns the same instance")
    func modelIsReused() throws {
        let f = try fixture()
        let trees = ProjectTreeStore(keyStore: SessionKeyStore())

        let first = trees.accessModel(for: f.project, targetFile: nil)
        let second = trees.accessModel(for: f.project, targetFile: nil)

        #expect(first === second,
                "a second render built a fresh, unloaded ProjectAccessModel — staged recipients would vanish with no error")
    }

    /// The one input that legitimately invalidates it: the panel plans around
    /// the rule governing `targetFile`, so a model built for a different file
    /// would describe the wrong rule.
    @Test("changing the target file builds a new model, because it plans a different rule")
    func targetFileChangeRebuilds() throws {
        let f = try fixture()
        let trees = ProjectTreeStore(keyStore: SessionKeyStore())
        let file = f.root.appendingPathComponent("secrets/local.sops.env")

        let noTarget = trees.accessModel(for: f.project, targetFile: nil)
        let withTarget = trees.accessModel(for: f.project, targetFile: file)
        #expect(noTarget !== withTarget,
                "the panel kept a model planned around a different file, so it describes the wrong rule")
        #expect(trees.accessModel(for: f.project, targetFile: file) === withTarget,
                "the new model is itself not reused, so the same defect returns one render later")
    }

    @Test("forgetting a project drops its Access model with everything else")
    func forgetDropsTheModel() throws {
        let f = try fixture()
        let trees = ProjectTreeStore(keyStore: SessionKeyStore())
        let before = trees.accessModel(for: f.project, targetFile: nil)
        trees.forget(f.projectID)
        #expect(trees.accessModel(for: f.project, targetFile: nil) !== before,
                "a removed and re-added project answers from a model built before it was forgotten")
    }

    @Test("AppShell asks the store for the model rather than constructing one in its body")
    func shellDoesNotBuildTheModelInline() throws {
        let source = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SopsUI/AppShell.swift").path,
            encoding: .utf8)
        let stripped = OuterSidebarWiringTests.strippingComments(source)

        #expect(!stripped.contains("ProjectAccessModel("),
                "AppShell constructs a ProjectAccessModel in its own body again — every re-render while Access is selected swaps in an unloaded one and the view never re-runs the .task that loads it")
        #expect(stripped.contains("trees.accessModel("),
                "AppShell no longer takes the Access model from ProjectTreeStore, so nothing guarantees it is the same one across renders")
    }
}
