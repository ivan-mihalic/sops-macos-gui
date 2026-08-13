import Foundation
import Observation
import SopsEngine
import SopsHealth
import SopsProjects

/// The new-file wizard's whole brain: what a not-yet-created secret file
/// would be governed by, whether creating it can proceed right now, and —
/// once the user asks — actually creating it. `NewSecretFileSheet` (Task 4)
/// only renders `readiness`; every decision behind it is made here, so Tasks
/// 3, 5 and 6 (previews and a recipient picker) have one place to hang their
/// own state without duplicating this one's.
///
/// ## No verdict is ever stored
///
/// `readiness` is **computed on every read**, never assigned. This is not a
/// style preference; it is the fix for a defect that was found and closed
/// four separate times during this task's review, each instance one door
/// along from the last. The shape was always the same: `readiness` was a
/// stored value, the facts behind it were cleared by only *some* of the
/// paths that change what is being created, and so any path that recomputed
/// — or any change that recomputed nothing at all — could leave the sheet
/// describing a situation that no longer existed. A malformed source file
/// refused at `create()` left a failure banner that survived the user
/// picking a different file; changing the name left the previous name's
/// verdict standing; switching the source radio left the previous source's.
///
/// A derived `readiness` cannot go stale, because there is nothing to go
/// stale. Everything it reads is either a live input (`relativeName`,
/// `sourceChoice`, the loaded source, `keyStore.state`) or a fact filed
/// under the exact subject it was learned about (`Learned`, below).
///
/// ## Facts learned by attempting, and the subject each belongs to
///
/// Two things can only be learned by calling `create()` and seeing what
/// happens: that this session's key is not among a plan's recipients
/// (`SecretFileCreator.Failure.wouldBeUnreadable`), and any other refusal
/// the creator reports. Both are stored as `Learned` values, whose *only*
/// accessor takes the current subject and returns nothing when it has
/// changed. There is no way to read such a fact without saying what it would
/// be a fact about, so a fact about a file that has since changed cannot be
/// returned at all — the compiler has no accessor to offer that would.
///
/// The two have deliberately different subjects:
///
/// - **`unreadability`** is filed under `GovernedPlan` — the recipients and
///   `encryptedRegex` a create would use. Self-readability is a property of
///   the recipient set, not of the bytes, so re-picking a source file must
///   not discard it (that was the third instance: the user re-picked instead
///   of ticking the box, and lost the checkbox that this type's own doc
///   comment calls the only way out).
/// - **`lastCreateFailure`** is filed under the whole `AttemptSubject` — the
///   name, the plan and the exact source bytes. Any change to any of them
///   drops it. That deliberately forgets more than strictly necessary: a
///   `destinationExists` refusal is about the name and stays true when only
///   the content changes. Forgetting it returns this model to the state it
///   would be in had the attempt never happened — which for that case is
///   `.ready`, exactly what a freshly built model reports, since nothing
///   here looks at the filesystem before `create()` does. The cost of
///   forgetting is one repeated, accurate refusal; the cost of remembering
///   too long is the defect above, four times over.
///
/// ## Self-readability cannot be predicted, only discovered
///
/// A `.governedByRule` plan's `recipients` are `age1…` public keys;
/// `SessionKeyStore` holds a private `AGE-SECRET-KEY-1…` identity. There is
/// no bridge primitive that derives one from the other —
/// `SecretFileCreator`'s own doc comment, "Self-readability is the default",
/// has the full account of why not: deriving one by hand would mean
/// reimplementing X25519/bech32, exactly what ADR 0002 forbids. So this
/// model cannot know, the moment a plan resolves, whether this session could
/// read back a file encrypted for that plan's recipients — the only way to
/// find out is to try, which is exactly what `SecretFileCreator.create`
/// already does as its own round-trip verification.
///
/// This is why `readiness` reports `.ready(recipients:)` for *every*
/// resolved `.governedByRule` plan with a configured session key — including
/// one whose recipients do not actually include this session's key, because
/// that membership question has not been asked yet. Only after `create()`
/// has actually been attempted and `SecretFileCreator` reports
/// `.wouldBeUnreadable` does this model learn anything about it:
/// `unreadability` records that one fact for the plan it was learned about,
/// and `readiness` reports `.needsAcknowledgement` from that point until
/// `acknowledgedUnreadable` is set. Nothing in this type ever tries to guess
/// the answer ahead of that call.
///
/// ## `Readiness.ready(recipients:)` carries only what gets displayed
///
/// `ResolvedEncryption` — which also needs `encryptedRegex` — is built fresh
/// inside `create()` from the current `AttemptSubject`, never carried on
/// `Readiness` itself. If `Readiness` carried it too, there would be two
/// sources of truth about what the file is about to be encrypted with.
///
/// ## No debounce here
///
/// `resolvePlan()` runs once per call and neither waits for, nor coalesces,
/// anything on its own. `NewSecretFileSheet` (Task 4) owns the 200 ms
/// debounce and its own cancellation as the user types — a model that
/// debounced itself could not be driven directly from a test without
/// actually waiting out the debounce. `readiness` reports `.resolving` for
/// the window in between, rather than the previous name's verdict.
@MainActor
@Observable
public final class NewSecretFileModel {

    /// Which kind of content a not-yet-created file would start from. All
    /// four are fully implemented — see `loadPlainYAML(from:)`/
    /// `loadDotEnv(from:)`/`chooseEncryptedFile(at:)` and `currentSource()`'s
    /// own switch. `.encryptedYAML` is the one source that needs an extra
    /// step before it can be used at all: unlocking the file and diffing who
    /// would gain or lose access against the current plan — see
    /// `encryptedImport`'s own doc comment.
    public enum SourceChoice: Equatable, Sendable, CaseIterable {
        case empty, plainYAML, encryptedYAML, dotEnv
    }

    /// What clicking Create would do right now.
    public enum Readiness: Equatable, Sendable {
        case needsName
        /// `relativeName` has changed since the last `resolvePlan()` call, so
        /// no plan in hand describes the file the user is currently naming.
        /// Deliberately not the previous name's verdict: that verdict is
        /// about a different file. `NewSecretFileSheet`'s debounce closes
        /// this window ~200 ms after the last keystroke.
        case resolving
        case needsSource
        case blocked(CreationFailureMessage)
        /// `plan` is `.governedByRule`, but a previous `create()` attempt
        /// discovered — via `SecretFileCreator.Failure.wouldBeUnreadable` —
        /// that this session's key could not be proven to be among its
        /// recipients. Ticking `acknowledgedUnreadable` is the only way out
        /// of this state; see this type's doc comment, "Self-readability
        /// cannot be predicted, only discovered".
        case needsAcknowledgement
        /// `plan` is `.noConfig` or `.noRuleMatched` and nothing has been
        /// chosen yet in `manuallyChosenRecipients`. Neither underlying
        /// state is a failure — see `CreationPlanResolver.plan`'s own doc
        /// comment — so this is not `.blocked`: `RecipientPicker` is the way
        /// out, and the moment at least one recipient has been chosen this
        /// model treats the manually-chosen set exactly like a resolved
        /// rule's own recipients, including the same round-trip discovery
        /// (`.needsAcknowledgement`) and the same `create()` failures
        /// (`.blocked`). See `currentGovernedPlan()`.
        case needsRecipients
        case ready(recipients: [String])
    }

    /// What choosing, and then unlocking, an `.encryptedYAML` source has
    /// produced so far — see `encryptedImport`'s own doc comment for the
    /// full account, including why `.unlocked`'s three arrays are computed
    /// fresh on every read rather than carried here as stored facts.
    public enum EncryptedImportState: Equatable, Sendable {
        case notChosen
        /// `NSOpenPanel` returned this path, but `unlockChosenEncryptedFile()`
        /// has not yet finished for it (or has not been called at all).
        case locked(path: String)
        /// The file could not be unlocked — a read failure, or this
        /// session's key could not decrypt it. Worded by
        /// `CreationFailurePresenter`, never composed here; see
        /// `unlockChosenEncryptedFile()`'s own doc comment for every way
        /// this is reached.
        case unlockFailed(CreationFailureMessage)
        /// The file decrypted, but `currentGovernedPlan()` has nothing to
        /// diff it against yet — the name has not resolved, `.sops.yaml`
        /// resolves to `.noConfig`/`.noRuleMatched` with nothing chosen by
        /// hand yet, or the plan is one of the two blocking cases
        /// (`.unsupportedRule`/`.configUnreadable`). There is no target
        /// recipient set to compare the source's own against, so there is
        /// nothing honest to show as a diff — see `encryptedImport`'s own
        /// doc comment, "The diff needs a known target, not just a decrypted
        /// file", for the finding this case exists to close.
        case unlockedAwaitingPlan
        /// The file decrypted, a target plan is known, and this is who it
        /// differs from the source file's own: `gaining` is in the target
        /// but not the source, `losing` is in the source but not the
        /// target, `keeping` is in both. Every array is age recipients — the
        /// view names them, this model never invents a name for one.
        case unlocked(gaining: [String], losing: [String], keeping: [String])
    }

    // MARK: - Subjects: what a fact can be a fact *about*

