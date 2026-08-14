import SopsProjects
import SwiftUI

/// The guidance an empty project shows instead of a dead end: what
/// `FileListView` renders in place of `statusPlaceholder`'s "No encrypted
/// files found in this project." once a *complete* scan has found nothing
/// to list and `FileListModel.configState` (Task 1) is ready to say why —
/// and, where this app can, what to do about it.
///
/// ## Why `configState`, not a guess from `otherFormatCount` alone
///
/// `configState` answers "what governs a file created right now at the
/// project root" — see `FileListModel.configState`'s own doc comment for the
/// probe substitution this rests on, and in particular why `.noRuleMatched`
/// means "a rule exists but does not reach this location", never "this
/// project has no usable config". This view keeps that distinction on
/// screen: collapsing the two into one "nothing here" sentence would be
/// exactly the confident-but-wrong claim `ProjectScanner`/
/// `ProjectScopeAccountant` exist elsewhere in this app to prevent — and
/// `configState`'s own doc comment calls this view out by name as the place
/// that must not make it.
///
/// ## What each of the five `configState` values shows
///
/// - `.noConfig` — no `.sops.yaml` at all: a plain statement of that fact,
///   plus a button that opens the wizard, which already knows how to
///   propose a brand-new config (`RecipientPicker`'s `.noConfig` branch).
///   Not phrased as a defect — `CreationPlan.noConfig`'s own doc comment
///   treats it as a legitimate starting point.
/// - `.governedByRule` — a rule already reaches this location: named by its
///   own recipients, shortened the same way every other unlabeled-key
///   surface in this app does (`NewSecretFileSheet.shortenedKey(_:)`). This
///   view has no project root to resolve a registry label against — see
///   `recipientNames(_:)` — so it never invents one, and never looks one
///   up either. A rule that matches but names no recipients at all is a
///   real, sops-admitted shape (`CreationPlanResolverTests
///   .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients`), not a
///   hypothetical this file is padding out — `presentation(for:
///   recipientNames:)` falls through to `CreationFailurePresenter
///   .messageForRuleWithNoRecipients()` for it instead of claiming an
///   encryption that will not happen, the identical guard
///   `NewSecretFileSheet.infoLineText` already holds one screen over.
/// - `.noRuleMatched` — says plainly that rules exist but do not reach this
///   location, and that this is not an error (`CreationPlanResolver`'s own
///   doc comment: a caller here "is expected to fall back to a manual
///   recipient picker rather than invent one here"). No button: the
///   toolbar "+" above this view (`FileListView.toolbar`) is always present
///   regardless of which of these five states is showing, so nothing is
///   out of reach — this state's whole job is explaining why the
///   rule-driven language the other two states use does not apply here.
/// - `.configUnreadable`/`.unsupportedRule` — both are blocking, and
///   `CreationFailurePresenter.message(forBlocking:)` already composes the
///   whole sentence for them. This view renders that message verbatim —
///   title, detail and recovery — and composes nothing of its own for
///   either case. See that function's own doc comment for why
///   `.noConfig`/`.noRuleMatched` are deliberately excluded from it.
/// - `nil` — `FileListModel.refresh()` has not resolved `configState` yet
///   (or has not run at all). Nothing extra is shown: there is nothing
///   dishonest to say yet, and nothing true to say either.
///
/// ## What this view never does
///
/// No model construction, no `.sops.yaml` resolution, no file I/O — this is
/// purely a renderer of a `CreationPlan?` the caller already resolved.
/// `onNewFile` is a closure the caller supplies, the same shape
/// `FileListView`'s own toolbar "+" already uses (`AppShell
/// .makeNewFileModel(projectRoot:keyStore:)` is what actually builds a
/// wizard); this view never builds one itself.
public struct ProjectStartHereView: View {
    private let configState: CreationPlan?
    private let otherFormatCount: Int
    private let onNewFile: () -> Void

    public init(configState: CreationPlan?, otherFormatCount: Int, onNewFile: @escaping () -> Void) {
        self.configState = configState
        self.otherFormatCount = otherFormatCount
        self.onNewFile = onNewFile
    }

