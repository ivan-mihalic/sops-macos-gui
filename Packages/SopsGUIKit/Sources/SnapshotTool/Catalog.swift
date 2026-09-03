import SopsEngine
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
        snapshots += settingsPane()
        snapshots += keyImportView()
        snapshots += updateSettingsPanel()
        snapshots += scanSettingsPanel()
        snapshots += try await projectTreeSidebar()
        snapshots += try await secretEditor()
        snapshots += try await projectHome()
        snapshots += try await projectAccessPage()
        snapshots += try projectStartHere()
        snapshots += dotEnvPreview()
        snapshots += try await newSecretFileSheet()
        // The guide's images. In the same catalog so one run can produce
        // both sets, but `Scripts/guide-snapshots.sh` filters to `guide-`
        // and writes them somewhere committed — see `Guide.swift`.
        snapshots += try await Guide.all()
        return snapshots
    }

    // MARK: - About

    /// Fixed facts rather than `AboutFacts.read()`: the snapshot tool's own
    /// bundle has none of the app's Info.plist keys, so the real reader would
    /// render "unknown (unknown)" and the image would show nothing about the
    /// layout that matters.
    /// The shipped app icon, found from this file's own location rather than
    /// from the working directory — `snapshots.sh` runs the tool from
    /// `Packages/SopsGUIKit`, so a repo-relative path silently missed and the
    /// snapshot rendered a generic folder.
    static func repositoryIcon() -> NSImage {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SnapshotTool
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // SopsGUIKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repository root
        let icon = root.appendingPathComponent(
            "App/Assets.xcassets/AppIcon.appiconset/icon_512x512.png")
        return NSImage(contentsOf: icon) ?? NSApplication.shared.applicationIconImage
    }

    private static func about() -> [Snapshot] {
        let facts = AboutFacts(version: "0.1.4", build: "128", commit: "abc1234",
                               sops: "3.13.3", age: "1.3.1")
        return [
            Snapshot("about-dark", size: CGSize(width: 620, height: 520), colorScheme: .dark) {
                AboutView(facts: facts, icon: repositoryIcon(), checkForUpdates: {})
            },
            Snapshot("setup-guide", size: CGSize(width: 760, height: 2400)) {
                SetupGuideView()
            },
            Snapshot("setup-guide-dark", size: CGSize(width: 760, height: 2400), colorScheme: .dark) {
                SetupGuideView()
            },
            Snapshot("about", size: CGSize(width: 620, height: 520)) {
            AboutView(facts: AboutFacts(version: "0.1.3", build: "127", commit: "abc1234",
                                        sops: "3.13.3", age: "1.3.1"),
                      // The real app icon, read from the repository. The
                      // default is `NSApplication.shared.applicationIconImage`,
                      // which under this tool is the *tool's* icon — so the
                      // snapshot would show something the app never displays.
                      icon: repositoryIcon(),
                      // Non-nil so the control renders. In the app this calls
                      // Sparkle; here it only has to exist for the layout.
                      checkForUpdates: {})
            },
        ]
    }

    // MARK: - Settings, as it appears inside the main window

    private static func settingsPane() -> [Snapshot] {
        let health = HealthViewModel(report: HealthReport(checks: []))
        let keyStore = SessionKeyStore()
        return [
            Snapshot("settings-pane", size: CGSize(width: 760, height: 560)) {
                SettingsPaneView(health: health, keyStore: keyStore)
            },
            Snapshot("settings-pane-dark", size: CGSize(width: 760, height: 560),
                     colorScheme: .dark) {
                SettingsPaneView(health: health, keyStore: keyStore)
            },
        ]
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
                AppShell(projects: projects, keyStore: keyStore, unsavedChanges: unsavedChanges,
                         health: HealthViewModel(report: HealthReport(checks: [])))
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

        // SOPS-46's third state. The vault is `InMemoryAgeKeyVault`, never
        // `KeychainAgeKeyVault`: this tool renders in a headless `Background`
        // session, where a real Touch ID prompt has no user and no window
        // server. The key inside it is the same fake shape as above.
        let locked = SessionKeyStore(vault: InMemoryAgeKeyVault(
            storedKey: "AGE-SECRET-KEY-1QTKPVHZDCRWEY069SMX3U8JAGN7F5L24QTKPVHZDCRWEY069SMX3U8JAGN"))

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
                KeyImportView(store: store, legacyKeyFiles: { options },
                              defaults: Fixtures.isolatedDefaults(prefix: "key-import"))
            }
        }

        return [
            keyImport("key-import-empty", empty, .one(libraryKeyFile)),
            keyImport("key-import-configured", configured, .one(libraryKeyFile)),
            keyImport("key-import-locked", locked, .one(libraryKeyFile)),
            keyImport("key-import-no-key-file", SessionKeyStore(),
                      .noneFound(searched: searched)),
            keyImport("key-import-several-key-files", SessionKeyStore(),
                      .several(searched)),
        ]
    }

    // MARK: - UpdateConsentToggle

    private static func updateSettingsPanel() -> [Snapshot] {
        let onDefaults = Fixtures.isolatedDefaults(prefix: "updates-on")
        UpdateCheckConsent.setEnabled(true, in: onDefaults)

        let offDefaults = Fixtures.isolatedDefaults(prefix: "updates-off")
        UpdateCheckConsent.setEnabled(false, in: offDefaults)

        return [
            Snapshot("update-settings-on", size: CGSize(width: 520, height: 260)) {
                UpdateConsentToggle(defaults: onDefaults)
            },
            Snapshot("update-settings-off", size: CGSize(width: 520, height: 260)) {
                UpdateConsentToggle(defaults: offDefaults)
            },
        ]
    }

    // MARK: - ScanSettingsPanel

    /// Ticket #25 claim 1. Two states, the same pair `updateSettingsPanel()`
    /// shows for its own toggle: an untouched default, and a value the user
    /// has actually raised — so a reviewer can see both without reading the
    /// footer text to know what changed.
    private static func scanSettingsPanel() -> [Snapshot] {
        let defaultDefaults = Fixtures.isolatedDefaults(prefix: "scanning-default")

        let raisedDefaults = Fixtures.isolatedDefaults(prefix: "scanning-raised")
        ScanBudgetSetting.set(50_000, in: raisedDefaults)

        return [
            Snapshot("scan-settings-default", size: CGSize(width: 520, height: 260)) {
                ScanSettingsPanel(defaults: defaultDefaults)
            },
            Snapshot("scan-settings-raised", size: CGSize(width: 520, height: 260)) {
                ScanSettingsPanel(defaults: raisedDefaults)
            },
        ]
    }

    // MARK: - The one sidebar (SOPS-39 task 6)

    /// Rendered standing alone rather than through `AppShell`, and that is
    /// not a shortcut: a `NavigationSplitView`'s own `sidebar:` column comes
    /// back **blank** under this tool (CLAUDE.md, "What it still cannot
    /// see"), so an `AppShell` snapshot would show an empty stripe where the
    /// navigation is.
    private static func projectTreeSidebar() async throws -> [Snapshot] {
        let (projects, trees) = try await Fixtures.projectTreeFixture()
        return [
            Snapshot("project-tree-sidebar", size: CGSize(width: 300, height: 520)) {
                ProjectTreeSidebar(
                    projects: projects, trees: trees, selection: .constant(nil),
                    onNewFile: { _ in }, onAddProjectAtPath: { _ in })
            },
        ]
    }

    // MARK: - The Access page

    /// SOPS-39 task 8. Rendered against a project with one drifted file, so
    /// the rewrap banner and the orange per-rule pill are both in frame — an
    /// all-in-sync project would show a page missing the half worth
    /// reviewing. 1000×900 is roughly the pane the shell gives it on a
    /// default-sized window.
    private static func projectAccessPage() async throws -> [Snapshot] {
        let model = try await Fixtures.projectAccessPageModel()
        return [
            Snapshot("project-access-page", size: CGSize(width: 1000, height: 900)) {
                ProjectAccessPage(
                    model: model,
                    selectedFile: model.inventory?.files.first?.url,
                    onFilesApplied: {})
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
            format: .yaml,
            keyStore: SessionKeyStore(),
            readFile: { _ in "irrelevant" })
        // Deliberately not awaited — this is what the view looks like the
        // instant a file is selected, before `load()` (called by
        // `AppShell`'s detail pane right after construction, per
        // `AppShell.swift`) has resolved.

        let loaded = try await Fixtures.editorLoadedViewModel()
        let empty = try await Fixtures.editorEmptyDocumentViewModel()
        let needsKey = await Fixtures.editorNeedsKeyViewModel()
        let failed = try await Fixtures.editorLoadFailedViewModel()
        let readOnlyCiphertext = try await Fixtures.editorReadOnlyCiphertextViewModel()
        let (pending, pendingSelection) = try await Fixtures.editorPendingChangesViewModel()
        let (revealed, revealedRowIDs) = try await Fixtures.editorRevealedRowViewModel()
        let dotenv = try await Fixtures.editorDotenvViewModel()
        let json = try await Fixtures.editorJSONViewModel()
        let ini = try await Fixtures.editorINIViewModel()

        let (table, tableSelection) = try await Fixtures.editorTableViewModel()
        let editorSize = CGSize(width: 760, height: 560)
        func editor(_ name: String, _ model: SecretDocumentViewModel, fileName: String) -> Snapshot {
            Snapshot(name, size: editorSize) {
                SecretEditorView(viewModel: model, fileName: fileName, unsavedChanges: UnsavedChangesTracker())
            }
        }

        return [
            // SOPS-39 task 7: the value table with its row inspector open.
            // 1100x640 is a wide window's share of the detail pane — the
            // width at which the old row list still gave the value under a
            // third of the pane. The check this snapshot exists for is
            // whether the Value column now takes more than half the table.
            Snapshot("secretTable", size: CGSize(width: 1100, height: 640)) {
                SecretEditorView(
                    viewModel: table, fileName: "production/.env",
                    unsavedChanges: UnsavedChangesTracker(),
                    initiallySelectedRowID: tableSelection)
            },
            // The inspector on its own, because `.inspector`'s column does
            // not populate under this headless technique — the same gap
            // CLAUDE.md records for `NavigationSplitView`'s `sidebar:` slot,
            // so `secretTable` above shows it as an empty column. This is
            // the only way to actually look at it.
            Snapshot("secretRowInspector", size: CGSize(width: 320, height: 640)) {
                SecretRowInspector(
                    viewModel: table, selectedRowID: tableSelection,
                    fileName: "production/.env", access: nil, nameFor: { _ in nil },
                    ruleLabel: nil,
                    // Revealed, because the masked state is the one a
                    // screenshot cannot tell apart from an empty pane — and
                    // the value editor is the thing worth reviewing here.
                    revealed: RevealedRows(revealing: [tableSelection], in: table.rowIdentityGeneration),
                    generation: table.rowIdentityGeneration,
                    onToggleReveal: { _ in }, onActivity: {})
            },
            editor("editor-loading", unloaded, fileName: "loading.yaml"),
            editor("editor-loaded", loaded, fileName: "production.secrets.yaml"),
            // The same document at the two ends of the range the window
            // actually allows. `ui-probe` can measure that the *window*
            // resizes; only a render shows whether the editor's own columns
            // survive it. 320 is the editor pane's declared minimum, 1100 a
            // wide window's share of it.
            Snapshot("editor-loaded-narrow", size: CGSize(width: 320, height: 560)) {
                SecretEditorView(viewModel: loaded, fileName: "production.secrets.yaml",
                                 unsavedChanges: UnsavedChangesTracker())
            },
            Snapshot("editor-w380", size: CGSize(width: 380, height: 300)) {
                SecretEditorView(viewModel: loaded, fileName: "p.yaml",
                                 unsavedChanges: UnsavedChangesTracker())
            },
            Snapshot("editor-w440", size: CGSize(width: 440, height: 300)) {
                SecretEditorView(viewModel: loaded, fileName: "p.yaml",
                                 unsavedChanges: UnsavedChangesTracker())
            },
            Snapshot("editor-w500", size: CGSize(width: 500, height: 300)) {
                SecretEditorView(viewModel: loaded, fileName: "p.yaml",
                                 unsavedChanges: UnsavedChangesTracker())
            },
            Snapshot("editor-loaded-wide", size: CGSize(width: 1100, height: 560)) {
                SecretEditorView(viewModel: loaded, fileName: "production.secrets.yaml",
                                 unsavedChanges: UnsavedChangesTracker())
            },
            // Dark. The app has never had a dark snapshot of anything except
            // `AppShell`, so every surface below was shipped without anyone
            // looking at it in the appearance half the users run.
            Snapshot("editor-loaded-dark", size: editorSize, colorScheme: .dark) {
                SecretEditorView(viewModel: loaded, fileName: "production.secrets.yaml",
                                 unsavedChanges: UnsavedChangesTracker())
            },
            editor("editor-empty-document", empty, fileName: "empty.secrets.yaml"),
            editor("editor-needs-key", needsKey, fileName: "needs-key.secrets.yaml"),
            editor("editor-load-failed", failed, fileName: "damaged.secrets.yaml"),
            // SOPS-38 phase F3: the real read-only ciphertext view — raw
            // ciphertext, the file's own (unregistered) recipient, and the
            // wrong-key reason. See `CiphertextReadOnlyView`.
            editor("editor-readonly-ciphertext", readOnlyCiphertext, fileName: "wrong-key.secrets.yaml"),
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
            Snapshot("editor-add-sheet-map", size: CGSize(width: 460, height: 420)) {
                Fixtures.addRowSheet(isList: false)
            },
            Snapshot("editor-add-sheet-list", size: CGSize(width: 460, height: 310)) {
                Fixtures.addRowSheet(isList: true)
            },
            // Task 6 (SOPS-38): the editor now opens dotenv sops files, not
            // just YAML — same view, a flat document with no map/list rows
            // at all.
            editor("editor-dotenv", dotenv, fileName: "production.env"),
            // The `+` sheet's type picker restricted to `.string` — the part
            // of Task 6 a YAML snapshot cannot show, since every kind is
            // legitimate there.
            Snapshot("editor-add-sheet-dotenv", size: CGSize(width: 460, height: 420)) {
                Fixtures.addRowSheetDotenv()
            },
            // SOPS-38 phase F2 task 4: the real per-format capability matrix
            // for json and ini — json renders exactly like YAML (nested map,
            // list); ini shows two sections, and its own add sheet at the
            // root state shows the message this app gives instead of a dead
            // end, since sops's INI store requires every root entry to be a
            // section and this app's Add API can never create one.
            editor("editor-json", json, fileName: "production.secrets.json"),
            editor("editor-ini", ini, fileName: "production.secrets.ini"),
            Snapshot("editor-add-sheet-ini-root-refused", size: CGSize(width: 460, height: 420)) {
                Fixtures.addRowSheetINIRootRefused()
            },
        ]
    }

    // MARK: - ProjectHomeView, every content state

    /// The states the file list used to carry alongside its rows — the
    /// incomplete-scan banner, the missing/unreadable roots, the narrowed
    /// empty placeholder and the footnotes — which live in the project's
    /// detail pane now that the rows themselves are in the sidebar. See
    /// `ProjectHomeView`'s own doc comment for why they needed a home.
    private static func projectHome() async throws -> [Snapshot] {
        let withFiles = try await Fixtures.fileListModelWithFiles()
        let empty = try await Fixtures.fileListModelEmpty()
        let missingRoot = await Fixtures.fileListModelMissingRoot()
        let incomplete = try await Fixtures.fileListModelIncompleteScan()
        let emptyPartial = try await Fixtures.fileListModelEmptyPartialScan()
        let unfollowedSymlink = try await Fixtures.fileListModelWithUnfollowedSymlink()

        let size = CGSize(width: 420, height: 480)
        func home(_ name: String, _ model: FileListModel) -> Snapshot {
            Snapshot(name, size: size) {
                ProjectHomeView(model: model, onNewFile: {})
            }
        }

        return [
            home("project-home-with-files", withFiles),
            home("project-home-empty", empty),
            home("project-home-missing-root", missingRoot),
            home("project-home-incomplete-scan", incomplete),
            home("project-home-empty-partial-scan", emptyPartial),
            home("project-home-unfollowed-symlink", unfollowedSymlink),
        ]
    }

    // MARK: - ProjectStartHereView
    //
    // `.configUnreadable`/`.unsupportedRule` get no snapshot here — those
    // two states already render through `CreationFailurePresenter
    // .message(forBlocking:)`, the identical failure banner other screens
    // already snapshot. Task 2's brief named three entries, one per state
    // that does get a sentence of its own on this screen (`.noConfig`,
    // `.governedByRule`, `.noRuleMatched`); this function actually returns
    // five, because `.governedByRule` gets two entries — with and without
    // an `encrypted_regex` scoping the rule, see the `encryptedRegex`
    // fixture's own comment below for why the second exists at all — plus
    // one more covering `otherFormatCount` sharing the screen with
    // `.noConfig`.
    private static func projectStartHere() throws -> [Snapshot] {
        let size = CGSize(width: 420, height: 320)
        // A bare root for the two states with no recipients to label either
        // way — see `Fixtures.startHereProjectRoot()`'s own doc comment.
        let plainRoot = try Fixtures.startHereProjectRoot()
        // Its own paired root, whose registry actually labels one of this
        // plan's own recipients "Alice" — see
        // `Fixtures.startHereGovernedFixture()`'s own doc comment for why
        // the plan and the root cannot be mixed and matched.
        let (governedPlan, governedRoot) = try Fixtures.startHereGovernedFixture()
        // A third root/plan pair, whose rule additionally sets
        // `encrypted_regex` — the one new output Important 1's fix produced
        // (`NewSecretFileSheet.governedByRuleSentence`'s appended scoping
        // disclosure) that this catalog had never rendered at all before
        // the review caught it.
        let (governedWithScopingPlan, governedWithScopingRoot) = try Fixtures.startHereGovernedFixture(
            encryptedRegex: "^(data|stringData)$")
        func startHere(
            _ name: String, _ configState: CreationPlan, in projectRoot: URL, otherFormatCount: Int = 0
        ) -> Snapshot {
            Snapshot(name, size: size) {
                ProjectStartHereView(
                    configState: configState, otherFormatCount: otherFormatCount, projectRoot: projectRoot,
                    onNewFile: {})
            }
        }
        return [
            startHere("start-here-no-config", Fixtures.startHereNoConfig, in: plainRoot),
            // Proves the registry-label fix reaches the screen: the first
            // recipient reads "Alice", the second still reads as a
            // shortened key (deliberately unlabeled) — see
            // `Fixtures.startHereGovernedFixture()`'s own doc comment.
            startHere("start-here-governed-by-rule", governedPlan, in: governedRoot),
            // The `encrypted_regex` disclosure, actually rendered and
            // looked at — see this function's own comment above.
            startHere(
                "start-here-governed-by-rule-with-scoping", governedWithScopingPlan,
                in: governedWithScopingRoot),
            startHere("start-here-no-rule-matched", Fixtures.startHereNoRuleMatched, in: plainRoot),
            // Task 2's own review question: whether a project that already
            // holds other-format sops files still reads clearly when the
            // guidance and that note share one screen.
            startHere(
                "start-here-no-config-other-formats", Fixtures.startHereNoConfig, in: plainRoot,
                otherFormatCount: 3),
        ]
    }

    // MARK: - DotEnvPreviewTable, covering all five suspicion kinds

    private static func dotEnvPreview() -> [Snapshot] {
        [
            Snapshot("dotenv-preview", size: CGSize(width: 640, height: 560)) {
                DotEnvPreviewTable(parsed: Fixtures.dotEnvPreviewFixture())
            },
        ]
    }

    // MARK: - NewSecretFileSheet — three of `Readiness`'s states

    private static func newSecretFileSheet() async throws -> [Snapshot] {
        let ready = try await Fixtures.newSecretFileModelReady()
        let needsAcknowledgement = try await Fixtures.newSecretFileModelNeedsAcknowledgement()
        let blocked = try await Fixtures.newSecretFileModelBlocked()

        let size = CGSize(width: 640, height: 560)
        func sheet(_ name: String, _ model: NewSecretFileModel) -> Snapshot {
            Snapshot(name, size: size) {
                NewSecretFileSheet(model: model, onCreated: { _ in })
            }
        }

        return [
            sheet("new-file-sheet-ready", ready),
            sheet("new-file-sheet-needs-acknowledgement", needsAcknowledgement),
            sheet("new-file-sheet-blocked", blocked),
        ]
    }
}