    /// A fact, inseparable from the exact subject it was learned about.
    ///
    /// `value(ifStillAbout:)` is the **only** accessor: there is no way to
    /// get the value out without naming the subject it would apply to, and
    /// no way to get it out at all once that subject has changed. This is
    /// what makes a stale verdict inexpressible rather than merely absent —
    /// a future field that forgets to clear itself cannot exist here,
    /// because nothing is cleared; facts simply stop being readable when
    /// what they describe is gone.
    ///
    /// Exactly how strong that is, stated so the next reader does not
    /// over-trust it: `private` in Swift is **file**-scoped, and every call
    /// site of this type lives in this file, so an extension written here —
    /// `extension NewSecretFileModel.Learned { var raw: Value { value } }` —
    /// would compile and hand back the value with no subject named. That
    /// cannot happen by accident, which is where the value of this design
    /// lies, but it is not a wall. Moving this type to its own file would
    /// make `private` do the full job; it lives here because the subjects it
    /// is instantiated with are this type's own nested types.
    struct Learned<Subject: Equatable, Value> {
        private let subject: Subject
        private let value: Value

        init(_ value: Value, about subject: Subject) {
            self.value = value
            self.subject = subject
        }

        func value(ifStillAbout current: Subject) -> Value? {
            subject == current ? value : nil
        }
    }

    /// The one `CreationPlan` case a file can actually be created under,
    /// with its payload lifted into a value of its own. Two purposes: a
    /// `Learned` fact about "the plan" compares exactly the recipients and
    /// regex a create attempt would use, and `create()` never has to
    /// re-destructure `CreationPlan` to reach them.
    struct GovernedPlan: Equatable, Sendable {
        let recipients: [String]
        let encryptedRegex: String
    }

    /// Exactly what `create()` would hand `SecretFileCreator` right now: the
    /// name it would write, the recipients and regex it would encrypt for,
    /// the bytes it would encrypt, and whether it would waive the round-trip
    /// verification.
    ///
    /// This is the single description of "what is being created", and it is
    /// load-bearing twice over: `create()` takes every input it uses from
    /// this value (never from the properties behind it), and every failure
    /// an attempt produces is filed under the value in hand at the time. So
    /// a new input to creation cannot be added without adding it here — the
    /// alternative is a field `create()` never reads, which by definition
    /// changes nothing about the file — and adding it here is what makes a
    /// change to it invalidate the facts learned before it changed.
    ///
    /// That claim is exact, and `acknowledgedUnreadable` is here because of
    /// it: an earlier version of this type read that flag straight off the
    /// model inside `create()`, which made the sentence above have one
    /// counter-example in its own file. It is a real input —
    /// `SecretFileCreator` treats it as "skip the refusal *and* skip all
    /// content verification" — so a refusal learned while it was unticked is
    /// not a refusal about the same attempt once it is ticked.
    ///
    /// `manuallyChosenRecipients` (Task 5) is the other real input this
    /// invariant had to answer for, and it joins by a different route than
    /// `acknowledgedUnreadable` did: rather than a field of its own here, it
    /// is folded into `plan` by `currentGovernedPlan()` whenever the
    /// resolver itself had nothing to offer. `plan` was always part of this
    /// subject, so nothing new had to be added — a change to the
    /// manually-chosen set already produces a different `GovernedPlan`, and
    /// therefore a different `AttemptSubject`, exactly as a change to a
    /// resolved rule's own recipients always has. A second field carrying
    /// the same information would only create a way for the two to
    /// disagree.
    struct AttemptSubject: Equatable {
        let name: String
        let plan: GovernedPlan
        let source: SecretFileCreator.Source
        let acknowledgedUnreadable: Bool
    }

    /// What a `.sops.yaml` proposal was actually built for — the name and
    /// the exact recipient set at the moment `proposeConfig()` called
    /// `SopsConfigGenerator.propose`.
    ///
    /// This is Task 5's own review finding, closed the same way every prior
    /// round of this exact defect class was closed: `ProposedConfig` itself
    /// carries `text`/`verified`/`reason` and nothing naming what it is
    /// *about* — no subject at all — so a caller holding one has no way to
    /// ask "is this still the proposal I would build right now?" without
    /// this type. Before it existed, `RecipientPicker` answered that
    /// question by hand, clearing its own `@State` at every mutation site it
    /// remembered to — and a mutation site it forgot (the remove button) or
    /// one added later (a fourth `manuallyChosenRecipients` writer this file
    /// does not yet have) could write a verified-but-stale proposal, mismatched against what the
    /// user's own on-screen selection said. See `writeProposedConfig()`'s
    /// own doc comment for how this closes that door structurally, the same
    /// way `AttemptSubject`/`GovernedPlan` already close it for `create()`.
    struct ProposalSubject: Equatable {
        let name: String
        let recipients: [String]
    }

    /// The outcome of the most recent `resolvePlan()` call: the name it ran
    /// for, and either the plan it produced or the reason it could not. One
    /// value rather than three properties, so `plan`, the resolve's failure
    /// message, and the name they belong to can never disagree about which
    /// name is being described.
    private struct Resolution: Equatable {
        let name: String
        /// `nil` when `name` was blank (the resolver is never asked about
        /// the project root itself — see `resolvePlan()`) or the resolve
        /// threw, in which case `error` explains it.
        let plan: CreationPlan?
        let error: CreationFailureMessage?
    }

    // MARK: - Inputs

    public let projectRoot: URL
    /// A plain property with no observer, and none is needed: `readiness` is
    /// computed on every read (see this type's doc comment, "No verdict is
    /// ever stored"), so changing this is reflected immediately, and it is
    /// part of the `AttemptSubject`, so changing it drops any verdict about
    /// the source it replaced. Nothing has to be called afterwards —
    /// `NewSecretFileSheet` used to call `resolvePlan()` here and no longer
    /// does; see that file's own doc comment for why that call was only ever
    /// harmful.
    public var sourceChoice: SourceChoice = .empty
    public var relativeName: String = ""

    /// Recipients the user has chosen by hand, for a `plan`
    /// `CreationPlanResolver` could not resolve on its own — `.noConfig` or
    /// `.noRuleMatched`. `RecipientPicker` is the only writer.
    ///
    /// This is a genuine new input to what would be created, and it does
    /// join `AttemptSubject` — but not as a field of its own.
    /// `currentGovernedPlan()` folds it into a `GovernedPlan` exactly the
    /// way a resolved rule's recipients already are, and `GovernedPlan` is
    /// what `AttemptSubject.plan` actually holds. So a change here already
    /// produces a different `AttemptSubject` — through `plan`, not through a
    /// second field that would have to be kept in step with it — and
    /// `lastCreateFailure`/`unreadability`, both filed under one of those
    /// two types, drop exactly the same way they would for a resolved
    /// rule's recipients changing. Adding a second, separate field here
    /// would let the two disagree; this cannot.
    ///
    /// A plain property with no observer, for the same reason `sourceChoice`
    /// has none: `readiness` is computed on every read. `resolvePlan()`
    /// resets this to `[]` on every call — see that method's own comment —
    /// so a set chosen for one name cannot silently carry over to a
    /// different one, the identical discipline it already applies to
    /// `acknowledgedUnreadable`/`unreadability`.
    public var manuallyChosenRecipients: [String] = []

    /// The verbatim text of a `.plainYAML`-sourced file, once
    /// `loadPlainYAML(from:)` has read it successfully. Handed to
    /// `SecretFileCreator` as `.verbatimYAML(_:)` — unchanged, never
    /// reserialised — so this is exactly what `create()` would encrypt, not
    /// a path it would re-read later. `nil` until a file has been picked and
    /// read, or after a read that failed (`plainYAMLLoadError` explains
    /// that case instead).
    public private(set) var plainYAMLText: String?
    /// Why the most recent `loadPlainYAML(from:)` call could not produce
    /// `plainYAMLText` — always through `CreationFailurePresenter`, never
    /// composed here. `nil` once a read has succeeded.
    public private(set) var plainYAMLLoadError: CreationFailureMessage?

    /// A `.dotEnv`-sourced file, already parsed, once `loadDotEnv(from:)`
    /// has read and parsed it successfully. The same value
    /// `NewSecretFileSheet` renders through `DotEnvPreviewTable` and the one
    /// `create()` hands to `SecretFileCreator` as `.dotEnv(_:.entries)` —
    /// one parse, shared by the preview and the write, never re-parsed
    /// between them. `nil` until a file has been picked and parsed, or
    /// after a parse that failed (`dotEnvLoadError` explains that case
    /// instead).
    public private(set) var dotEnvParsed: ParsedDotEnv?
    /// Why the most recent `loadDotEnv(from:)` call could not produce
    /// `dotEnvParsed` — always through `CreationFailurePresenter`, never
    /// composed here. `nil` once a read has succeeded.
    public private(set) var dotEnvLoadError: CreationFailureMessage?

    /// The file most recently chosen for the `.encryptedYAML` source, via
    /// `chooseEncryptedFile(at:)`. Unlike `plainYAMLText`/`dotEnvParsed`, the
    /// URL itself is kept, not only what was read from it: unlocking is a
    /// separate, retriable, explicit step from choosing (`readiness` can sit
    /// at `.needsSource` for a while in between, or `unlockChosenEncryptedFile()`
    /// can be called again after `.unlockFailed`), and each attempt has to
    /// re-read this exact file — `encryptedImport`'s own doc comment has the
    /// full account of what unlocking produces and how it is kept fresh.
    public private(set) var chosenEncryptedFileURL: URL?

