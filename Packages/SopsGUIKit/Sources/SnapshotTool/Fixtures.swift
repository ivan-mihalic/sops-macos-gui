import Foundation
import SopsEngine
import SopsHealth
import SopsProjects
import SopsUI

// Fixtures, not live data: every model here is built from fixed, fake,
// in-memory (or throwaway-temp-directory) inputs. Nothing reads the
// developer's real projects, `UserDefaults.standard`, or Keychain — a
// snapshot run must be exactly as deterministic on a clean checkout as it is
// on the machine that has been dogfooding this app for months.

/// A `HealthCheck` that returns a fixed list of findings — never touches
/// disk, the network, or a real CLI tool. Every `HealthViewModel` this
/// catalog builds is backed by one of these instead of `HealthReport
/// .standard`, so a snapshot never depends on what tools happen to be
/// installed on the machine running it.
struct FixtureHealthCheck: HealthCheck {
    let id: String
    let category: HealthCategory
    let findings: [HealthFinding]

    func run() async -> [HealthFinding] { findings }
}

@MainActor
enum Fixtures {

    // MARK: - Health view models

    /// Builds a `HealthViewModel` already populated with `findings` and
    /// `hasCompletedRefresh == true`.
    ///
    /// Populating through `await model.refresh()` — a real, public call to
    /// the same method the app's own "Re-run checks" button uses — rather
    /// than reaching for some settable-findings back door: `HealthViewModel`
    /// deliberately exposes no way to set `findings` other than by running a
    /// report, and this fixture should exercise the same path the app does,
    /// not a shortcut that could drift from it.
    ///
    /// This is called *before* the `Snapshot` it feeds into is ever handed
    /// to `SnapshotRenderer` — `HealthPanel`'s and `OnboardingWizard`'s own
    /// `.task { await health.refresh() }` never fires under `ImageRenderer`
    /// (there is no run loop to drive a `.task` modifier's lifecycle), so a
    /// model that relied on that would render as a permanent "checking…"
    /// spinner. Pre-refreshing here, synchronously with the rest of catalog
    /// construction, is what makes the render itself synchronous and
    /// deterministic.
    static func healthViewModel(findings: [HealthFinding]) async -> HealthViewModel {
        let check = FixtureHealthCheck(id: "fixture", category: .tools, findings: findings)
        let model = HealthViewModel(report: HealthReport(checks: [check]))
        await model.refresh()
        return model
    }

    /// An `OnboardingState` on an isolated `UserDefaults` suite, never
    /// `.standard` — this must never read or write the developer's own
    /// "have you completed onboarding" flag.
    static func onboardingState() -> OnboardingState {
        OnboardingState(defaults: isolatedDefaults(prefix: "onboarding"))
    }

    static func isolatedDefaults(prefix: String) -> UserDefaults {
        UserDefaults(suiteName: "snapshot-\(prefix)-\(UUID().uuidString)")!
    }

    // MARK: - Realistic finding set (`HealthPanel`)

    /// One finding per status, spread across every category — plausible
    /// output from a real scan, not an edge case. This is what the panel
    /// looks like on an ordinary day: mostly fine, one thing worth a look,
    /// one thing that needs fixing.
    static var realisticFindings: [HealthFinding] {
        [
            HealthFinding(
                id: "tool.sops", title: "sops", status: .ok,
                detail: "Found sops 3.9.4 at /opt/homebrew/bin/sops."),
            HealthFinding(
                id: "tool.age", title: "age", status: .warning,
                detail: "Found age 1.1.1 at /opt/homebrew/bin/age — older than the 1.2.1 this app embeds.",
                remediation: Remediation(
                    explanation: "Update age with your package manager, or keep relying on the version embedded in this app.",
                    command: "brew upgrade age")),
            HealthFinding(
                id: "engine.sops-freshness", title: "Embedded sops", status: .ok,
                detail: "This app embeds sops 3.9.4, the latest release."),
            HealthFinding(
                id: "engine.age-freshness", title: "Embedded age", status: .unknown(
                    reason: "Update checks are turned off in Settings, so this app has not asked GitHub whether a newer age is available."),
                detail: "This app embeds age 1.2.1."),
            HealthFinding(
                id: "security.os-version", title: "macOS version", status: .ok,
                detail: "Running macOS 26.0, at or above the minimum this app supports."),
            HealthFinding(
                id: "security.legacy-key-file", title: "Legacy key file", status: .problem,
                detail: "~/.config/sops/age/keys.txt exists and is readable by any process running as you.",
                remediation: Remediation(
                    explanation: "Restrict this file to your user only.",
                    command: "chmod 600 ~/.config/sops/age/keys.txt",
                    documentationURL: URL(string: "https://github.com/FiloSottile/age#usage"))),
            HealthFinding(
                id: "security.biometry", title: "Touch ID", status: .skipped(
                    reason: "Keychain key storage arrives in M3."),
                detail: "Not used yet — the session key store is in-memory only for M2."),
        ] + realProjectFindings
    }

    /// The project findings, produced by **running the real check** over a
    /// throwaway project rather than by writing out what its output is
    /// imagined to look like.
    ///
    /// The hand-written pair this replaces said "acme-web: plaintext leak" and
    /// "No plaintext .env files were found outside of .gitignore." Neither
    /// string exists in the app: the real titles and details differ, and — the
    /// reason this matters rather than being a typo — **no hand-written `.ok`
    /// project finding carried the scope-disclosure paragraph**, which every
    /// real one does (`ProjectScopeAccountant.finding`). That paragraph is the
    /// single thing a person reviewing an `.ok` finding is there to check:
    /// whether the app admits what it did not look at. It was invisible in
    /// every snapshot.
    ///
    /// Synchronous because the catalog is built on the main actor and this is a
    /// dev tool; the scan is a few files in a temp directory.
    private static var realProjectFindings: [HealthFinding] {
        guard let root = try? makeSnapshotProject() else { return [] }
        let check = ProjectHealthCheck(source: SnapshotProjects(projects: [
            InspectedProject(name: "acme-web", rootPath: root.path)
        ]))
        return runSynchronously { await check.run() }
    }

