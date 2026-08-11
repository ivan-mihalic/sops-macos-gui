import Foundation
import SwiftUI

/// Every user-facing string this module can render.
///
/// Views never take a string literal. Adding a case without adding the matching
/// entry to Localizable.xcstrings fails `everyKeyResolves`.
public enum LocalizedKey: String, CaseIterable, Sendable {
    case sidebarProjects = "sidebar.projects"
    case sidebarAbout = "sidebar.about"
    case sidebarSettings = "sidebar.settings"
    case detailNoSelection = "detail.no-selection"
    case settingsWindowPlaceholder = "settings.window-placeholder"

    case statusOK = "status.ok"
    case statusWarning = "status.warning"
    case statusProblem = "status.problem"
    case statusSkipped = "status.skipped"
    case statusUnknown = "status.unknown"
    case actionCopy = "action.copy"
    case actionCopied = "action.copied"
    case actionLearnMore = "action.learn-more"
    case actionRerunChecks = "action.rerun-checks"
    case healthChecking = "health.checking"
    case healthCategoryTools = "health.category.tools"
    case healthCategoryEngine = "health.category.engine"
    case healthCategorySecurity = "health.category.security"
    case healthCategoryProjects = "health.category.projects"
    case healthCategoryOther = "health.category.other"
    // Shown on a wizard step whose category genuinely produced no findings
    // *after* a completed run. Blank space in its place would read as an
    // all-clear the app never asserted.
    case healthCategoryEmpty = "health.category.empty"
    // Shown when a completed report produced no findings at all. Deliberately
    // not the green "Everything checks out." — see OnboardingSummaryState.
    case healthNothingChecked = "health.nothing-checked"
    case settingsTabHealth = "settings.tab.health"
    case settingsTabUpdates = "settings.tab.updates"
    case settingsTabKey = "settings.tab.key"
    case settingsUpdatesToggle = "settings.updates.toggle"
    case settingsUpdatesExplanation = "settings.updates.explanation"
    case settingsUpdatesPrivacy = "settings.updates.privacy"

    case keyStatusConfigured = "key.status.configured"
    case keyStatusEmpty = "key.status.empty"
    case keyPasteHeader = "key.paste.header"
    case keyPasteFooter = "key.paste.footer"
    case keyImportPasteButton = "key.import.paste-button"
    case keyForgetButton = "key.forget-button"
    // The three shapes of the key-file import control, one per case of
    // `LegacyKeyFileImportOptions`. None of them contains a path: the one
    // case that may name a path — exactly one file found — shows it as
    // `Text(verbatim:)` beneath this title, because a path is not
    // translatable and, resolved through the catalog, would vanish under
    // whichever build system copies `.xcstrings` uncompiled. The old single
    // key read literally "Import from ~/.config/sops/age/keys.txt", naming a
    // path the app no longer necessarily reads and, on macOS, usually does
    // not.
    case keyImportLegacyButton = "key.import.legacy-button"
    case keyImportLegacyChooseButton = "key.import.legacy-choose-button"
    case keyImportLegacyNoneButton = "key.import.legacy-none-button"
    case keyImportLegacyFooter = "key.import.legacy-footer"
    // Introduces the list of paths that were stat'd and held nothing. Same
    // discipline as `SecurityPostureCheck`'s all-clear: "found nothing" means
    // nothing unless the places looked at are named.
    case keyImportLegacyNoneFooter = "key.import.legacy-none-footer"
    // Shown after a successful import from the legacy keys.txt file,
    // immediately above the same `chmod 600` remediation
    // `SecurityPostureCheck`'s `security.legacy-key-file` finding offers —
    // this is the moment the app can point at that advice, not invent its
    // own. See `KeyImportView`.
    case keyImportLegacySuccess = "key.import.legacy-success"
    case keyImportErrorTitle = "key.import.error-title"
    case keyErrorEmpty = "key.error.empty"
    case keyErrorNotAnAgeKey = "key.error.not-an-age-key"
    // Formatted with the number of keys found — see `KeyImportView.message(for:)`.
    case keyErrorMultipleKeys = "key.error.multiple-keys"
    // The paste field was given more than one line. Separate from
    // `key.error.multiple-keys`, which names a file and counts keys — neither
    // of which is true on the paste path.
    case keyErrorMultipleLinesPasted = "key.error.multiple-lines-pasted"
    // A key file with at most one key but other content besides comments.
    case keyErrorUnreadableKeysFile = "key.error.unreadable-keys-file"
    case keyErrorReadFailed = "key.error.read-failed"

