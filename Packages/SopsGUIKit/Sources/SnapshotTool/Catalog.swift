import SopsHealth
import SopsProjects
import SopsUI
import SwiftUI

// The catalog. Adding a view = adding one `Snapshot` here — nothing else.
//
// Names are the on-disk filename and stay stable across commits: snapshots
// are meant to be diffed between commits, and renaming one manufactures a
// false "deleted + added" pair in place of a real change.
@MainActor
enum Catalog {
    static func all() async throws -> [Snapshot] {
        var snapshots: [Snapshot] = []
        snapshots += try await appShell()
        snapshots += await healthPanel()
        snapshots += healthFindingRow()
        snapshots += await onboardingWizard()
        snapshots += about()
        snapshots += keyImportView()
        snapshots += updateSettingsPanel()
        snapshots += try projectSidebar()
        snapshots += try await secretEditor()
        snapshots += try await fileList()
        return snapshots
    }

    // MARK: - About

    /// Fixed facts rather than `AboutFacts.read()`: the snapshot tool's own
    /// bundle has none of the app's Info.plist keys, so the real reader would
    /// render "unknown (unknown)" and the image would show nothing about the
    /// layout that matters.
    private static func about() -> [Snapshot] {
        [Snapshot("about", size: CGSize(width: 620, height: 520)) {
            AboutView(facts: AboutFacts(version: "0.1.0", build: "123", commit: "d85cae8",
                                        sops: "3.13.0", age: "1.2.1"))
        }]
    }

    // MARK: - AppShell, both appearances

    private static func appShell() async throws -> [Snapshot] {
        try [ColorScheme.light, .dark].map { scheme in
            let projects = try Fixtures.appShellProjectSidebarModel()
            let keyStore = SessionKeyStore()
            let unsavedChanges = UnsavedChangesTracker()
            return Snapshot(
                "app-shell-\(scheme == .dark ? "dark" : "light")",
                size: CGSize(width: 1200, height: 760),
                colorScheme: scheme
            ) {
                AppShell(projects: projects, keyStore: keyStore, unsavedChanges: unsavedChanges)
            }
        }
    }

    // MARK: - HealthPanel, a realistic finding set

    private static func healthPanel() async -> [Snapshot] {
        let model = await Fixtures.healthViewModel(findings: Fixtures.realisticFindings)
        return [
            Snapshot("health-panel", size: CGSize(width: 640, height: 680)) {
                HealthPanel(model: model)
            },
        ]
    }

    // MARK: - HealthFindingRow, every one of the five statuses

    private static func healthFindingRow() -> [Snapshot] {
        let cases: [(name: String, finding: HealthFinding)] = [
            ("ok", Fixtures.findingOK),
            ("warning", Fixtures.findingWarning),
            ("problem", Fixtures.findingProblem),
            ("skipped", Fixtures.findingSkipped),
            ("unknown", Fixtures.findingUnknown),
        ]
        return cases.map { name, finding in
            Snapshot("health-finding-row-\(name)", size: CGSize(width: 560, height: 170)) {
                HealthFindingRow(finding: finding, copyFeedback: CopyFeedback())
                    .padding()
            }
        }
    }

    // MARK: - OnboardingWizard: welcome, summary, and the long-finding overflow check

    /// Every wizard snapshot is sized to the wizard's own fixed sheet
    /// (`OnboardingWizard.body`'s `.frame(width: 640, height: 520)`) rather
    /// than some larger default canvas — the whole point of the third
    /// snapshot below is seeing whether content clips *inside that exact
    /// frame*, so the render canvas has to match it.
    private static let wizardSize = CGSize(width: 640, height: 520)

    private static func onboardingWizard() async -> [Snapshot] {
        let welcomeHealth = await Fixtures.healthViewModel(findings: Fixtures.realisticFindings)
        let welcomeState = Fixtures.onboardingState()
        // Default state is already `.welcome` — nothing to advance.

        let summaryHealth = await Fixtures.healthViewModel(findings: Fixtures.realisticFindings)
        let summaryState = Fixtures.onboardingState()
        // .welcome -> .tools -> .engine -> .security -> .projects -> .summary
        for _ in 0..<5 { summaryState.advance() }

        // The single most-suspected unverified defect in the whole project
        // (M2 brief): `HealthFindingRow` has no `.lineLimit`, and a
        // recipients finding can run to a dozen lines with embedded
        // newlines. This renders exactly that finding on the wizard's
        // `.projects` step (its id, `project.0.stale-recipients`, is what
        // routes it there — see `HealthViewModel.findings(in:)`), inside the
        // real fixed 640×520 sheet, so this is the first look anything has
        // ever gotten at whether it clips or overflows.
        let longFindingHealth = await Fixtures.healthViewModel(findings: [Fixtures.longRecipientsFinding])
        let longFindingState = Fixtures.onboardingState()
        // .welcome -> .tools -> .engine -> .security -> .projects
        for _ in 0..<4 { longFindingState.advance() }

        // The four category steps, all fed the *same* finding set that
        // `health-panel` is fed. Task 12 asks for two things a single wizard
        // snapshot cannot answer: that all six steps render (welcome and
        // summary were the only ones ever snapshotted), and that the wizard's
        // per-category steps agree with Settings › Health. Sharing
        // `realisticFindings` across both is what makes the second one a
        // comparison rather than an assertion of faith — a finding visible in
        // `health-panel`'s "Tools" section must appear on `onboarding-tools`
        // and nowhere else.
        var categorySteps: [Snapshot] = []
        for (index, name) in ["tools", "engine", "security", "projects"].enumerated() {
            let health = await Fixtures.healthViewModel(findings: Fixtures.realisticFindings)
            let state = Fixtures.onboardingState()
            // .welcome is step 0; .tools is one advance past it.
            for _ in 0...index { state.advance() }
            categorySteps.append(
                Snapshot("onboarding-\(name)", size: wizardSize) {
                    OnboardingWizard(health: health, state: state)
                })
        }

        return [
            Snapshot("onboarding-welcome", size: wizardSize) {
                OnboardingWizard(health: welcomeHealth, state: welcomeState)
            },
        ] + categorySteps + [
            Snapshot("onboarding-summary", size: wizardSize) {
                OnboardingWizard(health: summaryHealth, state: summaryState)
            },
            Snapshot("onboarding-projects-long-finding", size: wizardSize) {
                OnboardingWizard(health: longFindingHealth, state: longFindingState)
            },
        ]
    }

