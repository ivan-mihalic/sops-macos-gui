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
/// ## The `.governedByRule` headline generalizes the probe answer
///
/// The mirror image of the finding above, caught one review round later:
/// hardening `.noRuleMatched` alone left `.governedByRule` making the
/// identical mistake in the other direction. `NewSecretFileSheet
/// .governedByRuleSentence`'s sentence says "A rule in .sops.yaml governs
/// **this location**" — true, and fine where that function's other caller
/// shows it, directly under the filename field in `NewSecretFileSheet`
/// itself, where "this location" has an obvious referent one field above.
/// On this screen there is no filename anywhere, and the sentence is the
/// only headline on an otherwise empty pane — rendered at
/// `.title3.weight(.semibold)`, it reads as a statement about the project,
/// not about one unlabeled probe path at its root.
///
/// Concretely: a `.sops.yaml` with `path_regex: ^secrets/` naming one key
/// and a catch-all `path_regex: .*` naming another means an empty project
/// shows "…it will be encrypted for: Alice" (the catch-all rule, the only
/// one the root probe reaches) — and a file the user then names
/// `secrets/db.yaml` is actually encrypted for Bob. The sentence was true
/// of a path the user cannot see and false under the reading the screen
/// invites. Not Critical, because the wizard's own ⓘ line re-resolves
/// against the real filename before anything is written, so no
/// wrongly-encrypted file results — but exactly the distinction
/// `FileListModel.configState`'s own doc comment says anything rendering
/// this value must keep.
///
/// `LocalizedKey.startHereProbeLocation` closes it: one additive sentence,
/// appended to both the `.governedByRule` headline and the `.noRuleMatched`
/// one (which had the same gap only partly covered — its reassurance makes
/// location salient, "files created in a **different** location", without
/// ever naming *this* one either), the same appended-not-merged technique
/// `startHereNoRuleMatchedReassurance` already established for this screen.
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
/// - `.governedByRule` — a rule already reaches this location: the whole
///   sentence — who it will be encrypted for, plus, when the rule sets
///   `encrypted_regex`, the disclosure that it also scopes which values get
///   encrypted at all — comes from `NewSecretFileSheet
///   .governedByRuleSentence(recipients:encryptedRegex:recipientNames:)`,
///   called directly rather than reimplemented. That function's own doc
///   comment has the full account, including why it is a function call and
///   not merely a shared pair of keys: an earlier version of this file
///   re-derived the same guard-and-join independently and silently dropped
///   the `encrypted_regex` disclosure entirely (this task's review, "the
///   silent half of an access change" applies here exactly as it does one
///   screen over — spec §4.1 decision 4). Recipients are named with a
///   registry label when `RecipientRegistry.load(in: projectRoot)` has one,
///   the shortened public key otherwise — see `recipientNames(_:)`. A rule
///   that matches but names no recipients at all is a real, sops-admitted
///   shape (`CreationPlanResolverTests
///   .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients`), not a
///   hypothetical this file is padding out — `presentation(for:
///   recipientNames:)` falls through to `CreationFailurePresenter
///   .messageForRuleWithNoRecipients()` for it instead of calling
///   `governedByRuleSentence` at all, the identical guard
///   `NewSecretFileSheet.infoLineText` already holds one screen over.
///   Appended after that sentence: `LocalizedKey.startHereProbeLocation`,
///   naming the location "this location" refers to — see "The
///   `.governedByRule` headline generalizes the probe answer" above for why
///   this screen needs it and the wizard's own ⓘ line does not.
/// - `.noRuleMatched` — `LocalizedKey.newFileInfoNoRuleMatched` ("No rule in
///   .sops.yaml matches this location yet.") — the wizard's own careful
///   wording for this exact `CreationPlan` case, reused rather than
///   reworded — plus two sentences this screen alone needs, in order:
///   `LocalizedKey.startHereProbeLocation` (see above), and
///   `LocalizedKey.startHereNoRuleMatchedReassurance`: the wizard's ⓘ line
///   sits directly above `RecipientPicker`'s own explanation and a working
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
///   complete scan that found nothing) is true, and the common way it
///   happens is entirely ordinary, not exotic: `FileListModel` starts every
///   instance with `configState = nil`, and `FileListView.swift:189`'s own
///   `.task(id:)` runs `refresh()` only *after* the first body evaluation —
///   so every project selection renders this `nil` branch for one frame
///   before `refresh()` has resolved anything at all. Separately from that,
///   `FileListModel.resolveConfigState` can also return `nil` on a setup
///   failure that `ProjectScanner.scan(root:)`'s own `rootMissing` check
///   does not independently catch — concretely, `projectRoot` being removed
///   in the narrow window between the scan completing and the probe's own
///   existence check, a real (if rare) TOCTOU race, not a hypothetical, but
///   the rarer of the two paths here, not the only one.
///   When either happens this pane renders blank rather than any sentence.
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
    /// as cheap.
    ///
    /// Measured directly against this app's own headless snapshot tool
    /// (`./Scripts/snapshots.sh`): a `.task`-based version of this property
    /// was still empty by the time the rendered PNG was captured — the
    /// `start-here-governed-by-rule` snapshot showed a shortened key
    /// instead of the registry label it was built to prove. The likely
    /// mechanism, not fully confirmed: `Snapshot.swift`'s render path never
    /// orders its window front (`window.setIsVisible(false)`, never
    /// `orderFront`/`makeKeyAndOrderFront` — see that file's own doc
    /// comment, "Why this, and not a screenshot of the running app"), so no
    /// appear event may ever reach this view to start a `.task` closure at
    /// all — it is not that the closure started and lost a race.
    /// (`Snapshot.swift` does give AppKit a deliberate pause,
    /// `RunLoop.current.run(until:)` after the first `layoutSubtreeIfNeeded()`
    /// — real, and enough for `List`/`Form` content to populate — but
    /// `displayIfNeeded()` is never called anywhere in that path, and a
    /// pumped run loop does not help a task that was never scheduled to
    /// begin with.) Whatever the exact mechanism, a `let` set at `init`
    /// sidesteps the entire class of "may not have run yet under a
    /// synchronous headless render" rather than working around one
    /// instance of it — and, separately from snapshots, it also fixes a
    /// staleness `.task` would have kept: that modifier runs once per view
    /// *identity*, so a `projectRoot` change on an otherwise-identical
    /// `ProjectStartHereView` would not have re-triggered it.
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
        VStack(spacing: 12) {
            if let configState {
                let presentation = Self.presentation(for: configState, recipientNames: recipientNames)
                Image(systemName: Self.iconName(for: presentation))
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)

                presentationBody(presentation)
            }
            // `configState == nil`: nothing shown above. See this type's
            // own doc comment, "What each of the five configState values
            // shows" — the `nil` paragraph in particular for why this can
            // still happen once `FileListView.showsStartHere` is already
            // true.

            // `otherFormatCount`'s footnote (`FileListView.footnotes`) is
            // suppressed for the branch that shows this view — see
            // `FileListView.footnotes`'s own comment — so this is the one
            // place that count is surfaced while this view is on screen.
            // Reuses `files.other-format.note` rather than a second key
            // with the same fact: the sentence is identical regardless of
            // which screen shows it.
            //
            // Deliberately *not* nested inside `if let configState` above
            // (a review finding on this branch): `FileListView.footnotes`'s
            // own guard is `otherFormatCount > 0 && !showsStartHere` —
            // unconditional on `configState` — so nesting this block inside
            // `if let configState` meant a `configState == nil` render (the
            // `nil` paragraph above) made both guards false at once and the
            // disclosure vanished with nothing showing it anywhere. Sibling
            // to the `if let` now, so the two guards cannot disagree.
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
            // The whole sentence, including the `encrypted_regex`
            // disclosure when the rule sets one, comes from
            // `NewSecretFileSheet.governedByRuleSentence(recipients:
            // encryptedRegex:recipientNames:)` — called directly, not
            // reimplemented. See that function's own doc comment for why
            // this is a function call rather than a second copy of its
            // guard-and-join.
            let sentence = NewSecretFileSheet.governedByRuleSentence(
                recipients: recipients, encryptedRegex: encryptedRegex, recipientNames: recipientNames)
            // `sentence` says "this location", the identical wording the
            // wizard's own ⓘ line uses — fine there, sitting directly under
            // the filename field the user just typed, but this screen has
            // no filename anywhere for "this location" to refer back to.
            // `startHereProbeLocation` names it, the same additive-key
            // pattern `.noRuleMatched` below already uses. See this type's
            // own doc comment, "the `.governedByRule` headline generalizes
            // the probe answer", for the failure this closes.
            let text = sentence + " " + LocalizedKey.startHereProbeLocation.text
            return .headline(text, offersCreateButton: true)
        case .noConfig:
            return .headline(LocalizedKey.newFileInfoNoConfig.text, offersCreateButton: true)
        case .noRuleMatched:
            // Three whole catalog sentences, joined with a literal `" "` —
            // composition, not assembly from fragments, the same technique
            // (and the same reasoning) `NewSecretFileSheet
            // .governedByRuleSentence`'s own doc comment names for its own
            // join. See this type's own doc comment for why this state
            // needs the second and third sentences the wizard's identical
            // first one does not: `matched` already says "this location"
            // without saying what it is (fine one screen over, where the
            // filename field gives it a referent; not fine here), and
            // `reassurance` talks about "a different location" without
            // ever naming *this* one either. `startHereProbeLocation`
            // names it, once, for both.
            let matched = LocalizedKey.newFileInfoNoRuleMatched.text
            let location = LocalizedKey.startHereProbeLocation.text
            let reassurance = LocalizedKey.startHereNoRuleMatchedReassurance.text
            return .headline(matched + " " + location + " " + reassurance, offersCreateButton: false)
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
    /// name. The identical *fallback rule* `RecipientPicker
    /// .displayName(for:)` and `NewSecretFileSheet.recipientNames(_:)` each
    /// keep, so an unlabeled key reads the same way on this screen as it
    /// does one click later in the wizard — not shared code, unlike
    /// `governedByRuleSentence` above: each of those three methods reads
    /// its own view's own `registryRecords`, so there is no instance-free
    /// version of this specific lookup to extract, only the leaf
    /// `NewSecretFileSheet.shortenedKey(_:)` it falls back to, which all
    /// three do already call rather than reimplement.
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
            // `.fixedSize` matters here specifically: `.governedByRule`'s
            // text can carry the `encrypted_regex` disclosure appended
            // (`NewSecretFileSheet.governedByRuleSentence`'s own three-clause
            // sentence, ~250 characters combined) — the review's own
            // finding that this state was the one new output nothing had
            // rendered and looked at (see `Catalog.swift`'s
            // `start-here-governed-by-rule-with-scoping` snapshot).
            Text(text)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
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