    case actionBack = "action.back"
    case actionContinue = "action.continue"
    case actionDone = "action.done"
    case actionRunSetupCheck = "action.run-setup-check"
    case actionCheckForUpdates = "action.check-for-updates"
    case actionCheckAgain = "action.check-again"
    case aboutAppName = "about.app-name"
    case aboutEngineSops = "about.engine.sops"
    case aboutEngineAge = "about.engine.age"
    case aboutReleasesLink = "about.releases-link"
    case aboutPrivacyNote = "about.privacy-note"
    case onboardingWelcomeTitle = "onboarding.welcome.title"
    case onboardingSummaryTitle = "onboarding.summary.title"
    case onboardingWelcomeSubtitle = "onboarding.welcome.subtitle"
    case onboardingToolsSubtitle = "onboarding.tools.subtitle"
    case onboardingEngineSubtitle = "onboarding.engine.subtitle"
    case onboardingSecuritySubtitle = "onboarding.security.subtitle"
    case onboardingProjectsSubtitle = "onboarding.projects.subtitle"
    case onboardingSummarySubtitle = "onboarding.summary.subtitle"
    case onboardingWelcomeBody1 = "onboarding.welcome.body1"
    case onboardingWelcomeBody2 = "onboarding.welcome.body2"
    case onboardingWelcomeBody3 = "onboarding.welcome.body3"
    case onboardingSummaryOK = "onboarding.summary.ok"
    case onboardingSummaryWarning = "onboarding.summary.warning"
    case onboardingSummaryProblem = "onboarding.summary.problem"
    case onboardingSummaryFooter = "onboarding.summary.footer"
    case onboardingSummaryEvidence = "onboarding.summary.evidence"
    // Deliberately distinct from `.warning`: `.skipped` means a check's subject
    // doesn't exist yet (no projects added, a feature not shipped) — there is
    // nothing to look at, so "worth a look" would be false. See OnboardingWizard.
    case onboardingSummarySkipped = "onboarding.summary.skipped"
    // Deliberately distinct from both `.warning` and `.skipped`: `.unknown`
    // means the check ran but could not reach a verdict (offline, disabled) —
    // "could not run" would misdescribe checks that genuinely did run.
    case onboardingSummaryUnknown = "onboarding.summary.unknown"
    // Deliberately distinct from `.verdict(.ok)`: a report that ran no checks
    // has verified nothing, and "Everything checks out." would claim it did.
    case onboardingSummaryNothingChecked = "onboarding.summary.nothing-checked"

    case actionAddProject = "action.add-project"
    case actionRemoveProject = "action.remove-project"
    case actionCancel = "action.cancel"
    case projectsEmptyTitle = "projects.empty.title"
    // Shown next to a project whose directory could not be found on disk
    // right now — see `ProjectStore.isMissing(_:)`. The project stays in the
    // sidebar rather than vanishing; this badge is why it's still there.
    case projectsMissingBadge = "projects.missing-badge"
    case projectsWorktreeLabel = "projects.worktree-label"
    case projectsRemoveConfirmTitle = "projects.remove-confirm.title"
    // Load-bearing per PROPOSAL.md and CLAUDE.md: removing a project must
    // never be read as deleting it. This is the sentence that says so.
    case projectsRemoveConfirmMessage = "projects.remove-confirm.message"
    case projectsAddErrorTitle = "projects.add-error.title"
    case projectsErrorNotDirectory = "projects.error.not-directory"
    case projectsErrorDuplicate = "projects.error.duplicate"
    case projectsErrorAddFailed = "projects.error.add-failed"
    // A folder was dropped on the sidebar and the drop carried nothing this
    // app could read as a path — see `droppedProjectPath(from:)`.
    case projectsErrorDropUnreadable = "projects.error.drop-unreadable"
    // Formatted with the first problem and the number of further problems in
    // the same drop — see `ProjectSidebarModel.addDroppedProjects`.
    case projectsErrorDropPartial = "projects.error.drop-partial"
    case projectsErrorRemoveFailed = "projects.error.remove-failed"

    // MARK: Task 9 — file list