    // MARK: - KeyImportView

    private static func keyImportView() -> [Snapshot] {
        let empty = SessionKeyStore()

        let configured = SessionKeyStore()
        // Obviously-fake key text — never generated by `age-keygen`, never
        // rendered by this view (it only ever shows a checkmark and
        // "Configured"), but kept fake regardless per CLAUDE.md's standing
        // rule against secret-shaped values in fixtures.
        // 74 characters over the Bech32 alphabet — the shape `importKey`
        // requires since the shape check landed. The previous stand-in was 72
        // characters of "EXAMPLE", which `try?` swallowed: the store stayed
        // `.empty` and the snapshot named "configured" rendered the empty
        // state. A reviewer reading that PNG was approving a screen the app
        // never shows. `try!` would have caught it; `try?` made a broken
        // fixture look like a working one — and the comment saying so sat
        // directly above a `try?` for another whole round. It is `try!` now:
        // a dev tool crashing on a fixture it cannot build is the correct
        // outcome; writing a PNG that lies about the app is not.
        //
        // Not a real key and cannot decrypt anything — these snapshots only
        // exercise layout.
        try! configured.importKey("AGE-SECRET-KEY-1QTKPVHZDCRWEY069SMX3U8JAGN7F5L24QTKPVHZDCRWEY069SMX3U8JAGN")

        // The import control's three shapes, each pinned to a fixture rather
        // than to whatever happens to be under this machine's real `$HOME` —
        // otherwise these two snapshots would render differently on a Mac
        // that has a `keys.txt` and one that does not, which is not a diff
        // anyone wants to read. The label is the thing that was wrong here
        // (it named `~/.config/sops/age/keys.txt` unconditionally), so all
        // three get their own image.
        let libraryKeyFile = "/Users/example/Library/Application Support/sops/age/keys.txt"
        let dotConfigKeyFile = "/Users/example/.config/sops/age/keys.txt"
        let searched = [libraryKeyFile, dotConfigKeyFile]

        func keyImport(_ name: String,
                       _ store: SessionKeyStore,
                       _ options: LegacyKeyFileImportOptions) -> Snapshot {
            Snapshot(name, size: CGSize(width: 560, height: 460)) {
                KeyImportView(store: store, legacyKeyFiles: { options })
            }
        }

        return [
            keyImport("key-import-empty", empty, .one(libraryKeyFile)),
            keyImport("key-import-configured", configured, .one(libraryKeyFile)),
            keyImport("key-import-no-key-file", SessionKeyStore(),
                      .noneFound(searched: searched)),
            keyImport("key-import-several-key-files", SessionKeyStore(),
                      .several(searched)),
        ]
    }

    // MARK: - UpdateSettingsPanel

    private static func updateSettingsPanel() -> [Snapshot] {
        let onDefaults = Fixtures.isolatedDefaults(prefix: "updates-on")
        UpdateCheckConsent.setEnabled(true, in: onDefaults)

        let offDefaults = Fixtures.isolatedDefaults(prefix: "updates-off")
        UpdateCheckConsent.setEnabled(false, in: offDefaults)

        return [
            Snapshot("update-settings-on", size: CGSize(width: 520, height: 260)) {
                UpdateSettingsPanel(defaults: onDefaults)
            },
            Snapshot("update-settings-off", size: CGSize(width: 520, height: 260)) {
                UpdateSettingsPanel(defaults: offDefaults)
            },
        ]
    }

    // MARK: - Project sidebar, with a worktree group

