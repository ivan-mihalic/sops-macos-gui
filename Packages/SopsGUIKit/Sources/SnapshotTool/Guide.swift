import SopsEngine
import SopsHealth
import SopsProjects
import SopsUI
import SwiftUI

// The images `docs/GUIDE.md` embeds, and nothing else.
//
// Separate from `Catalog` for two reasons that pull the same way:
//
// - These are **committed**, to `docs/images/`. `Catalog`'s output is
//   `.snapshots/`, gitignored and explicitly never committed (CLAUDE.md), so
//   the two sets have opposite lifecycles and should not share a filter.
// - The guide's fixtures mirror the walkthrough project the guide tells the
//   reader to create — same directory names, same file names, same keys, same
//   values. `Catalog`'s fixtures deliberately do the opposite: they are edge
//   cases chosen to stress layout (six services × three environments, a value
//   long enough to run past the field). Those make bad instructional images
//   and these would make bad review images.
//
// Names carry the step number they illustrate, so a reordered guide is a
// visible rename rather than a silently wrong picture.
@MainActor
enum Guide {
    static func all() async throws -> [Snapshot] {
        var snapshots: [Snapshot] = []
        snapshots += await onboarding()
        snapshots += try navigation()
        snapshots += try await projectAndFiles()
        snapshots += try await editor()
        snapshots += await settingsAndAbout()
        snapshots += try await access()
        return snapshots
    }

    private static let wizardSize = CGSize(width: 640, height: 520)
    private static let sidebarSize = CGSize(width: 260, height: 460)
    // Widened from 780×520 in SOPS-39 task 10. The editor is a table with a
    // trailing inspector column now, and at 780 the table had ~470 pt to draw
    // four columns in — the filename truncated in the header and the Key
    // column ran into the Value column. The inspector's own column is
    // reserved but stays blank (this renderer does not populate `.inspector`,
    // CLAUDE.md), which `guide-14b-inspector` is for.
    private static let editorSize = CGSize(width: 1000, height: 560)

    // MARK: - Steps 1–5: the first-run wizard

    /// The wizard's six steps, all fed the same finding set, so a reader who
    /// pages through the guide sees one continuous machine rather than six
    /// unrelated ones.
    private static func onboarding() async -> [Snapshot] {
        let names = ["01-welcome", "02-tools", "03-engine", "04-security", "05-projects", "06-summary"]
        var result: [Snapshot] = []
        for (index, name) in names.enumerated() {
            let health = await Fixtures.healthViewModel(findings: Fixtures.realisticFindings)
            let state = Fixtures.onboardingState()
            // `.welcome` is step 0, so step *n* is n advances past it.
            for _ in 0..<index { state.advance() }
            result.append(
                Snapshot("guide-\(name)", size: wizardSize) {
                    OnboardingWizard(health: health, state: state)
                })
        }
        return result
    }

    // MARK: - Step 7: the sidebar

    /// Rendered from `ProjectTreeSidebar` rather than from `AppShell`, and
    /// that is not a shortcut. A `NavigationSplitView`'s own `sidebar:`
    /// column comes back **blank** under this tool (CLAUDE.md, "What it still
    /// cannot see"), so an `AppShell` snapshot would show the reader an empty
    /// stripe where the navigation is. Standing alone, the identical `List`
    /// renders — and it is the same code the app runs, not a mock-up of it.
    ///
    /// A store with nothing in it, on purpose: this is the window a reader
    /// sees before they have added anything, so About and Settings pinned at
    /// the bottom are the whole subject.
    private static func navigation() throws -> [Snapshot] {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("guide-empty-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let projects = ProjectSidebarModel(
            store: ProjectStore(fileURL: base.appendingPathComponent("projects.json")))
        let trees = ProjectTreeStore(keyStore: SessionKeyStore())

        func sidebar(_ selection: WorkspaceSelection?) -> some View {
            ProjectTreeSidebar(
                projects: projects, trees: trees, selection: .constant(selection),
                onNewFile: { _ in }, onAddProjectAtPath: { _ in })
        }

        return [
            Snapshot("guide-07-sidebar", size: sidebarSize) { sidebar(nil) },
            Snapshot("guide-07-sidebar-about", size: sidebarSize) { sidebar(.about) },
            Snapshot("guide-07-sidebar-setup-guide", size: sidebarSize) { sidebar(.setupGuide) },
        ]
    }

    // MARK: - Steps 8–9: the project list and the file list