    case filesNoProjectSelected = "files.no-project-selected"
    case filesScanning = "files.scanning"
    case filesEmptyTitle = "files.empty.title"
    case filesProjectMissingTitle = "files.project-missing.title"
    case filesProjectUnreadableTitle = "files.project-unreadable.title"
    // Shown when a walk fell short of the whole tree in a way that blocks any
    // affirmative statement about the list. The *reason* is not a key: it comes
    // from `ScannedTree.incompleteScanReason` — see
    // `FileListView.incompleteScanBanner`.
    case filesScanIncompleteTitle = "files.scan-incomplete.title"
    // The empty state over an incomplete walk. `files.empty.title` claims the
    // project holds no encrypted files; over a walk that could not see all of
    // it, that claim is not available.
    case filesEmptyPartialTitle = "files.empty-partial.title"
    // Formatted with the comma-joined list of directory names never entered —
    // see `FileListView.footnotes`.
    case filesSkippedDirectoriesNote = "files.skipped-directories.note"
    // Formatted with the count of sops files this build can't open (dotenv/
    // JSON/INI — YAML-only for v1) — see `FileListModel.otherFormatCount`.
    case filesOtherFormatNote = "files.other-format.note"

    // MARK: Task 9 — editor

    case editorNoFileSelected = "editor.no-file-selected"
    case editorNeedsKeyTitle = "editor.needs-key.title"
    case editorNeedsKeyBody = "editor.needs-key.body"
    case editorLoadFailedTitle = "editor.load-failed.title"
    // Deliberately distinct from `.editorLoadFailedTitle`: a `.loaded`
    // document with zero rows is what `sops -e` on `{}` produces — a
    // legitimate, ordinary file, not a failure. See `SecretEditorView`'s
    // doc comment ("The property this view must not break").
    case editorEmptyDocumentTitle = "editor.empty-document.title"
    case editorEmptyDocumentBody = "editor.empty-document.body"
    case editorUnsavedIndicator = "editor.unsaved-indicator"
    case editorSaveButton = "editor.save-button"
    case editorSaveErrorTitle = "editor.save-error.title"
    case editorRevealValue = "editor.reveal-value"
    case editorHideValue = "editor.hide-value"
    case editorMergeKeyBadge = "editor.merge-key-badge"
    case editorMergeKeyExplanation = "editor.merge-key-explanation"
    case editorValueEncrypted = "editor.value-encrypted"
    case editorValueNotEncrypted = "editor.value-not-encrypted"
    case editorKindString = "editor.kind.string"
    case editorKindInt = "editor.kind.int"
    case editorKindFloat = "editor.kind.float"
    case editorKindBool = "editor.kind.bool"
    case editorKindNull = "editor.kind.null"
    case editorKindTimestamp = "editor.kind.timestamp"
    case editorKindEmptyMap = "editor.kind.empty-map"
    case editorKindEmptyList = "editor.kind.empty-list"

    // MARK: Task 8b — adding and removing rows

    case actionAdd = "action.add"
    case editorAddRow = "editor.add-row"
    case editorRemoveRow = "editor.remove-row"
    case editorRemoveRowDisabled = "editor.remove-row-disabled"
    case editorAddSheetTitle = "editor.add.title"
    case editorAddDestination = "editor.add.destination"
    case editorAddDestinationRoot = "editor.add.destination-root"
    case editorAddKeyField = "editor.add.key"
    case editorAddValueField = "editor.add.value"
    case editorAddTypeField = "editor.add.type"
    // A list entry has no name and no position to choose: it goes at the end.
    // Saying so is what stops a user looking for the field that isn't there.
    case editorAddListNote = "editor.add.list-note"
    case editorAddDuplicateKey = "editor.add.duplicate-key"
    // `<<` is YAML's merge key and `sops` at the top level is SOPS's own
    // metadata; a document that misuses either cannot be read back at all.
    // Mirrors `refuseReservedKey` in the bridge — see `AddRowRefusal`.
    case editorAddReservedKey = "editor.add.reserved-key"
    // Shown instead of a padlock on a row added in this session — see
    // `SecretEditorView`'s doc comment for why neither padlock would be true.
    case editorNewRowBadge = "editor.new-row-badge"
    case editorNewRowExplanation = "editor.new-row-explanation"

    // MARK: Task 9 — unsaved-changes prompts (file/project switch and quit)