    /// A project with something to find: an encrypted file, a `.sops.yaml`, a
    /// plaintext `.env` that is *not* gitignored, and a `node_modules` the scan
    /// never enters — so the scope paragraph has a real exclusion to disclose.
    private static func makeSnapshotProject() throws -> URL {
        // A **fixed** directory name, not a UUID: these PNGs exist to be
        // diffed between commits, and the project root appears verbatim in
        // three of the findings. A fresh UUID every run would make every
        // snapshot differ from the last for no reason, which is the fastest
        // way to teach a reviewer to skip the diff. Removed and rebuilt so a
        // stale run cannot leak into a fresh one.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sops-gui-snapshot-project")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try writeSopsLikeYAML(root, at: "config/production.secrets.yaml")
        try writeSopsLikeYAML(root, at: "node_modules/pkg/fixture.secrets.yaml")
        // A genuinely valid age **public** key — public by definition, and
        // nothing in this repository holds its private half, which was
        // discarded the moment this line was written. It has to be real: an
        // `age1example…` placeholder is not Bech32, so the check reported
        // "could not be parsed: malformed recipient" and the snapshot showed a
        // broken project instead of an ordinary one.
        try "creation_rules:\n  - path_regex: .*\n    age: age1xergf8q8mg5fu5jkrwut46zm9nuurdgufverfft4ed09eudlhu3scah4e3\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        try "API_KEY=EXAMPLE-not-a-real-secret\n"
            .write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        return root
    }

    private struct SnapshotProjects: ProjectSourceProviding {
        let projects: [InspectedProject]
    }

