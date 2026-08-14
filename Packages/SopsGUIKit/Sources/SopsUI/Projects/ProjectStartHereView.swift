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
/// means "no rule reaches *this* location", never "this project has no
/// usable config" and never "no rule exists at all". This view keeps that
/// distinction on screen: collapsing it into one "nothing here" sentence
/// would be exactly the confident-but-wrong claim `ProjectScanner`/
/// `ProjectScopeAccountant` exist elsewhere in this app to prevent — and
/// `configState`'s own doc comment calls this view out by name as the place
/// that must not make it.
///
/// A first pass here got this half right: it never said "no config" for
/// `.noRuleMatched`, but its second sentence claimed the project's rules
/// "already" exist (false when `.sops.yaml` has no `creation_rules` key at
/// all — `CreationPlanResolver.plan`'s own doc comment, decision order step
/// 3, and `CreationRuleLookup.matched`) and predicted every file here would
/// need hand-picked recipients (false for the exact fixture Task 1 wrote to
/// pin this distinction, `FileListModelConfigStateTests
/// .noRuleMatchedFixture`: a rule scoped to `path_regex: ^secrets/` still
/// governs every file created under `secrets/`, automatically, the moment
/// this app's own wizard resolves a target there). Both false claims came
/// from generalizing what the probe answer supports — "no rule governs a
/// new file *at the project root*" — into a claim about the whole project.
/// `presentation(for:recipientNames:)`'s `.noRuleMatched` arm now stays
/// inside what the probe actually proves.
///
/// ## What each of the five `configState` values shows
///
/// - `.noConfig` — no `.sops.yaml` at all: `LocalizedKey.newFileInfoNoConfig`
///   verbatim (the identical sentence `NewSecretFileSheet`'s own ⓘ line
///   shows for the same `CreationPlan` case — reused rather than a
///   near-duplicate catalog entry with the same fact in slightly different
///   words), plus a button that opens the wizard, which already knows how
///   to propose a brand-new config (`RecipientPicker`'s `.noConfig`
///   branch). Not phrased as a defect — `CreationPlan.noConfig`'s own doc
///   comment treats it as a legitimate starting point.
/// - `.governedByRule` — a rule already reaches this location:
///   `LocalizedKey.newFileInfoGovernedByRule`, named by its own recipients
///   (a registry label when `RecipientRegistry.load(in: projectRoot)` has
///   one, the shortened public key otherwise — see `recipientNames(_:)`),
///   with `LocalizedKey.newFileInfoEncryptedRegexScoping` appended whenever
///   the rule sets `encrypted_regex`. Both keys, and the append-on-scoping
///   behavior, are reused verbatim from `NewSecretFileSheet.infoLineText`
///   rather than reimplemented: that function's own doc comment states why
///   the disclosure exists ("Naming only who can read the file, and saying
///   nothing about how much of it is encrypted, is the silent half of an
///   access change — spec §4.1 decision 4") and the reason applies
///   identically here — this screen's "Ready" framing would otherwise
///   assert a completeness the wizard, one click later, has to walk back.
///   A rule that matches but names no recipients at all is a real,
///   sops-admitted shape (`CreationPlanResolverTests
///   .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients`), not a
///   hypothetical this file is padding out — `presentation(for:
///   recipientNames:)` falls through to `CreationFailurePresenter
///   .messageForRuleWithNoRecipients()` for it instead of claiming an
///   encryption that will not happen, the identical guard
///   `NewSecretFileSheet.infoLineText` already holds one screen over.
/// - `.noRuleMatched` — `LocalizedKey.newFileInfoNoRuleMatched` ("No rule in
///   .sops.yaml matches this location yet.") — the wizard's own careful
///   wording for this exact `CreationPlan` case, reused rather than
///   reworded — plus `LocalizedKey.startHereNoRuleMatchedReassurance`, a
///   second sentence this screen alone needs: the wizard's ⓘ line sits
///   directly above `RecipientPicker`'s own explanation and a working
///   manual-recipient flow, so nothing there has to say "this isn't an
///   error" out loud. This screen has no such context to lean on, so it
///   says so directly — carefully hedged ("may still cover", never "does")
///   so it holds regardless of whether `.sops.yaml` has any rules at all.
///   No button: the toolbar "+" above this view (`FileListView.toolbar`) is
///   always present regardless of which of these five states is showing,
///   so nothing is out of reach — this state's whole job is explaining why
///   the rule-driven language the other two states use does not apply
///   here.
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
///   This is reachable even once `FileListView`'s `showsStartHere` (a
///   complete scan that found nothing) is true: `FileListModel
///   .resolveConfigState` can itself return `nil` on a setup failure that
///   `ProjectScanner.scan(root:)`'s own `rootMissing` check does not
///   independently catch — concretely, `projectRoot` being removed in the
///   narrow window between the scan completing and the probe's own
///   existence check, a real (if rare) TOCTOU race, not a hypothetical.
///   When that happens this pane renders blank rather than any sentence.
///   That is an accepted, honest gap — there is genuinely nothing true this
///   view can say about a `configState` it does not have — not a silently
///   reintroduced version of the claim this whole file exists to avoid; see
///   `FileListView.showsStartHere`'s own doc comment for the same note from
///   the caller's side.
///
/// ## What this view never does
///
/// No model construction, no `.sops.yaml` resolution, no file write — this
/// is purely a renderer of a `CreationPlan?` the caller already resolved.
/// `onNewFile` is a closure the caller supplies, the same shape
/// `FileListView`'s own toolbar "+" already uses (`AppShell
/// .makeNewFileModel(projectRoot:keyStore:)` is what actually builds a
/// wizard); this view never builds one itself. `projectRoot` is read for
/// exactly one purpose — `RecipientRegistry.load(in:)`, the same
/// non-throwing, best-effort read `RecipientPicker`/`NewSecretFileSheet`
/// already perform — never for a scan, a config resolve, or anything else.
public struct ProjectStartHereView: View {
    private let configState: CreationPlan?
    private let otherFormatCount: Int
    private let projectRoot: URL
    private let onNewFile: () -> Void

