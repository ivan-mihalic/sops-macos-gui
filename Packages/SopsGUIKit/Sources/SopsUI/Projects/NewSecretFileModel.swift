import Foundation
import Observation
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

    /// Which kind of content a not-yet-created file would start from.
    /// `.empty`, `.plainYAML` and `.dotEnv` are fully implemented — see
    /// `loadPlainYAML(from:)`/`loadDotEnv(from:)` and `currentSource()`'s own
    /// switch. `.encryptedYAML` alone still reports `.needsSource`
    /// unconditionally: it needs unlocking the file and diffing who would
    /// gain or lose access, which Task 6 adds.
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
        case ready(recipients: [String])
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
    struct AttemptSubject: Equatable {
        let name: String
        let plan: GovernedPlan
        let source: SecretFileCreator.Source
        let acknowledgedUnreadable: Bool
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

    /// `CreationPlan.noConfig` and `.noRuleMatched` are deliberately not
    /// failures from `CreationFailurePresenter`'s point of view — its own
    /// doc comment says a project in either state is one this app is
    /// "equipped to handle by falling back to the picker" Task 5 adds. That
    /// picker does not exist yet in this task, so until it does this model
    /// treats both the same way `.unsupportedRule` already is: refused, and
    /// named honestly, closing with the same "this app cannot do this yet,
    /// sops still can" sentence `CreationPlanResolver.nonAgeBackendsReason`/
    /// `.scopingFieldReason` already use.
    private static let noPickerYetMessage = CreationFailureMessage(
        title: .creationFailureTitle,
        detail: "This app cannot yet choose who should be able to read a new file here without a matching "
            + "creation rule in .sops.yaml. Create the file with sops and it will appear here.",
        recovery: nil)

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

    /// The whole description of what `create()` would do if it were called
    /// this instant — `nil` when there is nothing complete enough to attempt,
    /// which is every case `readiness` already explains (`.needsName`,
    /// `.resolving`, `.needsSource`, or a `plan` that is not
    /// `.governedByRule`).
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
        // completely different rule.
        guard let resolution, resolution.name == relativeName else { return nil }
        guard case .governedByRule(let recipients, let encryptedRegex) = resolution.plan else { return nil }
        guard let source = currentSource() else { return nil }
        return AttemptSubject(
            name: relativeName,
            plan: GovernedPlan(recipients: recipients, encryptedRegex: encryptedRegex),
            source: source,
            acknowledgedUnreadable: acknowledgedUnreadable)
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
            // Task 6 owns unlocking and importing this source. `readiness`
            // reports `.needsSource` for it unconditionally.
            return nil
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
            // Task 6 owns unlocking and importing this source.
            return .needsSource
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
        case .governedByRule(let recipients, let encryptedRegex):
            let governed = GovernedPlan(recipients: recipients, encryptedRegex: encryptedRegex)
            // A refusal from the last attempt, but only while that attempt is
            // still the one that would happen. `currentSubject()` rebuilds
            // what would be created right now; `value(ifStillAbout:)` returns
            // nothing when it has changed.
            if let subject = currentSubject(),
                let failure = lastCreateFailure?.value(ifStillAbout: subject)
            {
                return .blocked(failure)
            }
            if unreadability?.value(ifStillAbout: governed) == true, !acknowledgedUnreadable {
                return .needsAcknowledgement
            }
            return .ready(recipients: recipients)
        case .noConfig, .noRuleMatched:
            return .blocked(Self.noPickerYetMessage)
        case .unsupportedRule, .configUnreadable:
            // `CreationFailurePresenter.message(forBlocking:)` is documented
            // to return non-nil for exactly these two cases, so the `??` is
            // unreachable — kept only so this switch needs no `default`. See
            // `CreationFailurePresenter`'s own doc comment, "Every switch
            // below has no default", for why that discipline matters here
            // too: a case added later to `CreationPlan` must fail this
            // file's build, not fall through silently.
            return .blocked(CreationFailurePresenter.message(forBlocking: plan) ?? Self.noPickerYetMessage)
        }
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