    case editorUnsavedChangesTitle = "editor.unsaved-changes.title"
    case editorUnsavedChangesMessage = "editor.unsaved-changes.message"
    case editorSaveAndContinue = "editor.save-and-continue"
    case editorDiscardChanges = "editor.discard-changes"
    case actionQuit = "action.quit"
    case editorQuitUnsavedTitle = "editor.quit-unsaved.title"
    case editorQuitUnsavedMessage = "editor.quit-unsaved.message"
    case editorSaveAndQuit = "editor.save-and-quit"
    case editorDiscardAndQuit = "editor.discard-and-quit"

    // MARK: Task 3 (recipient management) — file access panel

    case accessToolbarButton = "access.toolbar-button"
    // Shown as the Access button's help text (and used to gate it disabled)
    // while the open document has unsaved edits — see
    // `SecretEditorView.canOpenAccessPanel`'s doc comment for the data-loss
    // finding this closes: applying a recipient change reloads the open
    // document, which discards anything mid-edit and never saved.
    case accessDisabledUnsavedChanges = "access.disabled-unsaved-changes"
    case accessTitle = "access.title"
    case accessLoadFailedTitle = "access.load-failed.title"
    case accessAddRecipientField = "access.add-recipient-field"
    // Shown under the add field when the pasted text matches a recipient
    // already staged — the bridge is the authority on whether the string is
    // actually a valid recipient at all; this only catches the one thing
    // knowable before `apply()` re-checks against the real document. See
    // `RecipientAccessModel.StageAddRefusal`.
    case accessAddDuplicate = "access.add.duplicate"
    case accessApplyButton = "access.apply-button"
    // The accessibility label on the progress indicator shown while
    // `RecipientAccessModel.apply()` is in flight — otherwise a bare spinner
    // announces nothing to VoiceOver.
    case accessApplyingLabel = "access.applying-label"
    // Reading who has access never needs a key; only applying a change does.
    // Shown instead of failing obscurely when no session key is configured —
    // see `RecipientAccessModel.keyConfigured`.
    case accessNeedsKeyBody = "access.needs-key.body"
    case accessApplyErrorTitle = "access.apply-error.title"
    // `RecipientAccessModel.ApplyOutcome.refusedEmptyRecipients` — a fixed
    // enum case, not bridge text, so it is localized here rather than
    // carried as a string on the model. Mirrors how `AddRowRefusal` is
    // translated in `EditorAddRowSheet.explanation(for:)`.
    case accessErrorEmptyRecipients = "access.error.empty-recipients"
    // Removing a recipient is destructive — PROPOSAL.md and CLAUDE.md both
    // require naming what will be lost before it happens.
    case accessRemoveConfirmTitle = "access.remove-confirm.title"
    // Formatted with the comma-joined labels (or public keys, for anyone the
    // registry doesn't know) about to lose access — see
    // `RecipientAccessView.removalConfirmationMessage`.
    case accessRemoveConfirmMessage = "access.remove-confirm.message"
    case accessRemoveConfirmButton = "access.remove-confirm.button"
    case accessPendingRemovalBadge = "access.pending-removal-badge"
    case accessPendingAdditionBadge = "access.pending-addition-badge"
    case accessRemoveRecipient = "access.remove-recipient"
    // The undo for a recipient already staged for removal — tapping the same
    // control again re-adds it to the staged set. See
    // `RecipientAccessModel.stageAdd`/`stageRemove`'s symmetry.
    case accessUndoRemoval = "access.undo-removal"

    // MARK: Task 4 (recipient management) — project access panel