    /// Three snapshots, because the sidebar's overflow fade only means
    /// something as a pair: `project-sidebar-many-projects` must show it and
    /// `project-sidebar-few-projects` must not. A fade over a list with
    /// nothing below it is a cue about content that does not exist, which is
    /// exactly the kind of small untruth `scrollOverflowFade()`'s own doc
    /// comment says it is built to avoid.
    ///
    /// All three at the same 300×520 column so the two overflow cases differ
    /// only in how many projects they hold.
    private static func projectSidebar() throws -> [Snapshot] {
        let worktree = try Fixtures.worktreeProjectSidebarModel()
        let many = try Fixtures.manyProjectsSidebarModel()
        let few = try Fixtures.fewProjectsSidebarModel()
        let size = CGSize(width: 300, height: 520)
        return [
            Snapshot("project-sidebar-worktree-group", size: size) {
                ProjectSidebar(model: worktree)
            },
            Snapshot("project-sidebar-many-projects", size: size) {
                ProjectSidebar(model: many)
            },
            Snapshot("project-sidebar-few-projects", size: size) {
                ProjectSidebar(model: few)
            },
        ]
    }

    // MARK: - SecretEditorView, all five load states

    /// `.idle`/`.loading` are not snapshotted on their own: `SecretEditorView`
    /// treats them identically (a bare `ProgressView`, see that type's doc
    /// comment), and both are transient states a real load already passes
    /// through in well under a second — there is nothing distinct for a
    /// static image to show beyond what `editor-loading` below already
    /// shows immediately after construction, before `load()` is awaited.
    private static func secretEditor() async throws -> [Snapshot] {
        let unloaded = SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/loading.yaml"),
            keyStore: SessionKeyStore(),
            readFile: { _ in "irrelevant" })
        // Deliberately not awaited — this is what the view looks like the
        // instant a file is selected, before `load()` (called by
        // `ProjectWorkspaceView.activateFile` right after construction, per
        // `AppShell.swift`) has resolved.

        let loaded = try await Fixtures.editorLoadedViewModel()
        let empty = try await Fixtures.editorEmptyDocumentViewModel()
        let needsKey = await Fixtures.editorNeedsKeyViewModel()
        let failed = try await Fixtures.editorLoadFailedViewModel()
        let (pending, pendingSelection) = try await Fixtures.editorPendingChangesViewModel()
        let (revealed, revealedRowIDs) = try await Fixtures.editorRevealedRowViewModel()

        let editorSize = CGSize(width: 760, height: 560)
        func editor(_ name: String, _ model: SecretDocumentViewModel, fileName: String) -> Snapshot {
            Snapshot(name, size: editorSize) {
                SecretEditorView(viewModel: model, fileName: fileName, unsavedChanges: UnsavedChangesTracker())
            }
        }

        return [
            editor("editor-loading", unloaded, fileName: "loading.yaml"),
            editor("editor-loaded", loaded, fileName: "production.secrets.yaml"),
            editor("editor-empty-document", empty, fileName: "empty.secrets.yaml"),
            editor("editor-needs-key", needsKey, fileName: "needs-key.secrets.yaml"),
            editor("editor-load-failed", failed, fileName: "wrong-key.secrets.yaml"),
            // Task 8b: the +/- affordance live, a row added in this session,
            // and a row removed — the state that did not exist before.
            Snapshot("editor-pending-changes", size: editorSize) {
                SecretEditorView(
                    viewModel: pending, fileName: "production.secrets.yaml",
                    unsavedChanges: UnsavedChangesTracker(),
                    initiallySelectedRowID: pendingSelection)
            },
            // One row revealed and the rest masked — the state a click on the
            // eye produces. Task 20: reveal had no snapshot and no test at
            // all, which is how a revealed row came to survive a save that
            // renumbered the list under it.
            Snapshot("editor-revealed-row", size: editorSize) {
                SecretEditorView(
                    viewModel: revealed, fileName: "production.secrets.yaml",
                    unsavedChanges: UnsavedChangesTracker(),
                    initiallyRevealedRowIDs: revealedRowIDs)
            },
            Snapshot("editor-add-sheet-map", size: CGSize(width: 460, height: 330)) {
                Fixtures.addRowSheet(isList: false)
            },
            Snapshot("editor-add-sheet-list", size: CGSize(width: 460, height: 310)) {
                Fixtures.addRowSheet(isList: true)
            },
        ]
    }

    // MARK: - FileListView, every content state

    private static func fileList() async throws -> [Snapshot] {
        let withFiles = try await Fixtures.fileListModelWithFiles()
        let empty = try await Fixtures.fileListModelEmpty()
        let missingRoot = await Fixtures.fileListModelMissingRoot()
        let incomplete = try await Fixtures.fileListModelIncompleteScan()
        let emptyPartial = try await Fixtures.fileListModelEmptyPartialScan()

        let size = CGSize(width: 320, height: 480)
        func list(_ name: String, _ model: FileListModel) -> Snapshot {
            Snapshot(name, size: size) {
                FileListView(model: model, selection: .constant(nil))
            }
        }

        return [
            list("file-list-with-files", withFiles),
            list("file-list-empty", empty),
            list("file-list-missing-root", missingRoot),
            list("file-list-incomplete-scan", incomplete),
            list("file-list-empty-partial-scan", emptyPartial),
        ]
    }
}