    /// Set by the user once `readiness` has reported `.needsAcknowledgement`.
    /// A plain flag with no property observer: `readiness` is computed, so
    /// setting this is reflected on the next read with nothing to keep in
    /// step. Reset by `resolvePlan()` — an acknowledgement is an answer to
    /// one specific round-trip attempt, not a standing waiver.
    public var acknowledgedUnreadable = false

    public private(set) var isResolving = false

    private let keyStore: SessionKeyStore

    // MARK: - Learned facts

    private var resolution: Resolution?

    /// That a `create()` attempt discovered this session's key could not be
    /// proven to be among a plan's recipients. Filed under the plan, not the
    /// whole `AttemptSubject`: this is a fact about the recipient set, and
    /// re-picking a source file must not discard it. Also cleared outright
    /// by `resolvePlan()` — see that method — which is a stricter policy
    /// than the subject check alone; the subject check is the floor.
    private var unreadability: Learned<GovernedPlan, Bool>?

    /// Why the most recent `create()` attempt refused, when the refusal was
    /// anything other than an unacknowledged `wouldBeUnreadable`. Filed
    /// under the whole `AttemptSubject`; see this type's doc comment for why
    /// this one forgets on any change and `unreadability` does not.
    private var lastCreateFailure: Learned<AttemptSubject, CreationFailureMessage>?

    /// The most recent `proposeConfig()` result, filed under exactly what it
    /// was proposed for. `writeProposedConfig()` reads this back through
    /// `value(ifStillAbout:)` and nothing else — never a caller-supplied
    /// `ProposedConfig` — so it can only write a proposal that is still
    /// describing the name and recipient set on screen right now. See
    /// `ProposalSubject`'s own doc comment for the finding this closes.
    private var lastProposal: Learned<ProposalSubject, ProposedConfig>?

    /// What `unlockChosenEncryptedFile()` learned about the chosen file, on
    /// success or failure — see `UnlockedImport`'s own doc comment for why
    /// only these two things are learned, and `encryptedImport`'s for why
    /// its own three-way diff is not a third.
    private enum EncryptedImportOutcome {
        case unlocked(UnlockedImport)
        case failed(CreationFailureMessage)
    }

    /// The two things `unlockChosenEncryptedFile()` actually learns from a
    /// successful decrypt: the source file's own recipients (from
    /// `SopsBridge.recipients(in:)`, which needs no private identity — see
    /// that method's own doc comment) and the plaintext the decrypt
    /// produced. Deliberately not a third thing alongside them: the
    /// three-way access diff `encryptedImport` reports is computed from
    /// `sourceRecipients` fresh on every read, never stored here — see that
    /// property's own doc comment for why.
    ///
    /// `decryptedText` is genuine secret material. It has exactly one
    /// reader: `currentSource()`, which hands it straight to
    /// `SecretFileCreator.Source.verbatimYAML(_:)` — never through any
    /// public property, never logged, never rendered. Nothing about it
    /// reaches `EncryptedImportState`, which is the whole of what
    /// `EncryptedImportPreview` can see.
    private struct UnlockedImport {
        let sourceRecipients: [String]
        let decryptedText: String
    }

    /// Filed under the file path `unlockChosenEncryptedFile()` read it from —
    /// not under a `GovernedPlan` or an `AttemptSubject`, on purpose.
    /// Unlocking is a fact about the *source* file alone: it needs no target
    /// plan to attempt (`SopsBridge.decryptYAML`/`.recipients(in:)` never see
    /// one), and its outcome cannot become untrue because the target plan
    /// changed — only because the file itself was replaced by
    /// `chooseEncryptedFile(at:)`, which is exactly what re-keys this
    /// subject. A target plan changing afterwards is handled entirely by
    /// `encryptedImport` re-deriving its diff against the live plan, not by
    /// invalidating this fact — see that property's own doc comment.
    private var encryptedImportOutcome: Learned<String, EncryptedImportOutcome>?

    // MARK: - Derived views of the resolve

    public var plan: CreationPlan? { resolution?.plan }

    /// The `relativeName` that `plan` was actually resolved for, `nil` before
    /// any resolve has happened at all.
    ///
    /// `NewSecretFileSheet` reads this to guard its own debounced resolve — a
    /// resolve is skipped whenever the name it would resolve for is already
    /// the one this reports, which is how it avoids reflexively discarding a
    /// fresh `acknowledgedUnreadable` tick between it and a redundant resolve
    /// for an unchanged name. See that view's own doc comment, "The debounce,
    /// and why it checks `resolvedName` before firing".
    public var resolvedName: String? { resolution?.name }

    /// The reason the most recent `resolvePlan()` or `create()` call could
    /// not proceed — a thrown `CreationPlanResolver.Error` in the first case,
    /// a `SecretFileCreator.Failure` in the second, always worded by
    /// `CreationFailurePresenter` and never composed here.
    ///
    /// `nil` whenever no such reason applies to what is being created *right
    /// now*: a resolve or create that did not fail this way, a create that
    /// refused with an unacknowledged `wouldBeUnreadable` (that refusal
    /// rides in `readiness` as `.needsAcknowledgement`, deliberately not
    /// here — nothing renders a failure sentence in that state), or a
    /// refusal that has since stopped describing what would be created. A
    /// `plan` resolving to `.noConfig`/`.noRuleMatched` is not this kind of
    /// failure either; see `readiness`.
    public var planError: CreationFailureMessage? {
        // The same `resolution.name == relativeName` gate `readiness` applies,
        // and for the same reason: a resolve failure is a refusal about the
        // name it ran for. Without this gate, typing a name with a `..`
        // component (refused as `targetOutsideProjectRoot`) and then fixing it
        // left this property still reporting the refusal about the name the
        // user had already replaced — the last stale read that was still
        // spellable after the redesign, and the one this file's own tests use
        // as their probe that a verdict was dropped.
        if let resolution, resolution.name == relativeName, let error = resolution.error {
            return error
        }
        guard let subject = currentSubject() else { return nil }
        return lastCreateFailure?.value(ifStillAbout: subject)
    }

    /// What choosing, and then unlocking, an `.encryptedYAML` source has
    /// produced — the one source whose own doc comment (`SourceChoice`)
    /// promises an extra step before it can be used at all: this source
    /// arrives with its own recipient set, already encrypted for someone,
    /// and re-encrypting it for a different set is a real access change that
    /// has to be shown, not merely a file to read (spec §4.1, decision 4).
    ///
    /// `.locked(path:)` is the state between `chooseEncryptedFile(at:)`
    /// returning and `unlockChosenEncryptedFile()` finishing — `path` is
    /// exactly `chosenEncryptedFileURL.path`, not a value this file invents.
    /// `.unlockFailed` carries a `CreationFailureMessage`, worded by
    /// `CreationFailurePresenter` like every other refusal in this file; a
    /// failed unlock **never** falls through to `.unlocked` — `create()`
    /// finds nothing to encrypt for this source until this reports
    /// `.unlocked`, so a refused unlock creates nothing (see
    /// `currentSource()`).
    ///
    /// ## `.unlocked(gaining:losing:keeping:)` is derived, not stored — the
    /// deliberate answer to the question this task's own brief asks about
    /// subjects
    ///
    /// What `unlockChosenEncryptedFile()` actually *learns*, once, is the
    /// source file's own recipients and its plaintext — both filed under
    /// `encryptedImportOutcome`, keyed to the exact file path they were read
    /// from (see that property's own doc comment). The three-way diff this
    /// case reports is **not** part of that learned fact: it is computed
    /// fresh, right here, every time this property is read, from the learned
    /// source recipients on one side and `currentGovernedPlan()?.recipients`
    /// — the *live* target — on the other.
    ///
    /// That split matters because the two halves of the diff change on
    /// different schedules. The source side is fixed the moment a file is
    /// picked; re-reading it needs another explicit unlock, which is why it
    /// is filed as a `Learned` fact keyed to the file path alone, mirroring
    /// `plainYAMLText`/`dotEnvParsed`. The target side is not fixed at all —
    /// it is `currentGovernedPlan()`, the exact value `readiness` and
    /// `create()` already treat as live, and it changes every time the name
    /// is retyped or `manuallyChosenRecipients` is edited, with no unlock
    /// involved. A version of this type that computed the diff once, at
    /// unlock time, and stored the three arrays would be exactly this task's
    /// brief's own cautionary tale one field over: `RecipientPicker`'s
    /// `ProposalSubject` finding was closed by giving a proposal a subject
    /// precisely because a stored verdict about "what would happen" silently
    /// stopped describing the truth the moment an unrelated mutation changed
    /// the inputs it was computed from. A stored diff here would go stale on
    /// every keystroke in the name field after an unlock — showing a user
    /// "gains: Alice" for a plan that no longer names Alice at all — which is
    /// precisely the silent access-change disclosure decision 4 exists to
    /// prevent, not a cosmetic staleness bug. Deriving it fresh on every read
    /// makes that impossible the same structural way `readiness` already is:
    /// there is no stored verdict to go stale, because there is nothing
    /// stored to begin with — only the one fact that genuinely cannot change
    /// without another unlock (the source's own recipients), read fresh
    /// against the one input that changes freely (the target plan).
    ///
    /// ## The diff needs a known target, not just a decrypted file
    ///
    /// A real review finding, closed here rather than left as a caveat:
    /// `currentGovernedPlan()` is `nil` in four ordinary cases —
    /// `relativeName` not yet resolved for, `.noConfig`/`.noRuleMatched` with
    /// nothing chosen in `manuallyChosenRecipients` yet, `.unsupportedRule`,
    /// `.configUnreadable` — and the first release of this property answered
    /// `nil` with `?? []`, treating "no target known" as "the target is
    /// nobody". That is not a degraded preview; it is a false statement,
    /// asserted in red, by name: `EncryptedImportPreview` named every one of
    /// the source's own recipients as *losing* access to a file whose
    /// destination had not even been decided. `readiness` staying
    /// `.needsSource`/`.needsRecipients`/`.resolving` at the same moment does
    /// not fix this — Create being disabled is not a disclaimer on a
    /// sentence the app has already put on screen, and the `.noConfig`/
    /// `.noRuleMatched` case is not even a brief window: `NewSecretFileSheet`
    /// renders `RecipientPicker` at the exact same time as this preview, so
    /// a user with no `.sops.yaml` yet reads "Alice and Bob will lose access"
    /// while still being asked who should have any.
    ///
    /// `.unlockedAwaitingPlan` is the fix: a target-less decrypt is its own
    /// state, not a `.unlocked` with an invented empty target. This is a
    /// deliberate divergence from this task's own brief, which specifies
    /// `.unlocked(gaining:losing:keeping:)` as the only case a successful
    /// decrypt reaches — that interface has no way to say "decrypted, but
    /// nothing to compare against yet" without lying about what the target
    /// is, so it is one case short for what decision 4 actually requires.
    public var encryptedImport: EncryptedImportState {
        guard let chosenEncryptedFileURL else { return .notChosen }
        let path = chosenEncryptedFileURL.path
        guard let outcome = encryptedImportOutcome?.value(ifStillAbout: path) else {
            return .locked(path: path)
        }
        switch outcome {
        case .failed(let message):
            return .unlockFailed(message)
        case .unlocked(let unlocked):
            guard let target = currentGovernedPlan()?.recipients else {
                return .unlockedAwaitingPlan
            }
            let targetSet = Set(target)
            let sourceSet = Set(unlocked.sourceRecipients)
            return .unlocked(
                gaining: target.filter { !sourceSet.contains($0) },
                losing: unlocked.sourceRecipients.filter { !targetSet.contains($0) },
                keeping: unlocked.sourceRecipients.filter { targetSet.contains($0) })
        }
    }

