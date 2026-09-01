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
    // Ticket #22: findings carried no timestamp on screen, so a stale report
    // looked identical to a current one. Paired with a relative-time `Text`
    // (`Text(date, style: .relative)`), e.g. "Last checked 2 minutes ago" —
    // see `HealthPanel`.
    case healthLastChecked = "health.last-checked"
    case settingsTabHealth = "settings.tab.health"
    case settingsTabUpdates = "settings.tab.updates"
    case settingsTabKey = "settings.tab.key"
    case settingsTabScanning = "settings.tab.scanning"
    case settingsUpdatesToggle = "settings.updates.toggle"
    case settingsUpdatesExplanation = "settings.updates.explanation"
    case settingsUpdatesPrivacy = "settings.updates.privacy"
    // Ticket #25 claim 1: ProjectScanner.maxScannedFiles used to be a
    // hardcoded ceiling nothing in the app could change — see
    // ScanBudgetSetting.
    case settingsScanningBudgetLabel = "settings.scanning.budget-label"
    case settingsScanningBudgetFooter = "settings.scanning.budget-footer"
    case settingsScanningResetButton = "settings.scanning.reset-button"

    case keyStatusConfigured = "key.status.configured"
    case keyStatusEmpty = "key.status.empty"
    case keyPasteHeader = "key.paste.header"
    case keyPasteFooter = "key.paste.footer"
    case keyTTLHeader = "key.ttl.header"
    case keyTTLFooter = "key.ttl.footer"
    case keyTTLMinutes = "key.ttl.minutes"
    case keyPasteNoKeyYet = "key.paste.no-key-yet"
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
    // Ticket #7: `AgeKeyFileLocations.protectCommand(for:)` returns nil for a
    // path `ShellQuoting` refuses to represent as one safe shell word — a
    // newline is the reachable case, and `SOPS_AGE_KEY_FILE` is user-settable.
    // Before this existed the command block below `keyImportLegacySuccess`
    // simply vanished with nothing in its place, so a user on exactly that
    // path never learned there was still something to do.
    case keyImportLegacyChmodUnavailable = "key.import.legacy-chmod-unavailable"
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
    // `files.empty.title` ("No encrypted files found in this project.") lived
    // here through M2 but is gone as of Phase 3 Task 2: a *complete* empty
    // scan now renders `ProjectStartHereView` instead, which never makes
    // that bare claim — it says what `configState` actually supports (see
    // that type's own doc comment). Only the *incomplete*-scan empty state
    // below survived, because "empty" is not a claim this app can make
    // honestly over a walk that did not finish.
    case filesProjectMissingTitle = "files.project-missing.title"
    case filesProjectUnreadableTitle = "files.project-unreadable.title"
    // Shown when a walk fell short of the whole tree in a way that blocks any
    // affirmative statement about the list. The *reason* is not a key: it comes
    // from `ScannedTree.incompleteScanReason` — see
    // `FileListView.incompleteScanBanner`.
    case filesScanIncompleteTitle = "files.scan-incomplete.title"
    // The empty state over an incomplete walk — the one case
    // `ProjectStartHereView` never reaches (`FileListView.showsStartHere`
    // requires `incompleteScanReason == nil`), because "no encrypted files"
    // is not a claim this app can make about a walk that did not finish.
    case filesEmptyPartialTitle = "files.empty-partial.title"
    // Formatted with the comma-joined list of directory names never entered —
    // see `FileListView.footnotes`.
    case filesSkippedDirectoriesNote = "files.skipped-directories.note"
    // Formatted with the count of sops files this build does not recognise
    // as any of its four known formats (YAML/dotenv/JSON/INI) — reserved for
    // a future sops store, so this is expected to be 0 today. See
    // `FileListModel.otherFormatCount` / `ScannedTree.encryptedInOtherFormats`.
    case filesOtherFormatNote = "files.other-format.note"
    // Ticket #25 claim 2. Formatted with the symlink's own relative path and
    // its resolved target — see `FileListView.unfollowedSymlinkFootnote`.
    case filesUnfollowedSymlinkNote = "files.unfollowed-symlink.note"
    case filesAddSymlinkTargetButton = "files.unfollowed-symlink.add-button"
    // SOPS-38 phase F3: shown next to a row whenever `ListedFile.isReadOnly`
    // is true — a hint only, never a claim this app is entitled to more than
    // conservatively (see that property's own doc comment). The accessibility
    // label doubles as the tooltip, the same "icon-only control" idiom
    // `filesNewFileButton` already uses.
    case filesReadOnlyBadge = "files.read-only-badge"

    // MARK: Task 7 (F2) — reaching the new-file wizard from the file list

    // The toolbar "+" above the file list, and its ⌘N shortcut. Icon-only —
    // this text is the accessibility label and the tooltip, never rendered
    // as a title. Only reachable at all once a project is selected: the
    // toolbar row lives inside `FileListView`, which `ProjectWorkspaceView`
    // never constructs without one — see `AppShell.makeNewFileModel(
    // projectRoot:keyStore:)`.
    case filesNewFileButton = "files.new-file-button"

    // MARK: Phase 3 Task 2 — ProjectStartHereView
    //
    // What an *empty, completely scanned* project shows in place of the old
    // `files.empty.title` — see `ProjectStartHereView`'s own doc comment for
    // which of `CreationPlan`'s five values reaches which sentence.
    //
    // `.noConfig` and `.governedByRule` reuse `new-file.info.no-config`/
    // `new-file.info.governed-by-rule` (`NewSecretFileSheet`'s own ⓘ-line
    // keys) verbatim rather than a second, near-duplicate entry with the
    // same fact worded slightly differently — an earlier draft of this file
    // kept three separate "start-here.*.title" keys that said the same
    // three facts `new-file.info.*` already say, and the `.no-rule-matched`
    // one had already drifted into two false claims (see
    // `ProjectStartHereView`'s own doc comment for the account) before this
    // review caught it. `.configUnreadable`/`.unsupportedRule` get no key
    // here either — those two reuse `CreationFailurePresenter
    // .message(forBlocking:)`'s own sentence.
    //
    // `.noRuleMatched` and `.governedByRule` each need one further,
    // additive key beyond their reused fact sentence — reviewed together
    // below because a whole-branch review found the same defect in both:
    // the reused sentence names "this location" (`new-file.info.governed-
    // by-rule`) or leans on it implicitly (`new-file.info.no-rule-matched`,
    // "this location yet"), which reads fine one screen over — in
    // `NewSecretFileSheet` it sits directly under the filename field the
    // user just typed, so the referent is on screen. Here there is no
    // filename anywhere: `configState` answers for a probe at the project
    // root (`FileListModel.configState`'s own doc comment), and this
    // screen's only headline is otherwise the sole thing on an empty pane —
    // exactly the shape that reads as a claim about the whole project
    // rather than about one unlabeled spot in it. `startHereProbeLocation`
    // names that spot for both arms, in the same reused-not-reworded
    // fashion this file already holds every other line here to.
    case startHereProbeLocation = "start-here.probe-location"
    // The *reassurance* half of `.noRuleMatched`'s sentence — the wizard's
    // own ⓘ line does not need to say this out loud, because it sits
    // directly above a working `RecipientPicker`, so nothing there has to
    // state "this isn't an error". This screen has no such context to lean
    // on.
    //
    // Hedged with "may still" rather than "does" or "will" — this project
    // could have no `creation_rules` at all (`.noRuleMatched` covers that
    // shape too, per `CreationRuleLookup.matched`'s own doc comment), so a
    // flat claim that another rule exists would be exactly the false
    // "already has rules" `ProjectStartHereView`'s doc comment names as the
    // finding this key exists to close.
    case startHereNoRuleMatchedReassurance = "start-here.no-rule-matched.reassurance"
    // The button `.noConfig`/`.governedByRule` show. Not "New File" (the
    // toolbar "+"'s own tooltip, `files.new-file-button`) — this is a
    // visible label on a real button, not an icon-only control's
    // accessibility text, and this screen's whole point is that there is
    // nothing to open yet.
    case startHereCreateFirstFileButton = "start-here.create-first-file-button"

    // MARK: Task 9 — editor

    case editorNoFileSelected = "editor.no-file-selected"
    case editorNeedsKeyTitle = "editor.needs-key.title"
    case editorNeedsKeyBody = "editor.needs-key.body"
    case editorLoadFailedTitle = "editor.load-failed.title"
    case editorLoadFailedWrongKey = "editor.load-failed.wrong-key"
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

    // MARK: SOPS-38 phase F3 — the real read-only ciphertext view

    // `CiphertextReadOnlyView`'s framing chrome around `LoadState
    // .readOnlyCiphertext`'s own `reason` — that string is bridge prose
    // (the same wrong-key sentence `.failed` used to carry,
    // `editorLoadFailedWrongKey`) and is rendered verbatim, never through
    // this catalog. This title is deliberately distinct from
    // `editorLoadFailedTitle`: the file *did* open, as ciphertext — it is
    // not "couldn't be opened" the way a damaged file or bad MAC is.
    case editorReadOnlyCiphertextTitle = "editor.read-only-ciphertext.title"
    case editorReadOnlyCiphertextRecipientsHeading = "editor.read-only-ciphertext.recipients-heading"
    // Shown instead of the recipient list when `recipients` came back empty —
    // `LoadState.readOnlyCiphertext`'s own doc comment: that is "this app
    // could not read the file's own metadata", not "this file has no
    // recipients at all", so the sentence must not claim either.
    case editorReadOnlyCiphertextRecipientsUnknown = "editor.read-only-ciphertext.recipients-unknown"
    case editorReadOnlyCiphertextContentsHeading = "editor.read-only-ciphertext.contents-heading"

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
    // SOPS-38 fix-wave C1: a dotenv document's own store reads a value back
    // by splitting on the first `=` and treating a leading `#` as a comment,
    // so a key using either character (or an embedded newline) saves without
    // error and can never be decrypted again. Mirrors `refuseInvalidDotenvKey`
    // in the bridge — see `AddRowRefusal.invalidDotenvKey`.
    case editorAddInvalidDotenvKey = "editor.add.invalid-dotenv-key"
    // SOPS-38 phase F2 task 4: an INI document's own store either corrupts
    // the whole file or silently changes the key that gets saved for a
    // different set of hazardous shapes than dotenv's. Mirrors
    // `refuseInvalidINIKey` in the bridge — see
    // `AddRowRefusal.invalidINIKey`.
    case editorAddInvalidINIKey = "editor.add.invalid-ini-key"
    // SOPS-38 phase F2 task 4: shown for `AddRowRefusal.unsupportedForFormat`
    // — in practice reachable from this sheet only for an INI document's own
    // root, where sops's INI store requires every entry to be a section and
    // this app has no way to create one. See `AddCapabilities` on
    // `SecretDocumentViewModel`.
    case editorAddUnsupportedForFormat = "editor.add.unsupported-for-format"
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
    // SOPS-38 phase F3: shown instead of `accessDisabledUnsavedChanges` when
    // the open document is `LoadState.readOnlyCiphertext` — that document has
    // no unsaved edits to save first, and saying so would be false. Applying
    // a recipient change needs to decrypt and re-wrap the file, which is
    // exactly what this state cannot do — see `SecretEditorView
    // .canOpenAccessPanel`, whose `loadState == .loaded` half already
    // disables the button here; this only makes the *reason* honest.
    case accessDisabledReadOnlyCiphertext = "access.disabled-read-only-ciphertext"
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
    // Formatted with how many age recipients this file's SOPS metadata names
    // more than once. sops does not deduplicate a flat age list, so this is a
    // shape a real file can have; the panel collapses each key to one row
    // (multiplicity is not access) and says so here rather than tidying it
    // away without a word. See `RecipientAccessModel.duplicatedRecipients`.
    case accessDuplicateRecipients = "access.duplicate-recipients"

    // SOPS-33: the title on the banner both Access panels show when
    // `registryQuarantineNotice` is set — `RecipientAccessModel
    // .registryQuarantineNotice`/`ProjectAccessModel
    // .registryQuarantineNotice`, set by `RecipientRegistry
    // .loadOrQuarantine(in:)` exactly when `recipients.json` existed but
    // could not be decoded and was moved aside. One key shared by both
    // panels, the same way `accessNeedsKeyBody` already is — the sentence
    // does not change meaning between the per-file and project-wide screen.
    // The notice body itself is never a catalog string: it carries the
    // registry's real path, composed at runtime by `RecipientRegistry` and
    // shown verbatim, the same treatment `ProjectAccessView.explanation(_:_
    // :tint:)` gives a config error.
    case accessRegistryQuarantineTitle = "access.registry-quarantine.title"

    // Ticket #3: a recipient removal this panel already applied may have
    // left this file owing a rotation of its values — see
    // `RecipientAccessModel.rotationDebtEntries` and
    // `SopsHealth.RotationDebtSource`. This app cannot verify a rotation
    // happened, only record that one is owed and let the user say when it
    // is done — the heading and button below must never claim more than
    // that.
    case accessRotationDebtHeading = "access.rotation-debt.heading"
    case accessRotationDebtAcknowledgeButton = "access.rotation-debt.acknowledge-button"

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
    // The other half of that widening, and the half the count alone hides:
    // the fallback scope reaches across creation-rule boundaries, so files
    // whose keys a *different* rule decides are re-wrapped alongside the ones
    // no rule governs. Formatted with how many. Shown on the panel and again
    // in the file-apply confirmation, because
    // `project-access.unmatched-note` — the sentence that names other rules —
    // renders only in the branch where a rule *was* identified, which is the
    // one branch that does not need it.
    case projectAccessOtherRulesInScope = "project-access.other-rules-in-scope"
    // Ticket #24 claim 1. Sits directly under `projectAccessOtherRulesInScope`
    // and requires an explicit check before "Apply to Files" is reachable at
    // all — see `ProjectAccessModel.requiresWidenedScopeAcknowledgement`.
    // Stating the fact was never the gap; nothing enforced that it was read.
    case projectAccessWidenedScopeAcknowledgement = "project-access.widened-scope.acknowledgement"
    // The heading over the list of files an apply would re-wrap, shown before
    // the run rather than only as results after it. The counts above it say
    // how many; this says which — the question a user actually has to answer
    // before pressing a button that rewrites files.
    case projectAccessFilesPreviewTitle = "project-access.files-preview.title"
    // Formatted with how many files in scope the preview did not draw. The
    // preview is bounded (`ProjectAccessView.filesPreviewLimit`) so a project
    // with thousands of encrypted files costs what a small one costs; the
    // remainder is stated rather than left to be inferred from the count above.
    case projectAccessFilesPreviewMore = "project-access.files-preview.more"
    case projectAccessScanIncompleteTitle = "project-access.scan-incomplete.title"
    // Ticket #24 claim 3. Formatted with how many files a previous run left
    // untouched — `ProjectAccessModel.previousIncompleteRun`, read from
    // `RunRecordStore` so it survives the panel having been closed.
    case projectAccessPreviousRunIncomplete = "project-access.previous-run-incomplete"
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
    // Who the rewritten creation rule gains, and who it loses. Formatted with
    // the comma-joined labels (or public keys, for anyone the registry does not
    // know), exactly like the other two confirmations in this feature — this
    // was the one mutating action of the three whose dialog named nobody.
    //
    // `…loses` carries the whole point of the distinction: dropping a recipient
    // from a creation rule takes nothing away from them. Every file already on
    // disk still decrypts for them, because their key is still in that file's
    // own SOPS metadata. Only "Apply to Files" changes that.
    case projectAccessConfigGains = "project-access.update-config-confirm.gains"
    case projectAccessConfigLoses = "project-access.update-config-confirm.loses"
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
    case projectAccessResultsCommitNote = "project-access.results.commit-note"
    // Formatted with the count of files a cancelled run never reached.
    case projectAccessCancelledNote = "project-access.cancelled-note"
    case projectAccessApplyingLabel = "project-access.applying-label"
    case projectAccessErrorTitle = "project-access.error.title"
    case projectAccessErrorEmptyRecipients = "project-access.error.empty-recipients"
    case projectAccessErrorNoFiles = "project-access.error.no-files"
    // `ProjectAccessModel.ConfigApplyOutcome.refusedStalePlan`: the staged set
    // moved again while the panel was working out what to write, so the only
    // `.sops.yaml` text on hand belongs to an older set. Nothing is written —
    // writing it would drop the recipients staged since, silently.
    case projectAccessErrorStalePlan = "project-access.error.stale-plan"
    // `ProjectAccessModel.FileApplyRefusal.alreadyRunning`: a run was already
    // in progress the moment this one was requested. Reachable in practice
    // only by a caller outside this view's own button, which queues behind an
    // in-flight run rather than asking again — see
    // `ProjectAccessModel.startApplyingToFiles`.
    case projectAccessErrorAlreadyRunning = "project-access.error.already-running"
    // `ProjectAccessModel.FileApplyRefusal.widenedScopeNotAcknowledged`:
    // reachable in practice only if a future caller finds a way to press
    // Apply while the view's own gate should have disabled it — see
    // `ProjectAccessView.canApplyToFiles`.
    case projectAccessErrorWidenedScopeNotAcknowledged = "project-access.error.widened-scope-not-acknowledged"
    // The creation-rule half of `access.duplicate-recipients`, formatted the
    // same way and for the same reason.
    case projectAccessDuplicateRecipients = "project-access.duplicate-recipients"
    // Formatted with how many of `encryptedFiles`' names were dropped because
    // they and a still-listed entry named the same file — a symlink and its
    // target, most often. Information, not a warning: nothing is wrong with a
    // project that has a symlink in it, and this only says the count shown is
    // smaller than the number of paths the scan actually found. See
    // `ProjectRecipientApplier.Plan.duplicateFileNameCount` and
    // `.deduplicatedByResolvedPath`.
    case projectAccessCollapsedDuplicateFiles = "project-access.collapsed-duplicate-files"

    // MARK: Recipient kinds — the registry's descriptive role for a key

    // Descriptive only: `.sops.yaml` and SOPS metadata remain the access
    // authority (see `RecipientKind`). Shown in both Access panels, which the
    // design spec asks for — "the human name, the *type* and the public key".
    case recipientKindDevice = "recipient.kind.device"
    case recipientKindServer = "recipient.kind.server"
    case recipientKindPerson = "recipient.kind.person"

    // MARK: The registry editor — naming a key, and forgetting the name

    // The two states of the row control that opens the editor. A recipient the
    // registry has never heard of is offered a name; one it knows is offered an
    // edit.
    case recipientNameThis = "recipient.name-this"
    case recipientEditLabel = "recipient.edit-label"
    case recipientEditorTitleNew = "recipient.editor.title-new"
    case recipientEditorTitleEdit = "recipient.editor.title-edit"
    // Says what the registry *is*, on the one screen where a user is writing to
    // it: a directory of names, never the authority on who can decrypt. Without
    // this, an editor that says "Save" over a list of recipients invites exactly
    // the wrong inference.
    case recipientEditorRegistryExplanation = "recipient.editor.registry-explanation"
    case recipientEditorKeyCaption = "recipient.editor.key-caption"
    case recipientEditorLabelField = "recipient.editor.label-field"
    case recipientEditorKindField = "recipient.editor.kind-field"
    case recipientEditorNoteField = "recipient.editor.note-field"
    case recipientEditorSave = "recipient.editor.save"
    case recipientEditorSavingLabel = "recipient.editor.saving-label"

    // Forgetting a name removes a nickname and **no access at all**: the
    // recipient goes on decrypting everything they could decrypt before. The
    // control, its accessibility label and its confirmation each say so
    // independently, because a user may stop reading at any one of them — and a
    // user who reads this as a revocation has been misled by the one tool whose
    // job is to say who can read their secrets. It is equally deliberate that
    // none of them is styled or worded as destructive: nothing is destroyed.
    case recipientForgetLabel = "recipient.forget-label"
    case recipientForgetLabelAccessibility = "recipient.forget-label.accessibility"
    case recipientForgetConfirmTitle = "recipient.forget-confirm.title"
    // Formatted with the name about to be forgotten.
    case recipientForgetConfirmMessage = "recipient.forget-confirm.message"
    case recipientForgetConfirmButton = "recipient.forget-confirm.button"

    // Every refusal `RecipientRegistry` can give, as a fixed sentence. None
    // quotes what was refused: the registry rejects private-key-shaped text in
    // the label, the note and the recipient alike, and a refusal that echoed its
    // input would be the leak the refusal exists to prevent.
    case recipientEditorErrorEmptyLabel = "recipient.editor.error.empty-label"
    case recipientEditorErrorInvalidRecipient = "recipient.editor.error.invalid-recipient"
    case recipientEditorErrorDuplicate = "recipient.editor.error.duplicate"
    case recipientEditorErrorPrivateIdentity = "recipient.editor.error.private-identity"
    case recipientEditorErrorRecordNotFound = "recipient.editor.error.record-not-found"
    case recipientEditorErrorChangedOnDisk = "recipient.editor.error.changed-on-disk"
    case recipientEditorErrorPathEscapesProject = "recipient.editor.error.path-escapes-project"
    case recipientEditorErrorCouldNotSave = "recipient.editor.error.could-not-save"

    // MARK: Phase 2 Task 1 — CreationFailurePresenter
    //
    // One voice for `CreationPlanResolver.Error`, `SecretFileCreator.Failure`,
    // `SopsConfigGenerator.Error` and `DotEnvParseFailure` — see
    // `CreationFailurePresenter`'s own doc comment for why a single presenter
    // owns all four rather than each call site wording its own sentence.
    // `detail` itself is never a catalog key (it can carry a path or a
    // bridge diagnostic, neither of which is translatable), so only the
    // title and the recovery hint live here.

    // A generic title for the file-creation half (`CreationPlanResolver
    // .Error`, `SecretFileCreator.Failure`): both describe the same action —
    // the file was not created — so one title, distinguished by `detail`,
    // reads more honestly than inventing a different headline per case.
    case creationFailureTitle = "creation-failure.title"
    // `SopsConfigGenerator.Error` is about proposing a `.sops.yaml`, a
    // different action from creating a file — sharing `creationFailureTitle`
    // with it would claim a file creation attempt that never happened.
    case creationFailureConfigTitle = "creation-failure.config-title"
    // `DotEnvParseFailure` fires before any encryption is attempted at all.
    case creationFailureDotEnvTitle = "creation-failure.dotenv-title"
    // Phase 2 Task 6: an `.encryptedYAML` source that could not be unlocked.
    // Distinct from `creationFailureTitle` — nothing was written or refused
    // to be written here; the file being *imported* could not be opened at
    // all, a different action from creating the new one.
    case creationFailureEncryptedImportTitle = "creation-failure.encrypted-import-title"

    case creationRecoveryPickLocationAgain = "creation-failure.recovery.pick-location-again"
    case creationRecoveryCheckProjectConnected = "creation-failure.recovery.check-project-connected"
    case creationRecoveryChooseLocationInsideProject = "creation-failure.recovery.choose-location-inside-project"
    case creationRecoveryChooseAnotherName = "creation-failure.recovery.choose-another-name"
    case creationRecoveryCheckUnusualCharacters = "creation-failure.recovery.check-unusual-characters"
    case creationRecoveryAddYourKeyOrAcknowledge = "creation-failure.recovery.add-your-key-or-acknowledge"
    case creationRecoveryCheckRecipients = "creation-failure.recovery.check-recipients"
    case creationRecoveryCheckFolderPermissions = "creation-failure.recovery.check-folder-permissions"
    case creationRecoveryReencodeAsUTF8 = "creation-failure.recovery.reencode-as-utf8"
    // `CreationPlan.configUnreadable`'s recovery — added when
    // `message(forBlocking:)` joined the other four overloads.
    case creationRecoveryCheckSopsYamlSyntax = "creation-failure.recovery.check-sops-yaml-syntax"
    // `CreationFailurePresenter.message(forUnreadableSourceFile:)`'s detail
    // — added when Task 4's review found this was the third case that same
    // presenter's own doc comment predicted, alongside `forBlocking(:)` and
    // `forEmptyKeyStore(:)`. A Plain YAML/`.env` source file whose read
    // failed after `NSOpenPanel` already returned a URL for it — see that
    // method's own doc comment for why none of the four vocabularies this
    // presenter unifies already has a case for it.
    case creationFailureSourceFileUnreadable = "creation-failure.source-file-unreadable"
    // `CreationFailurePresenter.message(forEncryptedImportUnlockFailure:)`'s
    // recovery — this session's key exists but cannot open the chosen
    // `.encryptedYAML` source. See that method's own doc comment for why
    // there is no acknowledgement path out of this, unlike
    // `creationRecoveryAddYourKeyOrAcknowledge`.
    case creationRecoveryImportAKeyThatCanDecryptThisFile =
        "creation-failure.recovery.import-a-key-that-can-decrypt-this-file"

    // MARK: Phase 2 Task 3 — DotEnvPreviewTable
    //
    // What a `.env` import would actually produce, before anything is
    // written. See `DotEnvPreviewTable`'s own doc comment for why every one
    // of these exists: masking follows `SecretEditorView`'s own keys
    // (`editorRevealValue`/`editorHideValue`, reused rather than duplicated
    // below) and every `DotEnvSuspicion.Kind` gets a full sentence, not an
    // icon alone.

    case dotEnvPreviewEntriesTitle = "dotenv-preview.entries-title"
    case dotEnvPreviewSkippedTitle = "dotenv-preview.skipped-title"
    // Sits under the skipped section's title. There is deliberately no
    // per-line reason here — `DotEnvSkippedLine`'s own doc comment explains
    // why the parser does not (and should not) try to guess one — so this
    // only says what the section as a whole means and what to do about it.
    case dotEnvPreviewSkippedExplanation = "dotenv-preview.skipped-explanation"
    // Formatted with a skipped line's 1-based line number. `%d` here is a
    // line number, not a count — see the exemption this key has in
    // `LocalizationTests.countedStringsWithNoSingularCase`.
    case dotEnvPreviewSkippedLineLabel = "dotenv-preview.skipped-line-label"
    // Shown when a `.env` file produced neither an entry nor a skipped
    // line — blank lines and comments alone, or a genuinely empty file.
    case dotEnvPreviewEmpty = "dotenv-preview.empty"

    case dotEnvPreviewSuspicionStrayOpeningQuote = "dotenv-preview.suspicion.stray-opening-quote"
    case dotEnvPreviewSuspicionNotAPosixName = "dotenv-preview.suspicion.not-a-posix-name"
    case dotEnvPreviewSuspicionLooksInterpolated = "dotenv-preview.suspicion.looks-interpolated"
    case dotEnvPreviewSuspicionEmptyValue = "dotenv-preview.suspicion.empty-value"
    // Formatted with the winning entry's own line number (`%1$d`, matching
    // `DotEnvEntry.line`) and the comma-joined superseded line numbers
    // (`%2$@`, from `DotEnvSuspicion.Kind.duplicateKey(supersededLines:)`).
    // `%1$d` is that entry's own line number, not a count — same exemption
    // reasoning as `dotEnvPreviewSkippedLineLabel` above.
    case dotEnvPreviewSuspicionDuplicateKey = "dotenv-preview.suspicion.duplicate-key"

    // MARK: Phase 2 Task 4 — NewSecretFileSheet
    //
    // The wizard itself: source picker, name field, the live `ⓘ` line that
    // teaches what `.sops.yaml` decides for the typed name, and the two
    // states `NewSecretFileModel.Readiness` can put on screen —
    // `.needsAcknowledgement`'s checkbox and `.blocked`'s failure banner
    // (rendered from `CreationFailureMessage`, never worded again here).

    case newFileTitle = "new-file.title"
    case newFileSourceLabel = "new-file.source.label"
    case newFileSourceEmpty = "new-file.source.empty"
    case newFileSourcePlainYAML = "new-file.source.plain-yaml"
    case newFileSourceEncryptedYAML = "new-file.source.encrypted-yaml"
    case newFileSourceDotEnv = "new-file.source.dotenv"

    case newFileNameLabel = "new-file.name.label"
    // An example path, not a real default — the field starts empty.
    case newFileNamePlaceholder = "new-file.name.placeholder"

    // Task SOPS-38: `NewSecretFileModel.targetFormat` — derived from
    // `relativeName`'s own extension via `SopsFileFormat.forDestinationName(_:)`
    // — decides which of these renders. Two sentences rather than one
    // parameterised with a format name, matching how `.newFileInfoNoConfig`/
    // `.newFileInfoNoRuleMatched` are two separate keys rather than one: each
    // is a whole, separately translatable sentence.
    case newFileTargetFormatYAML = "new-file.target-format.yaml"
    case newFileTargetFormatDotEnv = "new-file.target-format.dotenv"
    // F2 task 5: `.json`/`.ini` are now reachable from `forDestinationName`
    // too — see `NewSecretFileSheet.targetFormatText(for:)`'s own doc
    // comment for why these two used to render `nil`.
    case newFileTargetFormatJSON = "new-file.target-format.json"
    case newFileTargetFormatINI = "new-file.target-format.ini"

    // The `ⓘ` line's shapes: one per `CreationPlan` case, plus resolving.
    // `.unsupportedRule`/`.configUnreadable` reuse `CreationFailurePresenter
    // .message(forBlocking:)`'s own sentence rather than getting a key here —
    // see `NewSecretFileSheet.infoLineText`.
    case newFileInfoResolving = "new-file.info.resolving"
    // Formatted with the comma-joined recipient names/keys this plan would
    // encrypt for — see `NewSecretFileSheet.recipientNames(_:)`.
    case newFileInfoGovernedByRule = "new-file.info.governed-by-rule"
    case newFileInfoNoConfig = "new-file.info.no-config"
    case newFileInfoNoRuleMatched = "new-file.info.no-rule-matched"
    // Formatted with the matching rule's own `encrypted_regex`, shown
    // whenever it is set — appended to the ⓘ line for *every* source, and
    // repeated under the encrypted-import diff.
    //
    // `CreationPlanResolver` passes `encrypted_regex` through as supported
    // while refusing the other three scoping fields (see its own doc
    // comment, decision order step 5), so a file created under such a rule
    // stores every non-matching value in **plaintext** — and until this
    // sentence existed, the one screen whose entire purpose is disclosing
    // how access changes said only who could read the file, never that most
    // of it would not be encrypted at all. Spec §4.1 decision 4 is "do not
    // change access silently"; a wizard that creates files is where that
    // lands.
    //
    // Deliberately does **not** claim which fields will be plaintext: this
    // app never evaluates the expression (sops does, at write time), so the
    // sentence describes what the rule *does* and asks the user to check it,
    // which is true without this app having to predict sops's own matching.
    case newFileInfoEncryptedRegexScoping = "new-file.info.encrypted-regex-scoping"

    case newFileAcknowledgeUnreadableCheckbox = "new-file.acknowledge-unreadable-checkbox"

    case newFileChooseFileButton = "new-file.choose-file-button"
    case newFileNoFileChosen = "new-file.no-file-chosen"
    // Formatted with the chosen file's name only — never its full path,
    // which is not a secret but also not needed to identify what was picked.
    case newFileFileChosen = "new-file.file-chosen"
    // A Plain YAML source loaded before this view existed (every
    // `CreateFromSourceTests` fixture, and Task 6/7's presented sheets) has
    // no filename to show — `NewSecretFileModel` deliberately never carries
    // a path, only the content. Confirms a file is loaded without naming
    // one it does not have.
    case newFileFileChosenNoName = "new-file.file-chosen-no-name"

    case newFileEmptyPreviewNote = "new-file.empty-preview-note"
    case newFileCreateButton = "new-file.create-button"

    // MARK: Phase 2 Task 5 — RecipientPicker

    // Shown when `NewSecretFileModel.plan` is `.noConfig` or
    // `.noRuleMatched` — neither is a failure, and this is the way out
    // phase 1 deliberately left open rather than inventing recipients in
    // the resolver. See `RecipientPicker`'s own doc comment.
    case recipientPickerTitle = "recipient-picker.title"
    case recipientPickerExplanationNoConfig = "recipient-picker.explanation.no-config"
    case recipientPickerExplanationNoRuleMatched = "recipient-picker.explanation.no-rule-matched"
    case recipientPickerNoneChosen = "recipient-picker.none-chosen"
    // Heading over the registry's own recipients not yet chosen — a
    // convenience for adding a known key with one tap, never a source of
    // recipients the picker invents on its own.
    case recipientPickerKnownRecipientsTitle = "recipient-picker.known-recipients-title"
    // The add field's two shape refusals. Its own sentences rather than
    // `recipientEditorError{PrivateIdentity,InvalidRecipient}`, which the
    // *rule* is shared with (`RecipientRegistry.refusal(forAgeRecipient:)` —
    // one check, no drift): those two are written for the label editor and
    // say "nothing private-key-shaped is written to this file … Nothing was
    // saved", which here names the wrong file (nothing is written to
    // `.sops-gui/recipients.json` on this screen; the file at stake is
    // `.sops.yaml`) and the wrong action (nothing was being saved). Sharing
    // validation is right; sharing wording was not.
    //
    // Neither sentence ever quotes what was typed — see
    // `RecipientPicker.refusalMessage(_:)`.
    case recipientPickerErrorPrivateIdentity = "recipient-picker.error.private-identity"
    case recipientPickerErrorInvalidRecipient = "recipient-picker.error.invalid-recipient"
    case recipientPickerProposeButton = "recipient-picker.propose-button"
    case recipientPickerWriteButton = "recipient-picker.write-button"
    case recipientPickerProposalHeading = "recipient-picker.proposal-heading"
    case recipientPickerWriteSuccess = "recipient-picker.write-success"

    // MARK: Phase 2 Task 6 — EncryptedImportPreview
    //
    // Unlocking an `.encryptedYAML` source and disclosing exactly who gains
    // and loses access by re-encrypting it for the target plan's recipients
    // — spec §4.1, decision 4. See `EncryptedImportPreview`'s own doc
    // comment: the language deliberately matches `ProjectAccessView`'s own
    // "gains"/"loses" sentences (`projectAccessConfigGains`/`.Loses`), even
    // though this is a different action (importing one file, not rewriting
    // a creation rule) and so gets its own keys rather than reusing theirs.

    case newFileEncryptedImportUnlockingLabel = "new-file.encrypted-import.unlocking"
    // Shown for `.unlockedAwaitingPlan` — decrypted, but
    // `currentGovernedPlan()` has no recipient set to diff against yet, so
    // there is nothing honest to diff. See `NewSecretFileModel
    // .encryptedImport`'s own doc comment, "The diff needs a known target,
    // not just a decrypted file", for the review finding this state (and
    // this sentence) exist to close. States the fact only, deliberately not
    // an instruction — see `EncryptedImportPreview`'s own doc comment on its
    // `.unlockedAwaitingPlan` branch for why a second review round removed
    // "Choose a name…": that wording presumed a fix that does not apply to
    // every cause this state merges, and `NewSecretFileSheet` already
    // renders the real explanation for those directly above this sentence.
    //
    // Deliberately worded around *recipients*, not the *destination* — a
    // third review round found "no destination decided yet" false for three
    // of the six causes this state now merges (`.unsupportedRule`,
    // `.configUnreadable`, a matched rule naming no recipients at all): the
    // name is typed, the rule matched, the destination genuinely *is*
    // decided in all three. What is actually missing, in every one of the
    // six, is a usable recipient set — the one thing `currentGovernedPlan()`
    // returning `nil` always and only means, by construction, so this
    // phrasing is true for all six without `EncryptedImportPreview` ever
    // needing to inspect *which* of them it is.
    case newFileEncryptedImportAwaitingPlanLabel = "new-file.encrypted-import.awaiting-plan"
    // The diff's title when `gaining`/`losing` are not both empty.
    case newFileEncryptedImportDiffTitle = "new-file.encrypted-import.diff-title"
    // The diff's title when `gaining` and `losing` are both empty — every
    // source recipient survives into the target unchanged. Its own sentence
    // rather than reusing `newFileEncryptedImportDiffTitle`: that one
    // asserts a change, which is false here, and a headline contradicting
    // the body underneath it is worse than no headline at all.
    case newFileEncryptedImportNoChangeTitle = "new-file.encrypted-import.no-change-title"
    // Each formatted with the comma-joined recipient names/keys this half of
    // the diff names — the same `RecipientRegistry` lookup, falling back to
    // `NewSecretFileSheet.shortenedKey(_:)`, that the ⓘ line and
    // `RecipientPicker` already use. Never a count, so none of these needs a
    // plural split — see `LocalizationTests.countedStringsPluralize`.
    case newFileEncryptedImportGains = "new-file.encrypted-import.gains"
    // Names both that the *new* file will not be readable by these
    // recipients and that the *source* file is untouched — the same
    // clarification `project-access.update-config-confirm.loses` makes for
    // the identical shape of possible misreading. See
    // `EncryptedImportPreview`'s own doc comment, "What 'this file' means,
    // and why the filename stays on screen".
    case newFileEncryptedImportLoses = "new-file.encrypted-import.loses"
    case newFileEncryptedImportKeeps = "new-file.encrypted-import.keeps"

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