    /// The walkthrough project, exactly as `docs/GUIDE.md` has the reader
    /// build it: `config/production.secrets.yaml`, `config/staging.secrets
    /// .yaml`, and `services/worker.secrets.env`.
    ///
    /// The `.env` file is in the fixture on purpose. sops writes dotenv files
    /// too, and this app opens them exactly like the YAML files next to it
    /// (SOPS-38) — the file list draws no footnote for it at all, which is
    /// the point: a reader whose real project has one should see it listed
    /// and openable, not wonder why a file they can see in Finder is missing
    /// from the list.
    private static func demoProjectRoot() throws -> URL {
        // The UUID goes on the *parent*, never on the project directory
        // itself: the sidebar shows a project by its last path
        // component, so a uniquified root rendered as
        // `guide-project-B496602F-6D…` in an image whose caption tells the
        // reader it says `sops-demo-project`.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guide-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sops-demo-project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let key = try GuideKeyPair.generate()
        func write(_ relativePath: String, _ plaintext: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Real sops ciphertext through the in-process bridge, not a
            // hand-written `ENC[...]` lookalike: the file list decides what to
            // show by reading these files, and a fixture the scanner merely
            // happens to accept would make the image a claim about the fixture
            // rather than about the app.
            let encrypted = try SopsBridge.encrypt(plaintext, format: .yaml, recipients: [key.public])
            try encrypted.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("config/production.secrets.yaml", productionPlaintext)
        try write("config/staging.secrets.yaml", stagingPlaintext)

        // Real sops dotenv ciphertext through the in-process bridge — same
        // discipline as `write()` above, and the same values `docs/GUIDE.md`
        // has the reader put in this exact file. `ProjectScanner` classifies
        // it as `.dotenv` (SOPS-38) and the file list shows it as openable,
        // right alongside the two YAML files.
        let dotenv = root.appendingPathComponent("services/worker.secrets.env")
        try FileManager.default.createDirectory(
            at: dotenv.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encryptedDotenv = try SopsBridge.encrypt(workerDotenvPlaintext, format: .dotenv, recipients: [key.public])
        try encryptedDotenv.write(to: dotenv, atomically: true, encoding: .utf8)

        return root
    }

    private static func projectAndFiles() async throws -> [Snapshot] {
        let root = try demoProjectRoot()

        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("guide-store-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = ProjectStore(fileURL: base.appendingPathComponent("projects.json"))
        let project = try store.add(path: root.path)
        let projects = ProjectSidebarModel(store: store)
        projects.selection = project.id

        let trees = ProjectTreeStore(keyStore: SessionKeyStore())
        // Pre-refreshed for the same reason `Fixtures.healthViewModel` is: a
        // `.task` modifier never fires in this tool's offscreen render, so a
        // store left to refresh itself would draw a project with no children.
        await trees.refresh(project)

        let files = FileListModel(projectRoot: root)
        await files.refresh()

        func sidebar(_ selection: WorkspaceSelection?) -> some View {
            ProjectTreeSidebar(
                projects: projects, trees: trees, selection: .constant(selection),
                onNewFile: { _ in }, onAddProjectAtPath: { _ in })
        }

        return [
            // Steps 8 and 9 are one control now (SOPS-39 task 6): the
            // project and its files are the same tree, so the two images
            // differ by what is selected rather than by which column they
            // are of. `docs/GUIDE.md`'s prose for these two steps still
            // describes the old three-column window and has to be rewritten
            // alongside them.
            Snapshot("guide-08-projects", size: sidebarSize) {
                sidebar(.projectHome(project.id))
            },
            Snapshot("guide-09-files", size: sidebarSize) {
                sidebar(.file(project: project.id,
                              url: root.appendingPathComponent("config/production.secrets.yaml")))
            },
        ]
    }

    // MARK: - Steps 10–14: the editor

    /// The same plaintext the guide has the reader put in the file, so the
    /// rows in the image are the rows on their screen.
    ///
    /// Every value is inert by construction — an `.invalid` hostname (RFC
    /// 6761, guaranteed never to resolve) and keys with `DEMO` where the
    /// entropy would be. CLAUDE.md forbids secret values in this repository,
    /// and an editor screenshot is a picture of plaintext: this is the one
    /// fixture where that rule is the whole subject.
    private static let productionPlaintext = """
        database:
            url: postgres://demo:not-a-real-password@db.example.invalid:5432/demo
            pool_size: 20
        api:
            stripe_key: sk_live_DEMOxxxxxxxxxxxxxxxxxxxx
            sendgrid_key: SG.DEMOxxxxxxxxxxxxxxxxxxxx
        feature_flags:
            - new-checkout
            - beta-search
        """

    private static let stagingPlaintext = """
        database:
            url: postgres://demo:staging-not-real@db.staging.example.invalid:5432/demo
        api:
            stripe_key: sk_test_DEMOxxxxxxxxxxxxxxxxxxxx
        """

    /// The same values `docs/GUIDE.md`'s setup script puts in
    /// `services/worker.secrets.env` — see `demoProjectRoot()`.
    private static let workerDotenvPlaintext = """
        REDIS_URL=redis://cache.example.invalid:6379/0
        WORKER_TOKEN=demo-worker-token-0000
        """

    private static func editorModel() async throws -> SecretDocumentViewModel {
        let key = try GuideKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(productionPlaintext, format: .yaml, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/production.secrets.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    private static func editor() async throws -> [Snapshot] {
        let masked = try await editorModel()

        let revealedModel = try await editorModel()
        let revealed = Set(
            revealedModel.rows
                .filter { $0.path == ["database", "url"] }
                .map(\.id))
        guard !revealed.isEmpty else {
            throw GuideFixtureFailure(
                "no database.url row to reveal — guide-11 would show the same all-masked list as guide-10")
        }

        let editedModel = try await editorModel()
        guard let stripe = editedModel.rows.first(where: { $0.path == ["api", "stripe_key"] })
        else {
            throw GuideFixtureFailure(
                "no api.stripe_key row to edit — guide-12 would show a document with no unsaved changes")
        }
        editedModel.update(rowID: stripe.id, to: "sk_live_DEMOrotated0000000000")
        // Revealed, and that is the whole point of this image: an edited row
        // is masked like every other, so with it hidden the only difference
        // from `guide-10` is the header badge, and the reader cannot see what
        // they are being told they changed.
        let editedRevealed: Set<String> = [stripe.id]

        // No key imported at all: the state a reader hits if they open a file
        // before pasting their identity, and the one the guide's
        // troubleshooting section points at.
        let needsKey = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/production.secrets.yaml"),
            format: .yaml,
            keyStore: SessionKeyStore(),
            readFile: { _ in "never read — the key check happens first" })
        await needsKey.load()

        // The row the inspector is about: the same `database.url` the reveal
        // image uses, so a reader meets one row twice rather than two rows
        // once.
        let inspected = try await editorModel()
        guard let inspectedRow = inspected.rows.first(where: { $0.path == ["database", "url"] })?.id
        else {
            throw GuideFixtureFailure(
                "no database.url row — guide-14b would picture an inspector with nothing selected")
        }

        func editor(_ name: String, _ model: SecretDocumentViewModel,
                    revealing: Set<String> = []) -> Snapshot {
            Snapshot(name, size: editorSize) {
                SecretEditorView(
                    viewModel: model, fileName: "production.secrets.yaml",
                    unsavedChanges: UnsavedChangesTracker(),
                    initiallyRevealedRowIDs: revealing)
            }
        }

        return [
            editor("guide-10-editor", masked),
            editor("guide-11-editor-revealed", revealedModel, revealing: revealed),
            editor("guide-12-editor-edited", editedModel, revealing: editedRevealed),
            editor("guide-13-editor-needs-key", needsKey),
            Snapshot("guide-14-add-row", size: CGSize(width: 460, height: 330)) {
                Fixtures.addRowSheet(isList: false)
            },
            // The inspector, standing alone. SwiftUI's `.inspector` column
            // does not populate under this renderer — the same gap CLAUDE.md
            // records for `NavigationSplitView`'s `sidebar:` slot — so the
            // editor images above show the table with an empty strip to its
            // right. This is the only way to picture what belongs there
            // (SOPS-39 task 10). Revealed, because a masked value is a
            // picture a reader cannot tell from an empty pane.
            Snapshot("guide-14b-inspector", size: CGSize(width: 320, height: 520)) {
                SecretRowInspector(
                    viewModel: inspected, selectedRowID: inspectedRow,
                    fileName: "config/production.secrets.yaml", access: nil,
                    nameFor: { _ in nil }, ruleLabel: nil,
                    revealed: RevealedRows(
                        revealing: [inspectedRow], in: inspected.rowIdentityGeneration),
                    generation: inspected.rowIdentityGeneration,
                    onToggleReveal: { _ in }, onActivity: {})
            },
        ]
    }

    // MARK: - Step 21: the Access page

    /// The Access page, loaded, against a `.sops.yaml` shaped the way a team
    /// that names its keys writes one: three anchors under a top-level
    /// `keys:` list, a production rule that names all three, and a catch-all
    /// rule that names two.
    ///
    /// ⚠️ The model is loaded **before** the render, not left to the view's
    /// own `.task` — that modifier never fires in this tool's offscreen
    /// render, which is exactly why `docs/GUIDE.md` used to say Part 5 could
    /// have no pictures at all: a single shot of a panel that scans on
    /// appearance catches a spinner and a count of zero. Loading first is the
    /// difference between a picture of the wrong moment and a picture of the
    /// page (SOPS-39 task 10).
    ///
    /// The drift is deliberate: `config/production.secrets.yaml` is encrypted
    /// for two of the three keys its rule declares, so the page shows the
    /// rewrap banner — the one thing about this page a reader most needs to
    /// recognise, because a config edit re-encrypts nothing.
    private static func access() async throws -> [Snapshot] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("guide-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("sops-demo-project", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let studio = try GuideKeyPair.generate()
        let laptop = try GuideKeyPair.generate()
        let deploy = try GuideKeyPair.generate()
        try """
            keys:
              - &studio \(studio.public)
              - &laptop \(laptop.public)
              - &deploy \(deploy.public)

            creation_rules:
              - path_regex: config/production\\.secrets\\.yaml$
                age:
                  - *studio
                  - *laptop
                  - *deploy
              - path_regex: \\.secrets\\.(ya?ml|env)$
                age:
                  - *studio
                  - *laptop

            """.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let config = root.appendingPathComponent("config", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        // Real ciphertext through the in-process bridge, same discipline as
        // every other guide fixture: the page reads each file's own sops
        // metadata to decide whether it has drifted, so a hand-written
        // lookalike would make the image a claim about the fixture.
        try SopsBridge.encrypt(
            productionPlaintext, format: .yaml, recipients: [studio.public, laptop.public]
        ).write(
            to: config.appendingPathComponent("production.secrets.yaml"),
            atomically: true, encoding: .utf8)
        try SopsBridge.encrypt(
            stagingPlaintext, format: .yaml, recipients: [studio.public, laptop.public]
        ).write(
            to: config.appendingPathComponent("staging.secrets.yaml"),
            atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(studio.private)
        let target = config.appendingPathComponent("production.secrets.yaml")
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore, targetFile: target)
        await model.load()

        return [
            Snapshot("guide-19-access", size: CGSize(width: 900, height: 700)) {
                ProjectAccessPage(model: model, selectedFile: target, onFilesApplied: {})
            },
        ]
    }

    // MARK: - Steps 15–18: Settings, Health, keys, About

    private static func settingsAndAbout() async -> [Snapshot] {
        let icon = Catalog.repositoryIcon()
        // With findings, and pre-refreshed. An empty `HealthReport` rendered
        // this pane as a tab bar over a blank white rectangle — a picture of
        // the app's largest settings tab showing none of what it is for.
        let health = await Fixtures.healthViewModel(findings: Fixtures.realisticFindings)
        return [
            Snapshot("guide-15-settings", size: CGSize(width: 720, height: 560)) {
                SettingsPaneView(health: health, keyStore: SessionKeyStore())
            },
            Snapshot("guide-16-key-import", size: CGSize(width: 520, height: 420)) {
                KeyImportView(
                    store: SessionKeyStore(),
                    legacyKeyFiles: {
                        .one("/Users/example/Library/Application Support/sops/age/keys.txt")
                    },
                    defaults: Fixtures.isolatedDefaults(prefix: "guide-key-import"))
            },
            Snapshot("guide-17-updates", size: CGSize(width: 520, height: 240)) {
                UpdateConsentToggle(defaults: Fixtures.isolatedDefaults(prefix: "guide-updates"))
            },
            Snapshot("guide-23-setup-guide", size: CGSize(width: 760, height: 1400)) {
                SetupGuideView()
            },
            Snapshot("guide-18-about", size: CGSize(width: 600, height: 480)) {
                AboutView(
                    facts: AboutFacts(version: "0.1.8", build: "142", commit: "767cf20",
                                      sops: "3.13.3", age: "1.3.1"),
                    icon: icon,
                    checkForUpdates: {})
            },
        ]
    }
}

/// A throwaway age identity, from the real `age-keygen`. Mirrors the private
/// one in `Fixtures.swift` rather than sharing it: that one is `private` to a
/// type whose fixtures are chosen for layout stress, and the two sets should
/// stay free to diverge. Nothing generated here is written into the repository
/// or reused between runs — each call makes a new pair, used once, discarded
/// when the process exits.
private struct GuideKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> GuideKeyPair {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        var priv = "", pub = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw GuideFixtureFailure("age-keygen produced no usable key pair")
        }
        return GuideKeyPair(private: priv, public: pub)
    }
}

/// Thrown rather than tolerated. A guide fixture that quietly does nothing
/// produces a PNG that shows a state the app never reaches, and the reader has
/// no way to tell — the same failure `Catalog.swift`'s `try!` comment is about.
struct GuideFixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