    public init(projectRoot: URL, keyStore: SessionKeyStore) {
        self.projectRoot = projectRoot
        self.keyStore = keyStore
    }

    /// Recomputes `plan` for `relativeName` under `projectRoot`. Called by
    /// the view; see this type's doc comment, "No debounce here". `readiness`
    /// needs no recompute of its own — it is derived.
    public func resolvePlan() async {
        // A fresh resolve means nothing has been acknowledged yet about
        // whatever plan comes back.
        //
        // Resetting `acknowledgedUnreadable` here closes a real hole:
        // without it, ticking the box for one name (say `secret.yaml`, whose
        // rule excludes this session's key) stayed `true` after the name
        // changed to a second, differently-governed one (`other.yaml`,
        // excluded by a *different* rule). `create()` passes
        // `acknowledgedUnreadable` straight into `ResolvedEncryption`, and
        // `SecretFileCreator.create` treats it as "skip the refusal *and*
        // skip all content verification, unconditionally" — so the second
        // file would have been written blind, for a plan the user was never
        // actually warned about. See this type's doc comment,
        // "Self-readability cannot be predicted, only discovered": an
        // acknowledgement is an answer to one specific round-trip attempt,
        // not a standing waiver, and it must not survive past the plan it
        // was given for.
        //
        // `unreadability` is cleared alongside it, and this is the stricter
        // of the two policies available: filed under `GovernedPlan`, it
        // would already be unreadable for any plan but the one it was
        // learned about, so a resolve that lands on the *same* rule again
        // could legitimately keep it. It is cleared anyway so that a resolve
        // leaves this model in exactly the state a fresh one would be in for
        // the same inputs — the acknowledgement is gone, so the discovery
        // that demanded it must go too, or `readiness` would demand a tick
        // the user has no memory of being asked for.
        unreadability = nil
        acknowledgedUnreadable = false

        // `manuallyChosenRecipients` is cleared for the identical reason:
        // it is this model's equivalent of `acknowledgedUnreadable` for the
        // `.noConfig`/`.noRuleMatched` branch — an answer given about *this*
        // name, not a standing default to carry into whatever name comes
        // next. Without this, picking recipients by hand for `a.yaml`
        // (unmatched by any rule) and then renaming to `b.yaml` (also
        // unmatched) would silently apply `a.yaml`'s chosen set to `b.yaml`
        // without the user ever being asked about the second file — the
        // same shape of leak `acknowledgedUnreadable`'s own reset closes,
        // pinned by `NewSecretFileModelTests
        // .acknowledgementDoesNotCarryAcrossANameChange`.
        manuallyChosenRecipients = []

        // `lastProposal` would already be unreadable the moment
        // `manuallyChosenRecipients` above changes it to `[]` — no
        // `ProposalSubject` matches empty recipients, since `proposeConfig()`
        // never files one for an empty selection. Cleared explicitly anyway,
        // for the same reason `unreadability`/`acknowledgedUnreadable` are
        // cleared outright rather than left to the subject check alone: a
        // resolve should leave this model in exactly the state a fresh one
        // would be in for the same inputs, not merely in a state where the
        // old value happens to be unreachable.
        lastProposal = nil

        // `lastCreateFailure` is deliberately *not* cleared here. It is
        // filed under the whole `AttemptSubject`, so a resolve that changes
        // the name or the plan already makes it unreadable, and a resolve
        // that changes neither has not made a real refusal any less true.

        // `CreationPlanResolver.plan(forTarget:in:)` must never be asked
        // about `projectRoot` itself: an empty (or whitespace-only — a
        // name of all spaces is not a name either) `relativeName` would
        // make `target` and `projectRoot` the identical URL, and every
        // rule's `path_regex` would then be matched against the project
        // root's own path rather than against nothing at all.
        // Short-circuiting here means that call is never made with a name
        // the user has not actually typed anything meaningful into yet.
        guard !isBlank(relativeName) else {
            resolution = Resolution(name: relativeName, plan: nil, error: nil)
            return
        }

        isResolving = true
        defer { isResolving = false }

        let target = projectRoot.appendingPathComponent(relativeName)
        do {
            let plan = try CreationPlanResolver.plan(forTarget: target, in: projectRoot)
            resolution = Resolution(name: relativeName, plan: plan, error: nil)
        } catch let error as CreationPlanResolver.Error {
            resolution = Resolution(
                name: relativeName, plan: nil, error: CreationFailurePresenter.message(for: error))
        } catch {
            // `CreationPlanResolver.plan(forTarget:in:)` is documented to
            // throw only `Error` — not expected to be reachable in practice,
            // but a caller must never see this fail silently for a type it
            // did not anticipate.
            resolution = Resolution(
                name: relativeName, plan: nil,
                error: CreationFailureMessage(title: .creationFailureTitle, detail: "\(error)", recovery: nil))
        }
    }

