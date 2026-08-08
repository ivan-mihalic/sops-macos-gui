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
            HealthFinding(
                id: "project.0.sops-yaml", title: "acme-web: .sops.yaml", status: .ok,
                detail: "Found a .sops.yaml with 2 creation rules."),
            HealthFinding(
                id: "project.0.plaintext-leak", title: "acme-web: plaintext leak", status: .ok,
                detail: "No plaintext .env files were found outside of .gitignore."),
        ]
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
            for line in output.split(separator: "\n") {
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
        let encrypted = try SopsBridge.encryptYAML(editorRichDocumentYAML, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-loaded.yaml"),
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
        let encrypted = try SopsBridge.encryptYAML("{}\n", recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-empty.yaml"),
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
            keyStore: store,
            readFile: { _ in "irrelevant — never reached with no key configured" })
        await model.load()
        return model
    }

    /// Real ciphertext, but the session holds a *different* real identity —
    /// the same "wrong key" shape `SopsDocumentTests` covers at the bridge
    /// layer, one level up: this is what the editor shows for it.
    static func editorLoadFailedViewModel() async throws -> SecretDocumentViewModel {
        let owner = try SnapshotAgeKeyPair.generate()
        let intruder = try SnapshotAgeKeyPair.generate()
        let encrypted = try SopsBridge.encryptYAML(
            "database:\n    password: hunter2-EXAMPLE\n", recipients: [owner.public])
        let store = SessionKeyStore()
        try store.importKey(intruder.private)
        let model = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/snapshot-wrong-key.yaml"),
            keyStore: store,
            readFile: { _ in encrypted })
        await model.load()
        return model
    }

    // MARK: - The file list (`FileListView`)

    /// Hand-written text carrying the same byte-level markers
    /// `EncryptedFileMetadata`/`ProjectScanner` sniff for (`sops:` block,
    /// `mac:` field) — mirrors `FileListModelTests.writeSopsLike`. What is
    /// under test in the file-list snapshots is layout, sorting and
    /// truncation/other-format disclosure, not sops's own file format,
    /// which the bridge's and `SopsEngineTests`' real-binary fixtures
    /// already hold to the real standard.
    private static func writeSopsLikeYAML(_ root: URL, at relativePath: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
            key: ENC[AES256_GCM,data:Zm9v,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
            sops:
                age:
                    - recipient: age1exampleexampleexampleexampleexampleexampleexampleexamplex
                mac: ENC[AES256_GCM,data:AAAA,iv:AAAAAAAAAAAAAAAAAAAAAA==,tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]
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

    /// A project whose directory no longer exists — deleted or unmounted
    /// after being added. `rootMissing`, never a silent "found nothing".
    static func fileListModelMissingRoot() async -> FileListModel {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-files-missing-" + UUID().uuidString)
        let model = FileListModel(projectRoot: root)
        await model.refresh()
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
