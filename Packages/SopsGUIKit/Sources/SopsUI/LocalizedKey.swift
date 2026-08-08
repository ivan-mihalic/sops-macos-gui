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
    case keyImportLegacyButton = "key.import.legacy-button"
    case keyImportLegacyFooter = "key.import.legacy-footer"
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
    case keyErrorReadFailed = "key.error.read-failed"

    case actionBack = "action.back"
    case actionContinue = "action.continue"
    case actionDone = "action.done"
    case actionRunSetupCheck = "action.run-setup-check"
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
    case projectsErrorRemoveFailed = "projects.error.remove-failed"

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