    public var body: some View {
        if let configState {
            let presentation = Self.presentation(for: configState, recipientNames: Self.recipientNames)
            VStack(spacing: 12) {
                Image(systemName: Self.iconName(for: presentation))
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                presentationBody(presentation)

                // `otherFormatCount`'s footnote (`FileListView.footnotes`)
                // is suppressed for the branch that shows this view — see
                // `FileListView.footnotes`'s own comment — so this is the
                // one place that count is surfaced while this view is on
                // screen. Reuses `files.other-format.note` rather than a
                // second key with the same fact: the sentence is identical
                // regardless of which screen shows it.
                if otherFormatCount > 0 {
                    Text(String(format: LocalizedKey.filesOtherFormatNote.text, otherFormatCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // `configState == nil`: nothing extra. `FileListView` still renders
        // its own toolbar and (empty) list around wherever this view sits;
        // this body contributes nothing until the model actually knows.
    }

    // MARK: - What to show, decided once

    /// One state's whole message, decided independently of any view so it
    /// can be tested without rendering anything — the same shape
    /// `NewSecretFileSheet.infoLineText` already established for the
    /// identical family of decisions.
    enum Presentation: Equatable {
        /// A headline, plus whether the "create first file" button applies.
        /// `Bool` rather than a separate case per this type's own doc
        /// comment, "What each of the five `configState` values shows" —
        /// `.noConfig` and `.governedByRule` share this shape and differ
        /// only in that one flag.
        case headline(String, offersCreateButton: Bool)
        /// A blocking `CreationFailureMessage`, rendered verbatim — see
        /// this type's own doc comment, "What this view never does": no
        /// sentence here is composed from a `reason` string directly.
        case failure(CreationFailureMessage)
    }

    /// Decision order matches `CreationPlan`'s own case order; no `default`
    /// — a case added to `CreationPlan` later must fail this file's build
    /// rather than silently show nothing, the same discipline
    /// `CreationFailurePresenter`'s own switches document for themselves.
    static func presentation(
        for plan: CreationPlan, recipientNames: ([String]) -> String
    ) -> Presentation {
        switch plan {
        case .governedByRule(let recipients, _):
            guard !recipients.isEmpty else {
                return .failure(CreationFailurePresenter.messageForRuleWithNoRecipients())
            }
            return .headline(
                String(format: LocalizedKey.startHereGovernedTitle.text, recipientNames(recipients)),
                offersCreateButton: true)
        case .noConfig:
            return .headline(LocalizedKey.startHereNoConfigTitle.text, offersCreateButton: true)
        case .noRuleMatched:
            return .headline(LocalizedKey.startHereNoRuleMatchedTitle.text, offersCreateButton: false)
        case .configUnreadable, .unsupportedRule:
            // `message(forBlocking:)` is documented to answer for exactly
            // these two cases; the fallback is unreachable today and exists
            // only so a future contract break fails as a wrong sentence
            // rather than a crash — see
            // `CreationFailurePresenter.messageForUnexpectedlyUnblockedPlan()`'s
            // own doc comment.
            let message = CreationFailurePresenter.message(forBlocking: plan)
                ?? CreationFailurePresenter.messageForUnexpectedlyUnblockedPlan()
            return .failure(message)
        }
    }

    /// Every recipient's public key, shortened — never an invented name,
    /// and never a registry label either: unlike `RecipientPicker
    /// .displayName(for:)` or `NewSecretFileSheet.recipientNames(_:)`, this
    /// view has no `projectRoot` to load `RecipientRegistry` against (see
    /// this type's own `init`), so there is nothing here to look a label up
    /// in. The fallback is identical to theirs regardless, so an unlabeled
    /// key still reads the same way everywhere in this app.
    private static func recipientNames(_ recipients: [String]) -> String {
        recipients.map(NewSecretFileSheet.shortenedKey).joined(separator: ", ")
    }

    private static func iconName(for presentation: Presentation) -> String {
        switch presentation {
        case .headline: return "doc.badge.plus"
        case .failure: return "exclamationmark.triangle"
        }
    }

    @ViewBuilder
    private func presentationBody(_ presentation: Presentation) -> some View {
        switch presentation {
        case .headline(let text, let offersCreateButton):
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            if offersCreateButton {
                Button(LocalizedKey.startHereCreateFirstFileButton.text, action: onNewFile)
            }
        case .failure(let message):
            // Mirrors `NewSecretFileSheet.failureBanner(_:)`'s own reading
            // order (title, then detail, then recovery) — the same message
            // type, so the same shape reads consistently wherever it
            // appears.
            Text(message.title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            // Plain-`String` overload, not `LocalizedStringKey` — `detail`
            // may carry a path or the bridge's own diagnostic and must
            // never be looked up in the catalog. See `CreationFailureMessage
            // .detail`'s own doc comment.
            Text(message.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let recovery = message.recovery {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