    /// Reads `url` and stores its verbatim text as `plainYAMLText`, or
    /// records why it could not. The one read this file ever does for a
    /// `.plainYAML` source — `create()` uses `plainYAMLText`, never
    /// re-reads `url`, so what the user previewed (once `NewSecretFileSheet`
    /// renders it) is exactly what gets encrypted, not whatever the file
    /// happens to contain the moment Create is pressed.
    ///
    /// Nothing needs recomputing afterwards: `readiness` and `planError` are
    /// both derived, and replacing the text changes the `AttemptSubject`,
    /// which is what drops any refusal recorded about the text it replaced.
    ///
    /// Known, deliberately deferred limitation: `Data(contentsOf:)` below
    /// runs synchronously on the main actor, with no size ceiling — a very
    /// large or network-volume file freezes the sheet with no loading
    /// indicator at all. Fixing this properly needs an async read path and
    /// a loading affordance in `NewSecretFileSheet`, a real UI addition,
    /// not a one-line change; left for a later task.
    public func loadPlainYAML(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                plainYAMLText = nil
                plainYAMLLoadError = CreationFailurePresenter.message(forUnreadableSourceFile: ())
                return
            }
            plainYAMLText = text
            plainYAMLLoadError = nil
            forgetLastCreateFailure()
        } catch {
            // `Data(contentsOf:)` failing — permissions changed, or the file
            // was moved or deleted between `NSOpenPanel` returning `url` and
            // this read. See `CreationFailurePresenter
            // .message(forUnreadableSourceFile:)`'s own doc comment for why
            // this is not one of the four vocabularies that type otherwise
            // unifies.
            plainYAMLText = nil
            plainYAMLLoadError = CreationFailurePresenter.message(forUnreadableSourceFile: ())
        }
    }

    /// Reads and parses `url` as a `.env` file, storing the result as
    /// `dotEnvParsed`, or records why it could not. `DotEnvParser` owns the
    /// UTF-8 decode — the raw bytes go straight in, never a
    /// `String(contentsOf:)` read first (see that type's own doc comment,
    /// "Why `Data`, not `String`"). The one parse this file ever does for a
    /// `.dotEnv` source: `NewSecretFileSheet` renders `dotEnvParsed` through
    /// `DotEnvPreviewTable`, and `create()` hands its `.entries` to
    /// `SecretFileCreator` — the same parse, never repeated, so the preview
    /// and the write can never disagree about what was in the file.
    ///
    /// Nothing needs recomputing afterwards, for the same reason
    /// `loadPlainYAML(from:)` does not.
    ///
    /// Same known, deliberately deferred limitation as `loadPlainYAML(
    /// from:)`: the `Data(contentsOf:)` read below is synchronous, on the
    /// main actor, with no size ceiling.
    public func loadDotEnv(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            dotEnvParsed = try DotEnvParser.parse(data)
            dotEnvLoadError = nil
            forgetLastCreateFailure()
        } catch let failure as DotEnvParseFailure {
            dotEnvParsed = nil
            dotEnvLoadError = CreationFailurePresenter.message(for: failure)
        } catch {
            // Either `Data(contentsOf:)` itself failed, or `DotEnvParser
            // .parse` threw something other than `DotEnvParseFailure` — not
            // expected to be reachable for the latter (that type is
            // documented to throw only `DotEnvParseFailure`), but handled
            // rather than assumed so a future change to that contract can't
            // crash this call.
            dotEnvParsed = nil
            dotEnvLoadError = CreationFailurePresenter.message(forUnreadableSourceFile: ())
        }
    }

    /// Records `url` as the file `.encryptedYAML` would import and drops
    /// whatever a previous unlock attempt learned — a new file needs a new
    /// unlock, and `encryptedImportOutcome` is filed under the *path* being
    /// unlocked, not "whatever was most recently unlocked", so picking a
    /// different file already makes any previous outcome unreadable through
    /// `value(ifStillAbout:)`. Cleared here too, outright, for the identical
    /// "err toward forgetting" reason `resolvePlan()` clears
    /// `unreadability`/`acknowledgedUnreadable` unconditionally rather than
    /// relying on the subject check alone: this call site knows for certain
    /// the old fact no longer applies, so there is no reason to wait for a
    /// read to discover that structurally.
    ///
    /// Reads nothing and unlocks nothing — this only records *which* file;
    /// `unlockChosenEncryptedFile()` is the separate, explicit call that
    /// actually attempts to open it. `NewSecretFileSheet`'s file picker
    /// calls both, one after the other, the same way it calls
    /// `loadPlainYAML(from:)`/`loadDotEnv(from:)` synchronously right after
    /// `NSOpenPanel` returns — the two are only split here because unlocking
    /// needs the session key and the bridge, and doing that inside a
    /// property setter would make an ordinary assignment silently expensive
    /// and asynchronous.
    public func chooseEncryptedFile(at url: URL) {
        chosenEncryptedFileURL = url
        encryptedImportOutcome = nil
        // `lastCreateFailure` is filed under the whole `AttemptSubject`
        // (name, plan, source, acknowledgement), and `source` already
        // changes the moment `currentSource()` next reads
        // `encryptedImportOutcome` — so this call is memory hygiene, not a
        // correctness fix, the identical distinction `forgetLastCreateFailure()`'s
        // own doc comment draws for `loadPlainYAML(from:)`/`loadDotEnv(from:)`.
        // It matters more here than for either of those: an `AttemptSubject`
        // for this source retains the *decrypted plaintext of an encrypted
        // file* — material the user never typed or pasted, recovered by
        // this app from ciphertext they may have believed only they (or a
        // narrow recipient set) could read. Without this call, unlocking
        // file A, having `create()` refuse it, and then picking file B left
        // A's plaintext sitting in `lastCreateFailure`'s `AttemptSubject`
        // for the rest of the sheet's lifetime, reachable by `Mirror`/`dump`
        // — this source's own strongest instance of the rule the other two
        // loaders already follow.
        forgetLastCreateFailure()
    }

    /// Attempts to unlock the file `chooseEncryptedFile(at:)` most recently
    /// recorded — reads it, decrypts it with this session's key, and, only
    /// once that succeeds, reads its own recipients. A no-op if no file has
    /// been chosen at all.
    ///
    /// Every refusal is filed as `.failed(_:)`, worded by
    /// `CreationFailurePresenter`, never composed here — matching this
    /// file's own discipline throughout:
    ///
    /// - The file itself could not be read (`Data(contentsOf:)` failing, or
    ///   its bytes not being UTF-8) — the same
    ///   `message(forUnreadableSourceFile:)` `loadPlainYAML(from:)`/
    ///   `loadDotEnv(from:)` already use for the identical failure shape on
    ///   their own sources.
    /// - No session key is configured at all — `message(forEmptyKeyStore:)`,
    ///   the same sentence `readiness` itself falls back to for every other
    ///   source once a key is genuinely required.
    /// - The key that *is* configured could not decrypt this file, or the
    ///   file was not a SOPS document to begin with —
    ///   `message(forEncryptedImportUnlockFailure:)`, new for this task,
    ///   handed the bridge's own diagnostic rather than a fixed claim about
    ///   the key; see that method's own doc comment for why that distinction
    ///   is load-bearing (a plain, unencrypted YAML file reaches this exact
    ///   branch, and used to be told its *key* was wrong) and for why this is
    ///   not `SecretFileCreator.Failure.wouldBeUnreadable` wearing a
    ///   different name. This is also where a failure reading this file's
    ///   own recipients after a successful decrypt lands — unreachable in
    ///   practice (a document `SopsBridge.decryptYAML` could open has
    ///   already proven its own metadata parses), but handled rather than
    ///   assumed, the same discipline every catch-all in this file keeps.
    ///
    /// A failed unlock **never** produces a partial result — `encryptedImportOutcome`
    /// is either `.unlocked` with both a real recipient list and real
    /// plaintext, or `.failed`, and `currentSource()` returns `nil` for
    /// anything but the former. There is no "try anyway": a source this
    /// session's key cannot decrypt has no plaintext to import, acknowledged
    /// or not — unlike `SecretFileCreator.Failure.wouldBeUnreadable`, there
    /// is nothing here for `acknowledgedUnreadable` to waive.
    ///
    /// `sessionKey` is lent for exactly this call, through `keyStore.withKey`
    /// — nothing here copies it out anywhere else; see `SessionKeyStore`'s
    /// own doc comment, "Why `withKey` instead of a getter".
    ///
    /// Known, deliberately deferred limitation, named directly rather than
    /// left to be discovered: every step below — the `Data(contentsOf:)`
    /// read, `decryptYAML`, `recipients(in:)` — runs synchronously, inline,
    /// with no suspension point in between. `EncryptedImportPreview` renders
    /// a spinner and "Unlocking…" for the `.locked` state this method's
    /// caller sees while this `Task` is in flight, but for anything but a
    /// very large file that state is not actually visible for a perceptible
    /// duration — this method does not yield the run loop once, so SwiftUI
    /// gets no chance to redraw between `.locked` and whatever this settles
    /// into. A large file or a slow decrypt stalls the UI for that long with
    /// no visible progress, the identical gap `loadPlainYAML(from:)`/
    /// `loadDotEnv(from:)`'s own doc comments already name for their reads,
    /// except those two render no spinner that implies otherwise. Fixing
    /// this for real needs the async `SessionKeyStore.withKey` overload
    /// (`SessionKeyStore.swift`'s own doc comment states it exists for
    /// exactly this) and hopping the bridge calls off the main actor — a
    /// real change, not a one-line fix, left for a later task.
    public func unlockChosenEncryptedFile() async {
        guard let chosenEncryptedFileURL else { return }
        let path = chosenEncryptedFileURL.path

        let sourceText: String
        do {
            let data = try Data(contentsOf: chosenEncryptedFileURL)
            guard let text = String(data: data, encoding: .utf8) else {
                encryptedImportOutcome = Learned(
                    .failed(CreationFailurePresenter.message(forUnreadableSourceFile: ())), about: path)
                return
            }
            sourceText = text
        } catch {
            encryptedImportOutcome = Learned(
                .failed(CreationFailurePresenter.message(forUnreadableSourceFile: ())), about: path)
            return
        }

        let decrypted: Result<String, Swift.Error>? = keyStore.withKey { key in
            do {
                return .success(try SopsBridge.decryptYAML(sourceText, agePrivateKey: key))
            } catch {
                return .failure(error)
            }
        }
        guard let decrypted else {
            // `keyStore.state`, not a hardcoded `.empty` — `withKey` only
            // returns `nil` when no key is configured, which is exactly what
            // `state` already reports in that instant, but reading it rather
            // than asserting it is what keeps this correct if `KeyStoreState`
            // ever grows a second non-`.configured` case (`.unavailable`,
            // M3) that `withKey` would also return `nil` for. `create()`'s
            // own equivalent branch takes the same shortcut for the same
            // reason — see its own comment — so this matches established
            // precedent, not merely today's happenstance.
            if let message = CreationFailurePresenter.message(forEmptyKeyStore: keyStore.state) {
                encryptedImportOutcome = Learned(.failed(message), about: path)
            }
            return
        }
        let plaintext: String
        switch decrypted {
        case .success(let text):
            plaintext = text
        case .failure(let error):
            encryptedImportOutcome = Learned(
                .failed(CreationFailurePresenter.message(
                    forEncryptedImportUnlockFailure: Self.bridgeErrorDescription(error))),
                about: path)
            return
        }

        // Recipient metadata needs no private identity (`SopsBridge
        // .recipients(in:)`'s own doc comment) — read only now, after a
        // successful decrypt, since nothing downstream needs it otherwise.
        do {
            let sourceRecipients = try SopsBridge.recipients(in: sourceText)
            encryptedImportOutcome = Learned(
                .unlocked(UnlockedImport(sourceRecipients: sourceRecipients, decryptedText: plaintext)),
                about: path)
        } catch {
            encryptedImportOutcome = Learned(
                .failed(CreationFailurePresenter.message(
                    forEncryptedImportUnlockFailure: Self.bridgeErrorDescription(error))),
                about: path)
        }
    }

    /// `error`'s own diagnostic when it is a `SopsBridgeError` — the shape
    /// every throw out of `SopsBridge` actually has — otherwise its generic
    /// description. Handled rather than assumed, the same discipline every
    /// catch-all in this file keeps; feeds `CreationFailurePresenter
    /// .message(forEncryptedImportUnlockFailure:)` unchanged, matching that
    /// type's own "bridge text passes through unchanged" rule for `.engine`.
    private static func bridgeErrorDescription(_ error: Swift.Error) -> String {
        (error as? SopsBridgeError)?.description ?? "\(error)"
    }

    /// Drops the last create failure, called after a load has replaced the
    /// source content.
    ///
    /// **Not a correctness clear**, and the distinction matters to anyone
    /// reading this file for the invalidation rule: `lastCreateFailure` is
    /// filed under the whole `AttemptSubject`, so new content already makes
    /// it unreadable whether this runs or not. What this buys is memory
    /// hygiene — an `AttemptSubject` retains a copy of the source bytes, and
    /// those bytes are user plaintext. Without this, a `.env` or YAML file
    /// the user picked, was refused for, and then replaced would sit in this
    /// object's memory for the lifetime of the sheet, reachable by `Mirror`
    /// or `dump`. Nothing logs or renders it (this repo's "no secret values
    /// in logs, errors or crash reports" rule is not at stake either way),
    /// but there is no reason to hold it.
    ///
    /// The one observable consequence: re-picking the *identical* file after
    /// a refusal now clears the banner until Create is pressed again, where
    /// before the subject compared equal and the banner stayed. That is the
    /// same "err toward forgetting" this type's doc comment already argues
    /// for, applied to one more case.
    private func forgetLastCreateFailure() {
        lastCreateFailure = nil
    }

    // MARK: - What would be created, right now

    /// The `GovernedPlan` a create attempt would actually use right now —
    /// either a resolved rule's own recipients, or, when the resolver had
    /// nothing to offer (`.noConfig`/`.noRuleMatched`), the recipients the
    /// user has chosen by hand in `manuallyChosenRecipients`. `nil` for
    /// every other case: `plan` not yet resolved for `relativeName` (see
    /// `currentSubject()`'s own comment on why that check matters), no
    /// `plan` at all, `.noConfig`/`.noRuleMatched` with nothing chosen yet,
    /// or one of the two blocking cases (`.unsupportedRule`,
    /// `.configUnreadable`).
    ///
    /// This is the one place `manuallyChosenRecipients` is read for anything
    /// that matters to `create()` — see that property's own doc comment for
    /// why folding it in here, rather than adding it as a field on
    /// `AttemptSubject`, is what makes it join the invalidation guarantee
    /// automatically instead of by a second, separately-maintained rule.
    /// `encryptedRegex` is `""` for the manually-chosen case — "encrypt
    /// everything", the same default `SopsConfigGenerator.propose` builds
    /// (it never sets `encrypted_regex` either), so a file created before
    /// any `.sops.yaml` write and one created after `RecipientPicker`
    /// writes the proposed config are encrypted identically.
    private func currentGovernedPlan() -> GovernedPlan? {
        guard let resolution, resolution.name == relativeName, let plan = resolution.plan else { return nil }
        switch plan {
        case .governedByRule(let recipients, let encryptedRegex):
            return GovernedPlan(recipients: recipients, encryptedRegex: encryptedRegex)
        case .noConfig, .noRuleMatched:
            guard !manuallyChosenRecipients.isEmpty else { return nil }
            return GovernedPlan(recipients: manuallyChosenRecipients, encryptedRegex: "")
        case .unsupportedRule, .configUnreadable:
            return nil
        }
    }

    /// The whole description of what `create()` would do if it were called
    /// this instant — `nil` when there is nothing complete enough to attempt,
    /// which is every case `readiness` already explains (`.needsName`,
    /// `.resolving`, `.needsSource`, `.needsRecipients`, or a `plan` that is
    /// neither `.governedByRule` nor a manually-chosen stand-in for one).
    ///
    /// See `AttemptSubject`'s own doc comment for why this being the single
    /// description matters.
    private func currentSubject() -> AttemptSubject? {
        guard !isBlank(relativeName) else { return nil }
        // `plan` was resolved for `resolution.name`, not necessarily for the
        // `relativeName` sitting here right now: `resolvePlan()` can be
        // mid-flight, or simply not yet re-invoked after the view's own
        // debounce (see this type's doc comment, "No debounce here"). Without
        // this check, `create()` would happily write to the *new* name using
        // a plan — recipients and `encryptedRegex` both — resolved for a
        // completely different rule. `currentGovernedPlan()` repeats this
        // same check internally; it is not skipped here as an optimization,
        // because `currentGovernedPlan()` is also called on its own
        // (`readiness`) where this guard has to hold independently.
        guard let governed = currentGovernedPlan() else { return nil }
        guard let source = currentSource() else { return nil }
        return AttemptSubject(
            name: relativeName, plan: governed, source: source, acknowledgedUnreadable: acknowledgedUnreadable)
    }

    /// The bytes `create()` would encrypt, or `nil` when the chosen source
    /// has nothing usable to offer yet.
    ///
    /// No `default` — a case added to `SourceChoice` later must fail this
    /// file's build rather than silently fall through to `.empty`'s behavior
    /// for a source nobody taught this switch about. This is also the
    /// compile-time half of the invalidation guarantee: a new source kind
    /// cannot reach `create()` without passing through here, and therefore
    /// cannot reach it without becoming part of the `AttemptSubject` that
    /// drops stale verdicts.
    private func currentSource() -> SecretFileCreator.Source? {
        switch sourceChoice {
        case .empty:
            return .empty
        case .plainYAML:
            guard let plainYAMLText else { return nil }
            return .verbatimYAML(plainYAMLText)
        case .dotEnv:
            guard let dotEnvParsed else { return nil }
            // Same condition `readiness` reports `.blocked` for — see
            // `Self.hasNoUsableDotEnvContent(_:)`'s own doc comment for why
            // this is not simply "entries is empty".
            guard !Self.hasNoUsableDotEnvContent(dotEnvParsed) else { return nil }
            // `.entries` only — `SecretFileCreator` never sees `.skipped`
            // or `.suspicions`, the same way `DotEnvPreviewTable` renders
            // them but never lets them change what actually gets written
            // (see that view's own doc comment). A skipped line is a line
            // this app could not read as an assignment at all; there is
            // nothing to encrypt it *as*.
            return .dotEnv(dotEnvParsed.entries)
        case .encryptedYAML:
            // Reads `encryptedImportOutcome` directly rather than through the
            // public `encryptedImport` — that computed property reports a
            // *diff*, never the plaintext behind it (see its own doc
            // comment); this is the one place `UnlockedImport.decryptedText`
            // is ever read, and it goes straight into `.verbatimYAML(_:)`,
            // exactly decision 4 in this task's brief: once decrypted, an
            // imported file is plain YAML like any other, and
            // `SecretFileCreator` needs no dedicated case for it.
            guard let chosenEncryptedFileURL,
                case .unlocked(let unlocked)? = encryptedImportOutcome?.value(ifStillAbout: chosenEncryptedFileURL.path)
            else { return nil }
            return .verbatimYAML(unlocked.decryptedText)
        }
    }

    // MARK: - Creating

    /// Creates the file `relativeName` names under `projectRoot`, encrypted
    /// for the current plan's recipients. Returns the created file's URL, or
    /// `nil` on any refusal.
    ///
    /// Where the reason for a refusal lives depends on the refusal, and the
    /// three cases are deliberately different — an earlier version of this
    /// doc comment claimed "the reason is then in `planError`" for all of
    /// them, which is how a maintainer reconciling code to prose would
    /// reintroduce a defect this task closed:
    ///
    /// - **Nothing was complete enough to attempt** (`currentSubject()` is
    ///   `nil`: a blank name, a plan resolved for a different name, a plan
    ///   that is not `.governedByRule`, a source with nothing loaded). No
    ///   reason is recorded, because `readiness` already says which of those
    ///   it is and a caller following `readiness` never gets here. Guarded
    ///   rather than trusted all the same — nothing stops a caller from
    ///   invoking this regardless of `readiness`.
    /// - **`wouldBeUnreadable`, not yet acknowledged.** Recorded as
    ///   `unreadability`; `readiness` becomes `.needsAcknowledgement` and
    ///   `planError` stays `nil`. Nothing renders a failure sentence in that
    ///   state, and a sentence left here would hide the checkbox behind a
    ///   banner — the third of this task's four instances.
    /// - **Every other refusal.** Recorded as `lastCreateFailure`, filed
    ///   under the exact `AttemptSubject` it refused, and surfaced through
    ///   both `planError` and `readiness` for exactly as long as that subject
    ///   is still what would be created.
    public func create() async -> URL? {
        guard let subject = currentSubject() else { return nil }

        let destination = projectRoot.appendingPathComponent(subject.name)
        let resolved = ResolvedEncryption(
            recipients: subject.plan.recipients, encryptedRegex: subject.plan.encryptedRegex,
            acknowledgedUnreadable: subject.acknowledgedUnreadable)

        // `withKey` lends the identity for exactly this call; nothing here
        // copies it out anywhere else — see `SessionKeyStore`'s own doc
        // comment, "Why `withKey` instead of a getter".
        let outcome: Result<AtomicWriteReceipt, SecretFileCreator.Failure>? = keyStore.withKey { key in
            do {
                return .success(
                    try SecretFileCreator.create(
                        subject.source, plan: resolved, at: destination, in: projectRoot, sessionKey: key))
            } catch let failure as SecretFileCreator.Failure {
                return .failure(failure)
            } catch {
                // `SecretFileCreator.create` is documented to throw only
                // `Failure` — not expected to be reachable in practice, but
                // a caller must never see this fail silently for a type it
                // did not anticipate. `.engine` is the case built for
                // exactly this: arbitrary diagnostic text.
                return .failure(.engine("\(error)"))
            }
        }

        guard let outcome else {
            // `withKey` found no key to lend — `keyStore.state` is therefore
            // not `.configured` at this exact moment (see `SessionKeyStore
            // .state`), so `.empty` is the honest, structural fact here
            // rather than a guess. `message(forEmptyKeyStore:)` is
            // documented to return non-nil for every case but `.configured`;
            // the `if let` still handles the `nil` branch rather than
            // force-unwrapping, so a future change to that contract cannot
            // crash this call.
            if let message = CreationFailurePresenter.message(forEmptyKeyStore: .empty) {
                lastCreateFailure = Learned(message, about: subject)
            }
            return nil
        }

        switch outcome {
        case .success(let receipt):
            lastCreateFailure = nil
            unreadability = nil
            return receipt.destination
        case .failure(let failure):
            if case .wouldBeUnreadable = failure, !subject.acknowledgedUnreadable {
                // See this method's own doc comment for why no message is
                // recorded on this branch. Filed under the plan rather than
                // the whole subject: what was discovered is a fact about the
                // recipient set, and re-picking a source file must not
                // discard the checkbox it earns.
                unreadability = Learned(true, about: subject.plan)
                lastCreateFailure = nil
            } else {
                lastCreateFailure = Learned(CreationFailurePresenter.message(for: failure), about: subject)
            }
            return nil
        }
    }

    // MARK: - A .sops.yaml for a project that has none yet

    /// Builds a `.sops.yaml` proposal that would govern `relativeName`, for
    /// exactly `manuallyChosenRecipients` — the one way this model ever
    /// produces `.sops.yaml` text, and it never writes it; see
    /// `SopsConfigGenerator`'s own doc comment, "Never writes the config".
    /// `RecipientPicker` shows the result to the user and, only on their
    /// separate confirmation, calls `writeProposedConfig()`.
    ///
    /// Files the result under `lastProposal`, keyed to exactly the name and
    /// recipient set this call built it for — see `ProposalSubject`'s own
    /// doc comment. `writeProposedConfig()` reads this back rather than
    /// trusting whatever `ProposedConfig` a caller happens to be holding, so
    /// a proposal can only be written while it is still the one this model
    /// would build right now.
    ///
    /// `nil` when there is nothing meaningful to propose: a blank name, or
    /// no recipient chosen yet — and `lastProposal` is cleared in that case
    /// too, so a stale proposal from before the selection was emptied
    /// cannot be written either. `SopsConfigGenerator.propose` already
    /// refuses an empty recipient list on its own (`verified: false` — see
    /// that type's own doc comment, "Why `verified` is proven, not
    /// asserted", and the Important finding it closes), but that refusal is
    /// the *last* line of defense, not the only one: this guard is this
    /// model's own, so `RecipientPicker`'s propose control can simply stay
    /// disabled for an empty selection rather than firing a real bridge
    /// round trip for an answer already known without asking. Nothing about
    /// this guard is a way to *avoid* that refusal — `SopsConfigGeneratorTests
    /// .emptyRecipientsIsRefused` still exercises it directly, unconditionally.
    public func proposeConfig() async -> ProposedConfig? {
        guard !isBlank(relativeName), !manuallyChosenRecipients.isEmpty else {
            lastProposal = nil
            return nil
        }
        let subject = ProposalSubject(name: relativeName, recipients: manuallyChosenRecipients)
        let target = projectRoot.appendingPathComponent(relativeName)
        let proposed: ProposedConfig
        do {
            proposed = try SopsConfigGenerator.propose(
                forTarget: target, in: projectRoot, recipients: manuallyChosenRecipients)
        } catch let error as SopsConfigGenerator.Error {
            // Not expected to be reachable through this call site:
            // `relativeName` already resolved to `.noConfig`/`.noRuleMatched`
            // through `CreationPlanResolver.plan(forTarget:in:)`, whose own
            // absolute-path and containment checks are the identical ones
            // `SopsConfigGenerator.propose` would throw on here — see
            // `SopsConfigGenerator`'s own doc comment, "Containment is
            // enforced here, independently of `SecretFileCreator`", whose
            // closing paragraph names this exact mirroring on purpose.
            // Handled rather than assumed impossible: translated through the
            // one presenter every other failure in this file goes through,
            // as an unverified proposal — nothing here is silently dropped.
            proposed = ProposedConfig(
                text: "", verified: false, reason: CreationFailurePresenter.message(for: error).detail)
        } catch {
            // `propose` is documented to throw only `Error` — not expected
            // in practice, but a caller must never see this fail silently
            // for a type it did not anticipate. See the identical discipline
            // in `resolvePlan()`'s own catch-all.
            proposed = ProposedConfig(
                text: "", verified: false, reason: "The proposed .sops.yaml could not be built: \(error)")
        }
        lastProposal = Learned(proposed, about: subject)
        return proposed
    }

    /// What `writeProposedConfig()` actually did — a dedicated enum
    /// rather than `Result<Void, CreationFailureMessage>`, because
    /// `CreationFailureMessage` is a plain value type used all over this
    /// wizard for reasons that have nothing to do with `Swift.Error`, and
    /// giving it that conformance just to satisfy `Result` would be a
    /// second, wider-reaching change for one call site. Mirrors
    /// `ProjectAccessModel.ConfigApplyOutcome`'s own shape for the identical
    /// reason.
    public enum ConfigWriteOutcome: Equatable, Sendable {
        case written
        case refused(CreationFailureMessage)
    }

    /// Writes the most recently proposed `.sops.yaml` — the confirmed half
    /// of the two-act split `SopsConfigGenerator.propose`'s own doc comment
    /// describes ("deciding is not the same act as writing it down"). Only
    /// ever reached after a caller has shown the proposed text to the user
    /// and received explicit confirmation to write it; `RecipientPicker` is
    /// that caller.
    ///
    /// Takes **no parameter**. An earlier version took the `ProposedConfig`
    /// straight from the caller — closed for two reasons the review that
    /// found them named directly:
    ///
    /// 1. **Forgeability.** `ProposedConfig`'s public memberwise init lets
    ///    any caller construct `verified: true` for text
    ///    `SopsConfigGenerator` never actually produced or checked. Reading
    ///    from `lastProposal` instead means the only `ProposedConfig` this
    ///    method can ever write is one `proposeConfig()` itself built and
    ///    `SopsConfigGenerator` itself verified.
    /// 2. **Staleness.** A caller-supplied `ProposedConfig` carries no
    ///    subject — nothing naming the recipients or target it was built
    ///    for — so a UI holding one has no way to notice the user changed
    ///    the selection or the name in between, short of remembering to
    ///    clear its own state at every place that could invalidate it.
    ///    `RecipientPicker` tried exactly that and missed one (its remove
    ///    button). Reading `lastProposal?.value(ifStillAbout:)` against the
    ///    *current* `relativeName`/`manuallyChosenRecipients` makes that
    ///    class of miss structurally impossible rather than a discipline to
    ///    maintain across however many mutation sites this view ends up
    ///    with — the identical guarantee `Learned<Subject, Value>` already
    ///    gives `unreadability`/`lastCreateFailure` for `create()`.
    ///
    /// `.refused(CreationFailurePresenter.messageForStaleProposal())` when
    /// there is no proposal on file for the current name/selection, or when
    /// the one on file is for a different one. Worded there, not here — an
    /// earlier version composed this sentence inline, which is exactly the
    /// model-local-sentence mistake this task's own review already caught
    /// once for `.unsupportedRule`/`.configUnreadable`'s unreachable
    /// fallback; this one is reachable (it is the primary refusal path of
    /// this whole guard), which makes the presenter's rule apply even more
    /// directly, not less.
    ///
    /// `.absent`: a project with no `.sops.yaml` at all is exactly the
    /// precondition this whole flow exists for (`RecipientPicker`'s write
    /// control is offered only for `.noConfig`) — `.matching` would need a
    /// fingerprint this model never read, since it never read a
    /// `.sops.yaml` that did not exist, and `.unchecked` would silently
    /// clobber whatever another writer had just created there. See
    /// `AtomicFileWriter`'s own doc comment, "A third case: the destination
    /// must not exist at all".
    ///
    /// Never calls `resolvePlan()` on success: a fresh resolve is what
    /// actually notices the new `.sops.yaml` governs `relativeName` now, but
    /// deciding when to ask for that is `RecipientPicker`'s job, not this
    /// method's — the same split `ProjectAccessModel.applyConfig()`'s own
    /// doc comment draws between writing and re-planning. `lastProposal` is
    /// cleared on a successful write either way — the proposal has been
    /// consumed, and holding onto it would let a *second* call write the
    /// identical text again for an `.absent` check that would now correctly
    /// refuse, which is not a state worth preserving.
    @discardableResult
    public func writeProposedConfig() -> ConfigWriteOutcome {
        let subject = ProposalSubject(name: relativeName, recipients: manuallyChosenRecipients)
        guard let proposal = lastProposal?.value(ifStillAbout: subject) else {
            return .refused(CreationFailurePresenter.messageForStaleProposal())
        }
        guard proposal.verified else {
            return .refused(CreationFailureMessage(title: .creationFailureConfigTitle, detail: proposal.reason, recovery: nil))
        }
        let configURL = projectRoot.appendingPathComponent(".sops.yaml")
        do {
            _ = try AtomicFileWriter.write(proposal.text, to: configURL, expecting: .absent)
            lastProposal = nil
            return .written
        } catch let error as AtomicFileWriter.Error {
            return .refused(CreationFailurePresenter.message(forConfigWriteFailure: error))
        } catch {
            // `AtomicFileWriter.write` is documented to throw only `Error` —
            // not expected in practice, but handled rather than assumed
            // unreachable, the same discipline every catch-all in this file
            // follows.
            return .refused(CreationFailureMessage(title: .creationFailureConfigTitle, detail: "\(error)", recovery: nil))
        }
    }

    // MARK: - Readiness

    /// Computed on every read — see this type's doc comment, "No verdict is
    /// ever stored". Nothing assigns this, and nothing may: the whole point
    /// is that there is no stored value to fall out of step with the inputs
    /// below.
    ///
    /// No `default` in either switch — a case added to `SourceChoice` or
    /// `CreationPlan` later must fail this file's build rather than silently
    /// pass through.
    public var readiness: Readiness {
        guard !isBlank(relativeName) else { return .needsName }

        switch sourceChoice {
        case .empty:
            break
        case .plainYAML:
            if let plainYAMLLoadError { return .blocked(plainYAMLLoadError) }
            guard plainYAMLText != nil else { return .needsSource }
        case .dotEnv:
            if let dotEnvLoadError { return .blocked(dotEnvLoadError) }
            guard let dotEnvParsed else { return .needsSource }
            // A genuinely empty or comments-only `.env` (both empty) is
            // fine — see `Self.hasNoUsableDotEnvContent(_:)`'s own doc
            // comment for why that case is deliberately excluded here.
            if Self.hasNoUsableDotEnvContent(dotEnvParsed) {
                return .blocked(CreationFailurePresenter.message(forDotEnvWithNoUsableEntries: ()))
            }
        case .encryptedYAML:
            // `.notChosen`/`.locked` both mean there is nothing yet to
            // create from — the same `.needsSource` every other source
            // reports before it has content. `.unlockFailed` is a real
            // refusal, worded by `CreationFailurePresenter` inside
            // `unlockChosenEncryptedFile()`, so it renders through
            // `.blocked` exactly like `plainYAMLLoadError`/`dotEnvLoadError`
            // above — a failed unlock stops here and never reaches the
            // key-store/plan checks below. `.unlockedAwaitingPlan`/`.unlocked`
            // both fall through: the plan/resolution checks immediately
            // below are exactly what decide whether a target is known at
            // all, so this switch does not duplicate that question — it
            // only asks whether *unlocking* succeeded. A target-less decrypt
            // reaches the `.resolving`/`.needsRecipients`/`.blocked` guards
            // below precisely because nothing here short-circuits past them;
            // `.unlocked` reaches the identical round-trip/acknowledgement
            // handling every other loaded source already gets.
            switch encryptedImport {
            case .notChosen, .locked:
                return .needsSource
            case .unlockFailed(let message):
                return .blocked(message)
            case .unlockedAwaitingPlan, .unlocked:
                break
            }
        }

        if let keyMessage = CreationFailurePresenter.message(forEmptyKeyStore: keyStore.state) {
            return .blocked(keyMessage)
        }

        // Nothing in hand describes *this* name yet. Deliberately not the
        // previous name's verdict; see `Readiness.resolving`.
        guard let resolution, resolution.name == relativeName else { return .resolving }
        if let error = resolution.error { return .blocked(error) }
        guard let plan = resolution.plan else {
            // Unreachable: a `Resolution` with neither a plan nor an error is
            // only produced by the blank-name short circuit in
            // `resolvePlan()`, and a blank name already returned `.needsName`
            // above. Handled rather than force-unwrapped.
            return .needsName
        }

        switch plan {
        case .governedByRule:
            // `currentGovernedPlan()` re-derives the identical
            // `GovernedPlan` from `resolution` — see that method's own doc
            // comment. Never `nil` here: this branch already established
            // `resolution.plan` is `.governedByRule` for `resolution.name
            // == relativeName` (the `guard` above this switch), which is
            // exactly what `currentGovernedPlan()` itself checks first.
            // Handled rather than force-unwrapped all the same, so a future
            // change to either method's guard cannot crash this call.
            guard let governed = currentGovernedPlan() else { return .needsName }
            return readiness(for: governed)
        case .noConfig, .noRuleMatched:
            // Neither is a failure — see `CreationPlanResolver.plan`'s own
            // doc comment. `RecipientPicker` is what a user facing either
            // one actually sees; `.needsRecipients` is what puts it on
            // screen. The moment `manuallyChosenRecipients` is non-empty,
            // `currentGovernedPlan()` starts returning a real value and this
            // falls through to the identical path `.governedByRule` takes —
            // same round-trip discovery, same `create()` failures.
            guard let governed = currentGovernedPlan() else { return .needsRecipients }
            return readiness(for: governed)
        case .unsupportedRule, .configUnreadable:
            // `CreationFailurePresenter.message(forBlocking:)` is documented
            // to return non-nil for exactly these two cases — unreachable,
            // handled rather than force-unwrapped so a future change to
            // that contract fails loudly instead of crashing this call. See
            // `CreationFailurePresenter`'s own doc comment, "Every switch
            // below has no default", for why this switch needs no
            // `default` either: a case added later to `CreationPlan` must
            // fail this file's build, not fall through silently. There is
            // no more dated local fallback to reuse here — Task 4's
            // `noPickerYetMessage` covered `.noConfig`/`.noRuleMatched`
            // only, and both are handled above now that `RecipientPicker`
            // exists.
            guard let message = CreationFailurePresenter.message(forBlocking: plan) else {
                return .blocked(CreationFailurePresenter.messageForUnexpectedlyUnblockedPlan())
            }
            return .blocked(message)
        }
    }

    /// The shared verdict for a `GovernedPlan` in hand right now — whichever
    /// of the two sources produced it, a resolved rule or the
    /// manually-chosen recipients `currentGovernedPlan()` stands in with.
    /// Read `readiness`'s own two call sites for why both reach this through
    /// the same `GovernedPlan` value rather than two copies of this logic:
    /// `unreadability`/`lastCreateFailure` are filed under `GovernedPlan`/
    /// `AttemptSubject`, not under which of the two sources produced
    /// `governed`, so a manually-chosen set earns the identical discovery
    /// and refusal handling a resolved rule already has, with nothing here
    /// caring which one it was.
    private func readiness(for governed: GovernedPlan) -> Readiness {
        // A refusal from the last attempt, but only while that attempt is
        // still the one that would happen. `currentSubject()` rebuilds
        // what would be created right now; `value(ifStillAbout:)` returns
        // nothing when it has changed.
        if let subject = currentSubject(), let failure = lastCreateFailure?.value(ifStillAbout: subject) {
            return .blocked(failure)
        }
        if unreadability?.value(ifStillAbout: governed) == true, !acknowledgedUnreadable {
            return .needsAcknowledgement
        }
        return .ready(recipients: governed.recipients)
    }

    /// Whether `name` is empty once surrounding whitespace is stripped.
    /// Plain `isEmpty` alone let a name of all spaces (`"   "`) pass every
    /// guard that used it and reach `CreationPlanResolver.plan` — a real
    /// path component, just not a name anyone typed on purpose.
    private func isBlank(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether `parsed` has candidate lines that looked like assignments and
    /// very plausibly held secrets (`skipped`, non-empty), but salvaged none
    /// of them (`entries`, empty) — the state
    /// `CreationFailurePresenter.message(forDotEnvWithNoUsableEntries:)`
    /// exists to refuse.
    ///
    /// Deliberately **not** `parsed.entries.isEmpty` alone: a genuinely
    /// empty or comments-only `.env` file has `skipped.isEmpty` too, and
    /// `FlatYAMLEmitter.emit([])` already treats an empty entry list as a
    /// legitimate `"{}\n"` document — the same one `.empty`'s own source
    /// produces. That case is not a bug being caught here; only the one
    /// where lines existed and none of them survived is.
    static func hasNoUsableDotEnvContent(_ parsed: ParsedDotEnv) -> Bool {
        parsed.entries.isEmpty && !parsed.skipped.isEmpty
    }
}