    case projectAccessButton = "project-access.button"
    // The project panel re-wraps every file the creation rule governs, which
    // may include the document open in the editor. Applying while that
    // document has unsaved edits would rewrite the file underneath them —
    // the same data-loss shape `SecretEditorView.canOpenAccessPanel` closes
    // for the single-file panel, and gated the same way.
    case projectAccessDisabledUnsavedChanges = "project-access.disabled-unsaved-changes"
    case projectAccessTitle = "project-access.title"
    case projectAccessScanning = "project-access.scanning"
    // Formatted with the count of files the governing rule covers, and the
    // count of encrypted files found in total.
    case projectAccessFilesSummary = "project-access.files-summary"
    // Files that are encrypted but that some *other* creation rule governs.
    // Stated rather than silently skipped: a project apply that quietly left
    // files out would be the confident-about-what-it-did-not-touch claim
    // PROPOSAL §6 D forbids.
    case projectAccessUnmatchedNote = "project-access.unmatched-note"
    // What an apply would touch when no governing creation rule could be
    // identified — no config, an unreadable one, or one whose rules match
    // nothing here. `Plan.filesInScope` deliberately widens to every encrypted
    // file in that case (applying to *nothing* and reporting success is the
    // worse reading), so the panel has to say so before the button is pressed
    // rather than only in the confirmation dialog.
    case projectAccessAllFilesInScope = "project-access.all-files-in-scope"
    case projectAccessScanIncompleteTitle = "project-access.scan-incomplete.title"
    // The two ways a project can produce an *empty* scan that is not an
    // answer about anything. Reported rather than folded into "no encrypted
    // files found here", which would be a confident statement about a
    // directory the walk never got into — the one thing PROPOSAL §6 D says
    // this app must never do. See `ScannedTree.rootMissing`/`rootUnreadable`.
    case projectAccessRootMissing = "project-access.root-missing"
    case projectAccessRootUnreadable = "project-access.root-unreadable"
    case projectAccessNoConfig = "project-access.no-config"
    case projectAccessNoFiles = "project-access.no-files"
    case projectAccessConfigSectionTitle = "project-access.config-section.title"
    // The heading over the sentence the *bridge* produced explaining which
    // `.sops.yaml` shape it will not rewrite — see
    // `ProjectRecipientApplier.Plan.configRefusal`. The sentence itself is
    // engine text shown verbatim, like a health finding's, because it names
    // the specific shape found.
    case projectAccessConfigReadOnlyTitle = "project-access.config-read-only.title"
    case projectAccessConfigErrorTitle = "project-access.config-error.title"
    case projectAccessConfigUpToDate = "project-access.config-up-to-date"
    case projectAccessConfigWritten = "project-access.config-written"
    case projectAccessUpdateConfigButton = "project-access.update-config-button"
    case projectAccessUpdateConfigConfirmTitle = "project-access.update-config-confirm.title"
    case projectAccessUpdateConfigConfirmMessage = "project-access.update-config-confirm.message"
    case projectAccessUpdateConfigConfirmButton = "project-access.update-config-confirm.button"
    case projectAccessApplyFilesButton = "project-access.apply-files-button"
    case projectAccessApplyFilesConfirmTitle = "project-access.apply-files-confirm.title"
    // Formatted with the number of files that would be re-wrapped.
    case projectAccessApplyFilesConfirmMessage = "project-access.apply-files-confirm.message"
    // The destructive variant, formatted with the comma-joined labels (or
    // public keys) about to lose access *and* the file count. Removing a
    // recipient across a whole project is the most destructive thing this
    // panel can do, so it names who loses access before it happens.
    case projectAccessApplyFilesRemovalMessage = "project-access.apply-files-removal.message"
    case projectAccessApplyFilesConfirmButton = "project-access.apply-files-confirm.button"
    case projectAccessCancelRun = "project-access.cancel-run"
    case projectAccessResultsTitle = "project-access.results.title"
    case projectAccessResultUpdated = "project-access.result.updated"
    case projectAccessResultUnchanged = "project-access.result.unchanged"
    case projectAccessResultFailed = "project-access.result.failed"
    // Formatted with updated / unchanged / failed counts.
    case projectAccessResultsSummary = "project-access.results.summary"
    // Formatted with the count of files a cancelled run never reached.
    case projectAccessCancelledNote = "project-access.cancelled-note"
    case projectAccessApplyingLabel = "project-access.applying-label"
    case projectAccessErrorTitle = "project-access.error.title"
    case projectAccessErrorEmptyRecipients = "project-access.error.empty-recipients"
    case projectAccessErrorNoFiles = "project-access.error.no-files"

    /// The resolved English text. Used in views and asserted in tests.
    public var text: String {
        String(localized: String.LocalizationValue(rawValue), bundle: .module)
    }
}

public extension Text {
    init(_ key: LocalizedKey) {
        self.init(key.text)
    }
}

public extension Label where Title == Text, Icon == Image {
    init(_ key: LocalizedKey, systemImage: String) {
        self.init(key.text, systemImage: systemImage)
    }
}