    /// Registry labels for this project's recipients, read once at
    /// construction — never thrown, and left empty if the registry cannot
    /// be read at all — the same contract `RecipientPicker`'s own registry
    /// load and `ProjectAccessModel.loadRegistry`'s default both keep: a
    /// registry this view cannot read degrades to "no labels", never to
    /// hiding a recipient the config itself names.
    ///
    /// Read eagerly here rather than via `.task` (`RecipientPicker`'s own
    /// pattern, tried first): `RecipientRegistry.load(in:)` is a plain
    /// synchronous `throws` function, not `async` — there is no real
    /// asynchrony to defer to a task in the first place, only file I/O
    /// small enough that `RecipientPicker`'s own `.task` already treats it
    /// as cheap. Measured directly against this app's own headless snapshot
    /// tool (`./Scripts/snapshots.sh`, whose technique is documented in
    /// CLAUDE.md, "Visual verification"): a `.task`-based version of this
    /// property was still empty by the time the rendered PNG was captured —
    /// `NSHostingView.layoutSubtreeIfNeeded()`/`displayIfNeeded()` do not
    /// pump a `Task` to completion, and this file's own snapshot
    /// (`start-here-governed-by-rule`) showed a shortened key instead of
    /// the registry label it was built to prove. A `let` set at `init`
    /// sidesteps the whole class of "stale during a synchronous headless
    /// render" bug rather than working around it per call site.
    private let registryRecords: [RecipientRecord]

    public init(
        configState: CreationPlan?, otherFormatCount: Int, projectRoot: URL,
        onNewFile: @escaping () -> Void
    ) {
        self.configState = configState
        self.otherFormatCount = otherFormatCount
        self.projectRoot = projectRoot
        self.onNewFile = onNewFile
        self.registryRecords = (try? RecipientRegistry.load(in: projectRoot)) ?? []
    }

    public var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        if let configState {
            let presentation = Self.presentation(for: configState, recipientNames: recipientNames)
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
        // `configState == nil`: nothing extra. See this type's own doc
        // comment, "What each of the five configState values shows" — the
        // `nil` paragraph in particular for why this can still happen once
        // `FileListView.showsStartHere` is already true.
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
        case .governedByRule(let recipients, let encryptedRegex):
            guard !recipients.isEmpty else {
                return .failure(CreationFailurePresenter.messageForRuleWithNoRecipients())
            }
            let governed = String(format: LocalizedKey.newFileInfoGovernedByRule.text, recipientNames(recipients))
            // `encrypted_regex` disclosure, reused verbatim from
            // `NewSecretFileSheet.infoLineText` — see this type's own doc
            // comment, "What each of the five configState values shows",
            // for why it belongs here too. Joined with a literal `" "`,
            // the one instance of composing two whole catalog sentences —
            // `infoLineText` names this same choice in its own comment for
            // the identical join.
            guard !encryptedRegex.isEmpty else {
                return .headline(governed, offersCreateButton: true)
            }
            let scoping = String(format: LocalizedKey.newFileInfoEncryptedRegexScoping.text, encryptedRegex)
            return .headline(governed + " " + scoping, offersCreateButton: true)
        case .noConfig:
            return .headline(LocalizedKey.newFileInfoNoConfig.text, offersCreateButton: true)
        case .noRuleMatched:
            // Two whole catalog sentences, joined the same way the
            // `.governedByRule` arm above joins its own two — see this
            // type's own doc comment for why this state needs a second
            // sentence the wizard's identical first one does not.
            let matched = LocalizedKey.newFileInfoNoRuleMatched.text
            let reassurance = LocalizedKey.startHereNoRuleMatchedReassurance.text
            return .headline(matched + " " + reassurance, offersCreateButton: false)
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

    /// `recipient`'s registry label when `registryRecords` has one,
    /// otherwise the public key itself, shortened — never an invented
    /// name. Identical fallback to `RecipientPicker.displayName(for:)` and
    /// `NewSecretFileSheet.recipientNames(_:)`, so an unlabeled key reads
    /// the same way on this screen as it does one click later in the
    /// wizard.
    private func recipientNames(_ recipients: [String]) -> String {
        recipients.map { recipient in
            registryRecords.first { $0.ageRecipient == recipient }?.label ?? NewSecretFileSheet.shortenedKey(recipient)
        }.joined(separator: ", ")
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