    /// Bridges one `async` call into the catalog's synchronous fixture
    /// properties. A semaphore, and it is safe here for one reason worth
    /// stating: `Catalog.all()` awaits nothing while this runs, and the work
    /// behind it (`ProjectScanner`) runs off the cooperative pool, so nothing
    /// this blocks on needs the thread it is blocking.
    private static func runSynchronously<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        let box = UnsafeResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await work()
            done.signal()
        }
        done.wait()
        return box.value!
    }

    private final class UnsafeResultBox<T>: @unchecked Sendable {
        var value: T?
    }

    // MARK: - Five statuses (`HealthFindingRow`)

    static let findingOK = HealthFinding(
        id: "tool.sops", title: "sops", status: .ok,
        detail: "Found sops 3.9.4 at /opt/homebrew/bin/sops.")

    static let findingWarning = HealthFinding(
        id: "tool.age", title: "age", status: .warning,
        detail: "Found age 1.1.1 at /opt/homebrew/bin/age — older than the 1.2.1 this app embeds.",
        remediation: Remediation(
            explanation: "Update age with your package manager, or keep relying on the version embedded in this app.",
            command: "brew upgrade age"))

    static let findingProblem = HealthFinding(
        id: "security.legacy-key-file", title: "Legacy key file", status: .problem,
        detail: "~/.config/sops/age/keys.txt exists and is readable by any process running as you.",
        remediation: Remediation(
            explanation: "Restrict this file to your user only.",
            command: "chmod 600 ~/.config/sops/age/keys.txt",
            documentationURL: URL(string: "https://github.com/FiloSottile/age#usage")))

    static let findingSkipped = HealthFinding(
        id: "security.biometry", title: "Touch ID", status: .skipped(
            reason: "Keychain key storage arrives in M3."),
        detail: "Not used yet — the session key store is in-memory only for M2.")

    static let findingUnknown = HealthFinding(
        id: "engine.age-freshness", title: "Embedded age", status: .unknown(
            reason: "Update checks are turned off in Settings, so this app has not asked GitHub whether a newer age is available."),
        detail: "This app embeds age 1.2.1.")

    // MARK: - The long, multi-line finding

    /// Modeled on `ProjectHealthCheck.recipientFinding(for:...)`'s real
    /// shape — one line per mismatched file, joined with `"\n"`, sometimes
    /// followed by a second, blank-line-separated block of things the check
    /// could not verify. A real project with a dozen encrypted files and a
    /// couple of unreadable ones produces exactly this: a `detail` string a
    /// dozen lines long with embedded newlines, in a view
    /// (`HealthFindingRow`) that has no `.lineLimit` — hosted, in the
    /// wizard, inside a fixed 640×520 sheet. This is the one snapshot this
    /// tool exists foremost to take: nothing before it could show whether
    /// that combination clips or overflows.
    ///
    /// The age recipient strings below are obviously fake — repeating
    /// placeholder characters, not output from `age-keygen` — consistent
    /// with "no real secrets in fixtures" even though a public key is not
    /// itself secret material.
    static var longRecipientsFinding: HealthFinding {
        let mismatches = [
            "config/production.secrets.yaml does not list age1qexampleexampleexampleexampleexampleexampleexampleexample7k2h among its recipients, but .sops.yaml declares it for this file.",
            "config/staging.secrets.yaml does not list age1zexampleexampleexampleexampleexampleexampleexampleexamplerl4m among its recipients, but .sops.yaml declares it for this file.",
            "config/staging.secrets.yaml does not list age17example2xampleexampleexampleexampleexampleexampleexamplefzhk among its recipients, but .sops.yaml declares it for this file.",
            "secrets/ci-deploy.yaml does not list age1nexampleexampleexampleexampleexampleexampleexampleexample0hja among its recipients, but .sops.yaml declares it for this file.",
            "secrets/ci-deploy.yaml does not list age1pexampleexampleexampleexampleexampleexampleexampleexample0hjb among its recipients, but .sops.yaml declares it for this file.",
            "infra/terraform/backend.secrets.yaml does not list age1xexampleexampleexampleexampleexampleexampleexampleexample0hjc among its recipients, but .sops.yaml declares it for this file.",
            "mobile/fastlane/Appfile.enc.yaml does not list age1mexampleexampleexampleexampleexampleexampleexampleexample0hjd among its recipients, but .sops.yaml declares it for this file.",
        ]
        let unverifiable = [
            "This project has more files under it than this app's scan budget of 4000, so the walk stopped before it reached every file. Files beyond that point were never looked at, so this app cannot vouch for this project's recipients as a whole.",
            "config/legacy-vault.yaml is sops-encrypted in a format this app does not read yet — this build handles YAML only — so its recipient list was not checked.",
            "scripts/rotate-secrets.env is encrypted, but no creation rule in .sops.yaml governs it, so there is no declared key list to compare its recipients against.",
            "vendor/partner-integration/keys.yaml is protected by KMS, which the rule governing it also declares. This app reads age recipients only, so its key list was not checked.",
        ]
        let detail = mismatches.joined(separator: "\n")
            + "\n\nThis app also could not fully check:\n" + unverifiable.joined(separator: "\n")

        return HealthFinding(
            id: "project.0.stale-recipients", title: "acme-web: recipients", status: .problem,
            detail: detail,
            remediation: Remediation(
                explanation: "Run updatekeys to re-wrap these files for the recipients .sops.yaml declares.",
                command: "sops updatekeys config/production.secrets.yaml",
                documentationURL: URL(string: "https://getsops.io/docs/#adding-and-removing-keys")))
    }

    // MARK: - Project sidebar, with a worktree group

    /// A real git repository with one real linked worktree, built with the
    /// real `git` binary at a throwaway temporary path — mirrors
    /// `ProjectSidebarModelTests.makeRepoWithWorktree()`. A hand-authored
    /// `.git` file would prove nothing about grouping, only about parsing:
    /// `WorktreeResolver` reads the exact admin-directory shape
    /// (`HEAD`/`commondir`) git itself writes, so only a real worktree
    /// produces a faithful snapshot of the grouped sidebar.
    ///
    /// Also adds one unrelated, non-git project alongside the repo pair, so
    /// the snapshot shows both a grouped-with-header case and an ungrouped
    /// one in the same frame — what the sidebar actually looks like once a
    /// developer has more than one thing open.
    static func worktreeProjectSidebarModel() throws -> ProjectSidebarModel {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-worktree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let main = base.appendingPathComponent("acme-web")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try git(["init", "-q"], in: main)
        try "1".write(to: main.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: main)
        try git(["-c", "user.email=snapshot@example.com", "-c", "user.name=Snapshot",
                  "commit", "-qm", "init"], in: main)

        let worktree = base.appendingPathComponent("acme-web-hotfix")
        try git(["worktree", "add", "-q", worktree.path, "-b", "hotfix/rotate-keys"], in: main)

        let unrelated = base.appendingPathComponent("internal-tools")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        let storeURL = base.appendingPathComponent("projects.json")
        let store = ProjectStore(fileURL: storeURL)
        _ = try store.add(path: main.path)
        _ = try store.add(path: worktree.path)
        _ = try store.add(path: unrelated.path)

        return ProjectSidebarModel(store: store)
    }

    /// Enough projects that the sidebar's `List` genuinely runs past its own
    /// frame — the overflow case `scrollOverflowFade()` exists to signal, and
    /// the one `project-sidebar-worktree-group` (three projects in a 520pt
    /// column) cannot show because it does not overflow.
    ///
    /// Plain directories, not git repositories: every project then forms its
    /// own single-member group and renders without a header, which is the
    /// densest, least distracting way to fill the column. Twenty is well past
    /// what fits, so the fade cannot pass by being borderline.
    ///
    /// The pair matters as much as either half. A fade drawn over a list with
    /// nothing below it is its own small lie, so both are rendered and both
    /// are looked at.
    static func manyProjectsSidebarModel() throws -> ProjectSidebarModel {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-many-projects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let storeURL = base.appendingPathComponent("projects.json")
        let store = ProjectStore(fileURL: storeURL)
        let names = [
            "acme-web", "acme-api", "acme-worker", "billing-service", "checkout-service",
            "identity-service", "inventory-service", "notifications", "search-service",
            "internal-tools", "infra-terraform", "infra-ansible", "mobile-ios",
            "mobile-android", "design-system", "docs-site", "data-pipeline",
            "analytics-dbt", "partner-integrations", "ops-runbooks",
        ]
        for name in names {
            let dir = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try store.add(path: dir.path)
        }
        return ProjectSidebarModel(store: store)
    }

    /// Two ordinary projects — comfortably fewer than fit the same 520pt
    /// column. The negative half of the pair above: nothing is below the
    /// fold, so nothing may be faded.
    static func fewProjectsSidebarModel() throws -> ProjectSidebarModel {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-few-projects-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let storeURL = base.appendingPathComponent("projects.json")
        let store = ProjectStore(fileURL: storeURL)
        for name in ["acme-web", "internal-tools"] {
            let dir = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try store.add(path: dir.path)
        }
        return ProjectSidebarModel(store: store)
    }

    /// A small, plain (non-git) set of projects for the full-`AppShell`
    /// snapshot — populated so the sidebar isn't empty, but with nothing
    /// selected, so the detail pane renders its deterministic "no
    /// selection" placeholders rather than racing a real, async
    /// `FileListModel` directory scan.
    static func appShellProjectSidebarModel() throws -> ProjectSidebarModel {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-appshell-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let storeURL = base.appendingPathComponent("projects.json")
        let store = ProjectStore(fileURL: storeURL)
        for name in ["acme-web", "internal-tools", "infra-terraform"] {
            let dir = base.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            _ = try store.add(path: dir.path)
        }
        return ProjectSidebarModel(store: store)
    }

    // MARK: - The editor (`SecretEditorView`)

    /// A throwaway age identity from the real `age-keygen` binary. Mirrors
    /// `SopsEngineTests/TestSupport.swift`'s `AgeKeyPair`, duplicated rather
    /// than shared — that type lives in a test target this executable
    /// target has no dependency path to. Nothing generated here is ever
    /// written into the repository or reused between snapshot runs.
    private struct SnapshotAgeKeyPair {
        let `private`: String
        let `public`: String

        static func generate() throws -> SnapshotAgeKeyPair {
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
            // `LineEndings.lines(of:)`, not `split(separator: "\n")` — see
            // that type for why the `Character` `"\n"` is the wrong thing to
            // split on. `age-keygen` writes LF, so this is consistency with
            // the rest of the package rather than a bug being fixed; the
            // `Sources/`-wide guard treats every occurrence the same way on
            // purpose, because "this particular producer writes LF" is what
            // was believed at three of the four real sites too.
            for line in LineEndings.lines(of: output) {
                if line.hasPrefix("AGE-SECRET-KEY-") {
                    priv = String(line)
                } else if line.hasPrefix("# public key: ") {
                    pub = String(line.dropFirst("# public key: ".count))
                }
            }
            guard !priv.isEmpty, !pub.isEmpty else {
                throw SnapshotFixtureError("age-keygen produced no usable key pair")
            }
            return SnapshotAgeKeyPair(private: priv, public: pub)
        }
    }

    private struct SnapshotFixtureError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Every `SecretRow.Kind`, a merge key (`<<: *base` — Task 7's report:
    /// "merge keys surface as a row with a literal `<<` path segment", the
    /// exact shape `SecretRowViewLogic.isMergeKeyRow` and
    /// `SecretEditorView`'s badge look for), and enough rows that the list
    /// genuinely overflows the editor's frame — the same overflow shape
    /// `scrollOverflowFade()` exists to signal.
    private static let editorRichDocumentYAML = """
        base: &base
            region: us-east-1
            timeout_seconds: 30
        service:
            <<: *base
            name: checkout-api
        db:
            host: db.internal.example
            port: 5432
            password: correct-horse-battery-staple-EXAMPLE
            enabled: true
            ratio: 0.75
            nothing: null
            created: 2024-01-02T03:04:05Z
        api_key: sk_live_EXAMPLEEXAMPLEEXAMPLEEXAMPLE0001
        webhook_signing_secret: whsec_EXAMPLE_a_deliberately_long_value_meant_to_show_how_a_single_field_behaves_when_it_runs_past_a_comfortable_field_width_EXAMPLE
        servers:
            - name: primary
              ip: 10.0.0.1
            - name: secondary
              ip: 10.0.0.2
        feature_flags:
            - beta_checkout
            - dark_mode
            - new_pricing
        retry_policy:
            max_attempts: 5
            backoff: exponential
        empty_map: {}
        empty_list: []
        """

    /// A document this app can open and decrypt: real sops ciphertext (via
    /// the in-process bridge, `SopsBridge.encryptYAML` — the same call
    /// `CompatibilityTests` exercises), a real age identity imported into a
    /// real `SessionKeyStore`, loaded through the same `SecretDocumentViewModel
    /// .load()` the app calls. Nothing here is faked or hand-assembled —
    /// this is the one state that must prove the whole path actually works,
    /// not just that the view can render a shape of data.
    static func editorLoadedViewModel() async throws -> SecretDocumentViewModel {
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(editorRichDocumentYAML, format: .yaml, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-loaded.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// `sops -e` on `{}` — a legitimate, ordinary empty document (`Task 9`'s
    /// brief is explicit this must not read like an error). Real ciphertext,
    /// real key, same load path as above.
    static func editorEmptyDocumentViewModel() async throws -> SecretDocumentViewModel {
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt("{}\n", format: .yaml, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-empty.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// No identity configured at all — `load()` reaches `.needsKey` before
    /// ever attempting a decrypt. `readFile`'s return value is irrelevant
    /// here (the key check happens before the content is used for
    /// anything), so it is an obviously-inert placeholder, not real
    /// ciphertext.
    static func editorNeedsKeyViewModel() async -> SecretDocumentViewModel {
        let store = SessionKeyStore()
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-needs-key.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in "irrelevant — never reached with no key configured" })
        await model.load()
        return model
    }

    /// The editor mid-edit: one row added in this session (the "New" badge —
    /// see `SecretEditorView`'s doc comment for why it is not a padlock), one
    /// baseline row removed, and one value changed. This is the state Task 8b
    /// added, and the only one in which the toolbar's `-` is enabled.
    ///
    /// Returned with the id of the row to start selected, because the toolbar
    /// enables `-` on a selection and this tool cannot click one.
    static func editorPendingChangesViewModel() async throws -> (SecretDocumentViewModel, String?) {
        // Deliberately a short document, not `editorRichDocumentYAML`: a
        // `List` is a `ScrollView`, and this tool only ever sees its
        // unscrolled top (CLAUDE.md, "What it still cannot see"). A snapshot
        // whose whole subject sat below the fold would review nothing.
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            """
            db:
                host: db.internal.example
                password: correct-horse-battery-staple-EXAMPLE
            feature_flags:
                - beta_checkout
                - dark_mode
            """, format: .yaml, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-pending.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()

        // `if let` here, and it was three of them, is the same defect as the
        // `try?` in `Catalog.swift`: a fixture that quietly does nothing. If
        // the row is not found — a changed path, a load that failed, an editor
        // that renamed a field — this snapshot renders a document with *no*
        // pending changes under the name "pending changes", and the reviewer
        // approves a screen the app never produces. Not finding the row is a
        // broken fixture, so it is thrown, loudly, and the snapshot run stops.
        let password = try requireRow(model, ["db", "password"])
        model.update(rowID: password.id, to: "rotated-EXAMPLE-value")

        let flag = try requireRow(model, ["feature_flags", "1"])
        model.removeRow(id: flag.id)

        let host = try requireRow(model, ["db", "host"])
        let destination = model.addDestination(forSelectedRowID: host.id)
        guard case .added(let selected) = model.addRow(
            in: destination, key: "replica_host", kind: .string, value: "db-replica.internal.example")
        else {
            throw FixtureFailure(
                "adding replica_host was refused, so this snapshot would show no new row")
        }
        return (model, selected)
    }

    /// One row revealed, the rest masked — the state a reveal actually puts
    /// the editor in, and the one nothing had ever looked at. Every other
    /// editor snapshot shows an all-masked list, so the eye/eye-slash swap,
    /// the plaintext field beside eight bullets, and the fact that only the
    /// clicked row opens up were all unreviewed.
    ///
    /// Returned with the ids to reveal, because reveal is a click and this
    /// tool cannot click — the same reason `editorPendingChangesViewModel`
    /// returns a selection.
    ///
    /// Short document, deliberately: a `List` is a `ScrollView` and this tool
    /// only sees its unscrolled top (CLAUDE.md), so a revealed row below the
    /// fold would review nothing. The values are obviously fake, per the
    /// standing rule — a snapshot is a PNG of a plaintext secret, and this is
    /// the one fixture where that is the entire subject.
    static func editorRevealedRowViewModel() async throws -> (SecretDocumentViewModel, Set<String>) {
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            """
            db:
                host: db.internal.example
                password: correct-horse-battery-staple-EXAMPLE
            api_key: sk_live_EXAMPLEEXAMPLEEXAMPLEEXAMPLE0001
            """, format: .yaml, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-revealed.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()

        let revealed = model.rows
            .filter { $0.path == ["db", "password"] }
            .map(\.id)
        return (model, Set(revealed))
    }

    /// The `+` sheet, in both shapes it has: a named key for a map, and an
    /// appended entry for a list. YAML's full kind picker — see
    /// `addRowSheetDotenv()` for the restricted one a dotenv document shows.
    static func addRowSheet(isList: Bool) -> EditorAddRowSheet {
        EditorAddRowSheet(
            destination: SecretDocumentViewModel.AddDestination(
                document: 0, parent: isList ? ["feature_flags"] : ["db"], isList: isList),
            refusal: { $0 == "host" ? .duplicateKey : nil },
            allowedKinds: [.string, .int, .float, .bool, .null, .timestamp],
            onCancel: {},
            onAdd: { _, _, _ in })
    }

    /// The `+` sheet as a dotenv document shows it (Task 6, SOPS-38): the
    /// type picker offers only `.string` — `SecretDocumentViewModel
    /// .allowedAddKinds` for a document whose format cannot hold anything
    /// else — so this is what proves the restriction actually reaches the
    /// screen, not just the model.
    static func addRowSheetDotenv() -> EditorAddRowSheet {
        EditorAddRowSheet(
            destination: SecretDocumentViewModel.AddDestination(document: 0, parent: [], isList: false),
            refusal: { $0 == "DB_HOST" ? .duplicateKey : nil },
            allowedKinds: [.string],
            onCancel: {},
            onAdd: { _, _, _ in })
    }

    /// A genuinely damaged file — not a wrong key at all.
    ///
    /// This used to encrypt for one identity and import a *different* real
    /// one, the "wrong key" shape — until SOPS-38 phase F3 gave that its own
    /// `LoadState.readOnlyCiphertext` (see `editorReadOnlyCiphertextViewModel`
    /// below), which made that scenario the wrong fixture for this snapshot:
    /// unchanged, it silently stopped showing `.failed` at all. The correct
    /// key is imported here, so `SecretDocumentViewModel.load()` can only
    /// reach `.failed` from the corruption itself, never from
    /// `.noMatchingIdentity` — the same retyped-`ENC[...,type:...]` tag
    /// technique `SecretDocumentViewModelTests
    /// .genuinelyDamagedFileStillReportsFailed` proves reliably fails
    /// decryption for a reason that is not a missing identity.
    static func editorLoadFailedViewModel() async throws -> SecretDocumentViewModel {
        let owner = try SnapshotAgeKeyPair.generate()
        let rawEncrypted = try SopsBridge.encrypt(
            "database:\n    password: hunter2-EXAMPLE\n", format: .yaml, recipients: [owner.public])
        // `LineEndings.lines(of:)`, not `.components(separatedBy: "\n")` — see
        // that type's own doc comment for why a `"\n"` literal is blind to a
        // CRLF file. Rejoining with `"\n"` is fine (writing a line ending,
        // not reading one), matching `SnapshotAgeKeyPair.generate()`'s own
        // idiom just above.
        var lines = LineEndings.lines(of: rawEncrypted)
        guard let index = lines.firstIndex(where: { $0.hasPrefix("    password: ENC[") }) else {
            throw SnapshotFixtureError("fixture has no encrypted password to corrupt")
        }
        lines[index] = Substring(lines[index].replacingOccurrences(of: ",type:str]", with: ",type:int]"))
        let encrypted = lines.joined(separator: "\n")

        let store = SessionKeyStore()
        try store.importKey(owner.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-load-failed.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// Real ciphertext, but the session holds a *different* real identity —
    /// the same "wrong key" shape `SopsDocumentTests` covers at the bridge
    /// layer, one level up. SOPS-38 phase F3: this is what
    /// `CiphertextReadOnlyView` shows for it — the raw on-disk bytes and the
    /// file's own recipient (`owner.public`, unregistered, so it renders as
    /// its raw key rather than a name).
    static func editorReadOnlyCiphertextViewModel() async throws -> SecretDocumentViewModel {
        let owner = try SnapshotAgeKeyPair.generate()
        let intruder = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            "database:\n    password: hunter2-EXAMPLE\n", format: .yaml, recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(intruder.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-wrong-key.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// A dotenv document (Task 6, SOPS-38): real ciphertext via the
    /// in-process bridge's dotenv path (`SopsBridge.encrypt(_:format:
    /// .dotenv:...)`, Task 4), loaded through `SecretDocumentViewModel
    /// (format: .dotenv)` exactly the way `AppShell.swift`'s
    /// `ProjectWorkspaceView.activateFile` does once `FileListModel.files`
    /// carries a dotenv `ListedFile`. What this snapshot exists to show:
    /// the editor renders a flat document the same as any other, and the
    /// toolbar's `+` (see `Catalog.swift`'s `editor-add-sheet-dotenv`)
    /// offers only a string.
    static func editorDotenvViewModel() async throws -> SecretDocumentViewModel {
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            """
            DB_HOST=db.internal.example
            DB_PASSWORD=correct-horse-battery-staple-EXAMPLE
            API_KEY=sk_live_EXAMPLEEXAMPLEEXAMPLEEXAMPLE0001
            """, format: .dotenv, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-dotenv.env"),
            format: .dotenv,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// A JSON document (SOPS-38 phase F2 task 4): real ciphertext via the
    /// in-process bridge's json path, loaded through
    /// `SecretDocumentViewModel(format: .json)`. What this snapshot exists
    /// to show: JSON renders exactly like a YAML document — nested map, a
    /// list — because its capability row in `SecretDocumentViewModel
    /// .addCapabilities(for:)` is identical to YAML's.
    static func editorJSONViewModel() async throws -> SecretDocumentViewModel {
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            """
            {"database": {"host": "db.internal.example", "port": 5432},
             "api_key": "sk_live_EXAMPLEEXAMPLEEXAMPLEEXAMPLE0001",
             "allowed_ips": ["10.0.0.1", "10.0.0.2"]}
            """, format: .json, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-json.json"),
            format: .json,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// An INI document (SOPS-38 phase F2 task 4): real ciphertext via the
    /// in-process bridge's ini path, loaded through
    /// `SecretDocumentViewModel(format: .ini)`. Two sections, the shape
    /// `addRowSheetINI()` below adds a key into.
    static func editorINIViewModel() async throws -> SecretDocumentViewModel {
        let key = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(
            """
            [database]
            host = db.internal.example
            port = 5432

            [api]
            key = sk_live_EXAMPLEEXAMPLEEXAMPLEEXAMPLE0001
            """, format: .ini, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-ini.ini"),
            format: .ini,
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    /// The `+` sheet at an INI document's own root — the destination
    /// `SecretDocumentViewModel.AddCapabilities` refuses for every format
    /// except this one, because sops's INI store requires every root entry
    /// to be a section and this app's Add API can never create one (see that
    /// type's doc comment). What this snapshot exists to show is the part
    /// `editor-ini` cannot: the message the sheet gives instead of a dead
    /// end (`editor.add.unsupported-for-format`), shown immediately rather
    /// than only after the user types a name.
    static func addRowSheetINIRootRefused() -> EditorAddRowSheet {
        EditorAddRowSheet(
            destination: SecretDocumentViewModel.AddDestination(document: 0, parent: [], isList: false),
            refusal: { _ in .unsupportedForFormat },
            allowedKinds: [.string],
            onCancel: {},
            onAdd: { _, _, _ in })
    }

    // MARK: - The file list (`FileListView`)

    /// Hand-written text carrying the structure `ProjectScanner` requires of a
    /// sops-written YAML file (`sops:` as the last top-level key, with `mac`
    /// and `version` under it — see `SopsMetadataShape`) — mirrors
    /// `FileListModelTests.writeSopsLike`. What is under test in the file-list
    /// snapshots is layout, sorting and truncation/other-format disclosure,
    /// not sops's own file format, which the bridge's and `SopsEngineTests`'
    /// real-binary fixtures already hold to the real standard. It still has to
    /// be a shape sops could have produced: since Task 14 the scanner requires
    /// structure rather than a bare marker, so a block without `version:`
    /// renders an empty file list instead of the populated one this fixture
    /// exists to show.
    /// A project tree store and sidebar model over one project holding two
    /// encrypted files, one of which its `.sops.yaml` rule does **not**
    /// declare the recipient for — so the sidebar draws one in-sync dot and
    /// one drift dot, which is the pair the status column exists for.
    /// Snapshotting only in-sync rows would show a column that cannot be
    /// told apart from no column at all.
    static func projectTreeFixture() async throws -> (ProjectSidebarModel, ProjectTreeStore) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tree-" + UUID().uuidString)
        let root = base.appendingPathComponent("acme-web")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        try """
            creation_rules:
              - path_regex: .*
                age: \(ruleRecipient)

            """.write(to: root.appendingPathComponent(".sops.yaml"),
                      atomically: true, encoding: .utf8)
        try writeSopsLikeYAML(root, at: "config/production.secrets.yaml", recipient: ruleRecipient)
        try writeSopsLikeYAML(root, at: "config/staging.secrets.yaml", recipient: strangerRecipient)

        let store = ProjectStore(fileURL: base.appendingPathComponent("projects.json"))
        let project = try store.add(path: root.path)
        let projects = ProjectSidebarModel(store: store)
        projects.selection = project.id

        let trees = ProjectTreeStore(keyStore: SessionKeyStore())
        // Pre-refreshed for the same reason every other fixture here is: a
        // `.task` never fires in this tool's offscreen render, so a store
        // left to refresh itself would draw a project with no children.
        await trees.refresh(project)
        return (projects, trees)
    }

    /// The recipient `.sops.yaml` declares in `projectTreeFixture`, and the
    /// one a drifted file is wrapped for instead. Both are shape-valid and
    /// inert — no key material, only the public half of nothing.
    private static let ruleRecipient =
        "age1exampleexampleexampleexampleexampleexampleexampleexamplex"
    private static let strangerRecipient =
        "age1strangerstrangerstrangerstrangerstrangerstrangerstrangerx"

    private static func writeSopsLikeYAML(
        _ root: URL, at relativePath: String,
        recipient: String = "age1exampleexampleexampleexampleexampleexampleexampleexamplex"
    ) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            sops:
                age:
                    - recipient: \(recipient)
                mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
                version: 3.13.3
            """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// A dotenv-shaped sops file — `ProjectScanner.looksSopsEncryptedInAnotherFormat`
    /// keys on the `sops_mac=`/`sops_version=` markers sops's own dotenv
    /// store writes. This app is YAML-only for v1 (`Package.swift`,
    /// `CLAUDE.md`), so this must surface as `otherFormatCount`, never as
    /// an openable row in `files`.
    private static func writeSopsLikeDotenv(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            API_KEY=ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            sops_mac=ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            sops_version=3.9.4
            """.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Enough encrypted files, spread across a few directories, that the
    /// list genuinely overflows the panel's frame — the same overflow shape
    /// `scrollOverflowFade()` exists to signal — plus one dotenv-format sops
    /// file so `otherFormatCount`'s footnote has something real to count.
    /// Pre-`refresh()`ed before being handed to a `Snapshot`, the same
    /// reason `Fixtures.healthViewModel(findings:)` pre-refreshes: nothing
    /// in this tool's offscreen render drives a `.task` reliably enough to
    /// depend on it alone (see `AppShellProjectSidebarModel`'s doc comment).
    static func fileListModelWithFiles() async throws -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let services = ["billing", "checkout", "identity", "inventory", "notifications", "search"]
        let environments = ["production", "staging", "development"]
        for service in services {
            for environment in environments {
                try writeSopsLikeYAML(root, at: "services/\(service)/\(environment).secrets.yaml")
            }
        }
        try writeSopsLikeYAML(root, at: ".sops-managed/root.secrets.yaml")
        try writeSopsLikeDotenv(root, at: "legacy/.env.production")

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        return model
    }

    /// A project directory that exists but holds nothing this app
    /// recognises as sops-encrypted — the ordinary "nothing here yet"
    /// state, not `rootMissing`.
    static func fileListModelEmpty() async throws -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-empty-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# nothing encrypted here yet\n".write(
            to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        return model
    }

    /// A walk that could not cover the whole tree: one subdirectory this
    /// process cannot list, plus a `node_modules` the scan never enters by
    /// name. Renders the warning banner *and* the quiet exclusion footnote,
    /// which is the combination nothing had ever looked at — the banner used
    /// to fire only on the file-budget cap, and the footnote used to be
    /// nested inside the banner, so on any ordinary project neither appeared.
    ///
    /// Permissions are restored as soon as the scan is done: this tool must
    /// not leave an unreadable directory behind in `/tmp`.
    static func fileListModelIncompleteScan() async throws -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-partial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try writeSopsLikeYAML(root, at: "services/billing/production.secrets.yaml")
        try writeSopsLikeYAML(root, at: "services/checkout/production.secrets.yaml")
        try writeSopsLikeYAML(root, at: "node_modules/some-package/fixture.secrets.yaml")

        let locked = root.appendingPathComponent("vault")
        try writeSopsLikeYAML(root, at: "vault/root.secrets.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        guard model.incompleteScanReason != nil else {
            throw FixtureFailure(
                "the locked directory was readable after all, so this snapshot would show "
                    + "an ordinary complete scan under the name \"incomplete\"")
        }
        return model
    }

    /// The same incomplete walk, but every encrypted file in the project sits
    /// behind the directory it could not read. The placeholder must narrow its
    /// claim from "no encrypted files in this project" to "none in the part
    /// that could be scanned" — the confident version is a statement about
    /// files nobody looked at.
    static func fileListModelEmptyPartialScan() async throws -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-empty-partial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let locked = root.appendingPathComponent("vault")
        try writeSopsLikeYAML(root, at: "vault/root.secrets.yaml")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let model = FileListModel(projectRoot: root)
        await model.refresh()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)

        guard model.incompleteScanReason != nil, model.files.isEmpty else {
            throw FixtureFailure(
                "this fixture was meant to find nothing behind an unreadable directory; "
                    + "it found \(model.files.count) file(s)")
        }
        return model
    }

    /// Ticket #25 claim 2: a project holding a symlink to a directory
    /// elsewhere on disk — a `secrets -> ../shared-secrets` layout, the
    /// example the ticket itself names — so the "Add as Project" footnote
    /// has something real to render. The target directory is deliberately
    /// left outside `root`: were it inside, the walk would reach its files
    /// through the ordinary tree traversal too, which would not prove the
    /// footnote is what makes this content reachable at all.
    static func fileListModelWithUnfollowedSymlink() async throws -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-symlink-" + UUID().uuidString)
        let shared = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-symlink-target-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try writeSopsLikeYAML(root, at: "services/billing/production.secrets.yaml")
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("shared-secrets"), withDestinationURL: shared)

        let model = FileListModel(projectRoot: root)
        await model.refresh()

        guard !model.unfollowedDirectorySymlinks.isEmpty else {
            throw FixtureFailure("the symlink was followed or not recorded — this snapshot would "
                + "render the ordinary file-list state under a name claiming otherwise")
        }
        return model
    }

    /// A project whose directory no longer exists — deleted or unmounted
    /// after being added. `rootMissing`, never a silent "found nothing".
    static func fileListModelMissingRoot() async -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-missing-" + UUID().uuidString)
        let model = FileListModel(projectRoot: root)
        await model.refresh()
        return model
    }

    // MARK: - ProjectStartHereView
    //
    // In-memory `CreationPlan` values, not a real project root or `.sops.yaml`
    // — unlike every `fileListModel*` fixture above, `ProjectStartHereView`
    // never resolves a plan itself (see that type's own doc comment, "What
    // this view never does"), it only renders one a caller already resolved.
    // Fabricating one directly is the same discipline
    // `NewSecretFileSheetTests.InfoLineTextTests` already holds
    // `NewSecretFileSheet.infoLineText` to, for the identical reason: this is
    // a pure rendering decision, not something a real bridge call needs to
    // prove.

    static let startHereNoConfig: CreationPlan = .noConfig

    static let startHereNoRuleMatched: CreationPlan = .noRuleMatched

    /// A bare throwaway project root — no registry content, because
    /// `.noConfig`/`.noRuleMatched` have no recipients to label either way.
    /// `RecipientRegistry.load(in:)` degrades to an empty registry for a
    /// directory whose `.sops-gui/recipients.json` does not exist, the same
    /// contract every other caller of that function keeps.
    static func startHereProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-start-here-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// A `.governedByRule` plan paired with the one project root whose
    /// registry actually labels one of its recipients "Alice" — the pairing
    /// matters, since `ProjectStartHereView` only shows a label for a
    /// recipient the registry it reads actually names. Added when this
    /// task's review found the view had no way to show a nickname at all
    /// ("Decision on your disclosed limitation"); the snapshot this builds
    /// for proves the fix reaches the rendered screen: the first recipient
    /// should read "Alice", the second — deliberately left unlabeled —
    /// should still read as a shortened key, never an invented name.
    ///
    /// The labeled recipient is real, from `age-keygen`
    /// (`SnapshotAgeKeyPair.generate()`) — `RecipientRegistry.save`
    /// validates the bech32 shape before writing, so a hand-typed
    /// placeholder like `"age1qexample…"` is refused with
    /// `.invalidAgeRecipient` before a registry ever reaches disk. The
    /// second, unlabeled recipient has no such requirement —
    /// `CreationPlan.governedByRule` carries raw `[String]` and validates
    /// nothing — so it stays an obvious placeholder.
    /// - Parameter encryptedRegex: passed straight through into the built
    ///   plan. Non-empty by a caller who wants
    ///   `start-here-governed-by-rule-with-scoping` — the review's own
    ///   finding that the `encrypted_regex` disclosure (Important 1's fix)
    ///   was the one new output in that round with no snapshot and no
    ///   `.fixedSize` on the `Text` rendering it.
    static func startHereGovernedFixture(
        encryptedRegex: String = ""
    ) throws -> (plan: CreationPlan, projectRoot: URL) {
        let labeled = try SnapshotAgeKeyPair.generate()
        let unlabeled = "age1qunlabeledunlabeledunlabeledunlabeledunlabeledunlabeledunla"
        let root = try startHereProjectRoot()
        try RecipientRegistry.save(
            [RecipientRecord(label: "Alice", kind: .person, ageRecipient: labeled.public)], in: root)
        return (
            .governedByRule(recipients: [labeled.public, unlabeled], encryptedRegex: encryptedRegex), root
        )
    }

    // MARK: - DotEnvPreviewTable

    /// A short `.env` import preview covering all five `DotEnvSuspicion.Kind`
    /// cases plus one skipped line — short on purpose, per this file's own
    /// house rule (`snapshots.sh`'s `List` only shows its unscrolled top, so
    /// a long fixture would make the snapshot legible only for whatever
    /// happens to fit above the fold). Values are obviously-fake, `-EXAMPLE`
    /// suffixed where a real secret's shape matters, matching every other
    /// fixture in this file — never a real key, never `age-keygen` output.
    static func dotEnvPreviewFixture() -> ParsedDotEnv {
        ParsedDotEnv(
            entries: [
                DotEnvEntry(key: "DB_HOST", value: "db.internal.example", line: 1),
                DotEnvEntry(
                    key: "DB_PASSWORD", value: "correct-horse-battery-staple-EXAMPLE", line: 2),
                DotEnvEntry(key: "API_KEY", value: "'sk_live_EXAMPLE_unterminated", line: 3),
                DotEnvEntry(key: "9BAD_KEY", value: "still-imported-EXAMPLE", line: 4),
                DotEnvEntry(key: "TEMPLATE_URL", value: "${HOME}/app-EXAMPLE", line: 5),
                DotEnvEntry(key: "EMPTY_SECRET", value: "", line: 6),
                DotEnvEntry(key: "SHARED_TOKEN", value: "final-value-EXAMPLE", line: 8),
            ],
            skipped: [
                DotEnvSkippedLine(line: 9, text: "not a valid config line at all"),
            ],
            suspicions: [
                DotEnvSuspicion(key: "API_KEY", kind: .strayOpeningQuote),
                DotEnvSuspicion(key: "9BAD_KEY", kind: .notAPosixName),
                DotEnvSuspicion(key: "TEMPLATE_URL", kind: .looksInterpolated),
                DotEnvSuspicion(key: "EMPTY_SECRET", kind: .emptyValue),
                DotEnvSuspicion(key: "SHARED_TOKEN", kind: .duplicateKey(supersededLines: [7])),
            ])
    }

    // MARK: - NewSecretFileSheet

    /// A ready-to-create wizard: a real temp project whose `.sops.yaml`
    /// names this session's own key, and a name already resolved against
    /// it. Real `age-keygen` and a real project root, matching every other
    /// fixture here and `NewSecretFileModelTests`'s own shape — never a
    /// mock model.
    static func newSecretFileModelReady() async throws -> NewSecretFileModel {
        let key = try SnapshotAgeKeyPair.generate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-new-file-ready-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(key.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: store)
        model.relativeName = "secrets/production.secrets.yaml"
        await model.resolvePlan()
        return model
    }

    /// A plan whose recipients exclude this session's key, after `create()`
    /// has already discovered that once — `readiness == .needsAcknowledgement`.
    /// Same shape as `NewSecretFileModelTests
    /// .selfReadabilityIsDiscoveredNotPredicted`'s first half.
    static func newSecretFileModelNeedsAcknowledgement() async throws -> NewSecretFileModel {
        let owner = try SnapshotAgeKeyPair.generate()
        let stranger = try SnapshotAgeKeyPair.generate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-new-file-ack-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(stranger.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let store = SessionKeyStore()
        try store.importKey(owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: store)
        model.relativeName = "secrets/production.secrets.yaml"
        await model.resolvePlan()
        _ = await model.create()
        return model
    }

    /// No `.sops.yaml` at all — `readiness == .blocked`, until Task 5 adds
    /// the manual recipient picker.
    static func newSecretFileModelBlocked() async throws -> NewSecretFileModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-new-file-blocked-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let model = NewSecretFileModel(projectRoot: root, keyStore: SessionKeyStore())
        model.relativeName = "secrets/production.secrets.yaml"
        await model.resolvePlan()
        return model
    }

    private static func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }
}

/// A fixture could not be built as written. Thrown rather than absorbed: a
/// snapshot that silently renders a different state than its name claims is
/// worse than no snapshot, because someone reviews it and signs it off.
struct FixtureFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
private func requireRow(_ model: SecretDocumentViewModel, _ path: [String]) throws -> SecretRow {
    guard let row = model.rows.first(where: { $0.path == path }) else {
        throw FixtureFailure(
            "the fixture document has no row at \(path.joined(separator: ".")) — "
                + "it holds \(model.rows.map { $0.path.joined(separator: ".") })")
    }
    return row
}
