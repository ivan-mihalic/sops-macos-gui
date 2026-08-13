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
/// `discoveredUnreadable` records that one fact for the plan currently in
/// hand, and `readiness` reports `.needsAcknowledgement` from that point
/// until `acknowledgedUnreadable` is set. Nothing in this type ever tries to
/// guess the answer ahead of that call.
///
/// ## `Readiness.ready(recipients:)` carries only what gets displayed
///
/// `ResolvedEncryption` — which also needs `encryptedRegex` — is built fresh
/// inside `create()` from `plan`, never carried on `Readiness` itself. If
/// `Readiness` carried it too, there would be two sources of truth about
/// what the file is about to be encrypted with.
///
/// ## No debounce here
///
/// `resolvePlan()` runs once per call and neither waits for, nor coalesces,
/// anything on its own. `NewSecretFileSheet` (Task 4) owns the 200 ms
/// debounce and its own cancellation as the user types — a model that
/// debounced itself could not be driven directly from a test without
/// actually waiting out the debounce.
@MainActor
@Observable
public final class NewSecretFileModel {

    /// Which kind of content a not-yet-created file would start from.
    /// `.empty`, `.plainYAML` and `.dotEnv` are fully implemented — see
    /// `loadPlainYAML(from:)`/`loadDotEnv(from:)` and `create()`'s own
    /// switch. `.encryptedYAML` alone still reports `.needsSource`
    /// unconditionally: it needs unlocking the file and diffing who would
    /// gain or lose access, which Task 6 adds.
    public enum SourceChoice: Equatable, Sendable, CaseIterable {
        case empty, plainYAML, encryptedYAML, dotEnv
    }

    /// What clicking Create would do right now.
    public enum Readiness: Equatable, Sendable {
        case needsName
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

    public let projectRoot: URL
    /// No property observer here (unlike `acknowledgedUnreadable` below):
    /// changing this does not refresh `readiness` on its own —
    /// `NewSecretFileSheet` calls `resolvePlan()` (an equivalent recompute)
    /// on every change, the same way it does for `relativeName`. Until that
    /// call happens, changing this only takes effect the next time
    /// `readiness` is recomputed by any means (`resolvePlan()`,
    /// `loadPlainYAML(from:)`, `loadDotEnv(from:)`).
    public var sourceChoice: SourceChoice = .empty
    public var relativeName: String = ""
    public private(set) var plan: CreationPlan?

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

    /// The reason the most recent `resolvePlan()` or `create()` call could
    /// not proceed: a thrown `CreationPlanResolver.Error` in the first case,
    /// a thrown `SecretFileCreator.Failure` in the second — always turned
    /// into text through `CreationFailurePresenter`, never composed here.
    /// `nil` after a resolve or create that did not fail this way (`plan`
    /// resolving to `.noConfig`/`.noRuleMatched` is not this kind of
    /// failure — see `computeReadiness()`).
    public private(set) var planError: CreationFailureMessage?
    public private(set) var isResolving = false

    /// Set by the user once `readiness` has reported `.needsAcknowledgement`.
    /// Setting it to `true` while still in that state resolves `readiness`
    /// back to `.ready(recipients:)` immediately, without waiting for
    /// another `resolvePlan()` call — see the property observer below.
    public var acknowledgedUnreadable = false {
        didSet {
            guard acknowledgedUnreadable, !oldValue else { return }
            guard case .needsAcknowledgement = readiness,
                case .governedByRule(let recipients, _) = plan
            else { return }
            // The `.wouldBeUnreadable` message `create()` left in `planError`
            // described exactly the state this acknowledgement just resolved
            // — leaving it in place would show a failure banner next to a
            // readiness that now says nothing is blocking.
            planError = nil
            readiness = .ready(recipients: recipients)
        }
    }

    public private(set) var readiness: Readiness = .needsName

    private let keyStore: SessionKeyStore

    /// Whether `create()` has already discovered, for the `plan` currently
    /// in hand, that this session's key could not be proven to be among its
    /// recipients. Reset at the top of every `resolvePlan()` call, alongside
    /// `acknowledgedUnreadable` (see that reset's own comment in
    /// `resolvePlan()`) — a freshly resolved plan, even one that resolves to
    /// the exact same rule again, has not itself been tried yet, so nothing
    /// has actually been discovered about *it*, and nothing about it has
    /// been acknowledged either. See this type's doc comment for why this
    /// can only be learned by attempting `create()`, never predicted ahead
    /// of time.
    private var discoveredUnreadable = false

    /// The `relativeName` that `plan` was actually resolved for. `create()`
    /// compares this against the live `relativeName` and refuses on a
    /// mismatch, rather than trusting the caller: `resolvePlan()` can be
    /// mid-flight (`isResolving`) or simply not yet re-invoked after the
    /// view's own debounce (see this type's doc comment, "No debounce
    /// here") when `relativeName` changes, and without this check `create()`
    /// would happily write to the *new* name using a `plan` — recipients and
    /// `encryptedRegex` both — that was resolved for a completely different
    /// rule. Set alongside `plan`/`planError` at the end of every
    /// `resolvePlan()` call, including the empty-name short circuit.
    ///
    /// `public private(set)` since Task 4: `NewSecretFileSheet` reads this
    /// to guard its own debounced resolve — a resolve is skipped whenever
    /// the name it would resolve for is already the one this reports,
    /// which is exactly how it avoids reflexively discarding a fresh
    /// `acknowledgedUnreadable` tick between it and a redundant resolve for
    /// an unchanged name. See that view's own doc comment, "The debounce,
    /// and why it checks `resolvedName` before firing".
    public private(set) var resolvedName: String?

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

    /// Recomputes `plan` for `relativeName` under `projectRoot`, and
    /// `readiness` from the result. Called by the view; see this type's doc
    /// comment, "No debounce here".
    public func resolvePlan() async {
        // A fresh resolve means nothing has been discovered — or
        // acknowledged — yet about whatever plan comes back.
        //
        // Resetting `acknowledgedUnreadable` here, not only
        // `discoveredUnreadable`, closes a real hole: without it, ticking
        // the box for one name (say `secret.yaml`, whose rule excludes this
        // session's key) stayed `true` after the name changed to a second,
        // differently-governed one (`other.yaml`, excluded by a *different*
        // rule). `create()` passes `acknowledgedUnreadable` straight into
        // `ResolvedEncryption`, and `SecretFileCreator.create` treats it as
        // "skip the refusal *and* skip all content verification,
        // unconditionally" — so the second file would have been written
        // blind, for a plan the user was never actually warned about. See
        // this type's doc comment, "Self-readability cannot be predicted,
        // only discovered": an acknowledgement is an answer to one specific
        // round-trip attempt, not a standing waiver, and it must not survive
        // past the plan it was given for.
        discoveredUnreadable = false
        acknowledgedUnreadable = false

        // `CreationPlanResolver.plan(forTarget:in:)` must never be asked
        // about `projectRoot` itself: an empty (or whitespace-only — a
        // name of all spaces is not a name either) `relativeName` would
        // make `target` and `projectRoot` the identical URL, and every
        // rule's `path_regex` would then be matched against the project
        // root's own path rather than against nothing at all.
        // Short-circuiting here means that call is never made with a name
        // the user has not actually typed anything meaningful into yet.
        guard !isBlank(relativeName) else {
            plan = nil
            planError = nil
            resolvedName = relativeName
            readiness = computeReadiness()
            return
        }

        isResolving = true
        defer { isResolving = false }

        let target = projectRoot.appendingPathComponent(relativeName)
        do {
            plan = try CreationPlanResolver.plan(forTarget: target, in: projectRoot)
            planError = nil
        } catch let error as CreationPlanResolver.Error {
            plan = nil
            planError = CreationFailurePresenter.message(for: error)
        } catch {
            // `CreationPlanResolver.plan(forTarget:in:)` is documented to
            // throw only `Error` — not expected to be reachable in practice,
            // but a caller must never see this fail silently for a type it
            // did not anticipate.
            plan = nil
            planError = CreationFailureMessage(
                title: .creationFailureTitle, detail: "\(error)", recovery: nil)
        }

        resolvedName = relativeName
        readiness = computeReadiness()
    }

    /// Reads `url` and stores its verbatim text as `plainYAMLText`, or
    /// records why it could not. The one read this file ever does for a
    /// `.plainYAML` source — `create()` uses `plainYAMLText`, never
    /// re-reads `url`, so what the user previewed (once `NewSecretFileSheet`
    /// renders it) is exactly what gets encrypted, not whatever the file
    /// happens to contain the moment Create is pressed.
    ///
    /// Recomputes `readiness` synchronously at the end — unlike
    /// `resolvePlan()`, there is no bridge call here to justify a debounce,
    /// so the view calls this directly from its file picker rather than
    /// through `resolveDebounced()`.
    public func loadPlainYAML(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                plainYAMLText = nil
                plainYAMLLoadError = CreationFailurePresenter.message(forUnreadableSourceFile: ())
                readiness = computeReadiness()
                return
            }
            plainYAMLText = text
            plainYAMLLoadError = nil
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
        readiness = computeReadiness()
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
    /// Recomputes `readiness` synchronously at the end, for the same reason
    /// `loadPlainYAML(from:)` does.
    public func loadDotEnv(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            dotEnvParsed = try DotEnvParser.parse(data)
            dotEnvLoadError = nil
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
        readiness = computeReadiness()
    }

    /// Creates the file `relativeName` names under `projectRoot`, encrypted
    /// for `plan`'s recipients. Returns the created file's URL, or `nil` on
    /// any refusal — the reason is then in `planError`.
    ///
    /// Only meaningful when `plan` is `.governedByRule`: every other `plan`
    /// value already means `readiness` is neither `.ready` nor
    /// `.needsAcknowledgement`, so there is nothing a caller following
    /// `readiness` would ever ask this to do. Still guarded explicitly
    /// rather than trusted, because nothing stops a caller from invoking
    /// this directly regardless of `readiness`.
    public func create() async -> URL? {
        // No `default` — a case added to `SourceChoice` later must fail this
        // file's build rather than silently fall through to `.empty`'s
        // behavior for a source nobody taught this switch about.
        let source: SecretFileCreator.Source
        switch sourceChoice {
        case .empty:
            source = .empty
        case .plainYAML:
            // `readiness` already reports `.needsSource` whenever this is
            // `nil` (see `computeReadiness()`), so a caller following
            // `readiness` never reaches here without it — guarded anyway
            // rather than trusted, same discipline every guard below keeps.
            guard let plainYAMLText else { return nil }
            source = .verbatimYAML(plainYAMLText)
        case .dotEnv:
            guard let dotEnvParsed else { return nil }
            // Same guard `computeReadiness()` already applies — repeated
            // here rather than trusted, same discipline every guard in this
            // switch keeps. See `Self.hasNoUsableDotEnvContent(_:)`'s own
            // doc comment for why this is not simply "entries is empty".
            guard !Self.hasNoUsableDotEnvContent(dotEnvParsed) else { return nil }
            // `.entries` only — `SecretFileCreator` never sees `.skipped`
            // or `.suspicions`, the same way `DotEnvPreviewTable` renders
            // them but never lets them change what actually gets written
            // (see that view's own doc comment). A skipped line is a line
            // this app could not read as an assignment at all; there is
            // nothing to encrypt it *as*.
            source = .dotEnv(dotEnvParsed.entries)
        case .encryptedYAML:
            // Task 6 owns unlocking and importing this source. `readiness`
            // reports `.needsSource` for it unconditionally (see
            // `computeReadiness()`), so a caller following `readiness`
            // never reaches here either.
            return nil
        }

        guard !isBlank(relativeName) else { return nil }
        // `plan` was resolved for `resolvedName`, not necessarily for the
        // `relativeName` sitting here right now — see `resolvedName`'s own
        // doc comment for the exact race this closes.
        guard resolvedName == relativeName else { return nil }
        guard case .governedByRule(let recipients, let encryptedRegex) = plan else { return nil }

        let destination = projectRoot.appendingPathComponent(relativeName)
        let resolved = ResolvedEncryption(
            recipients: recipients, encryptedRegex: encryptedRegex,
            acknowledgedUnreadable: acknowledgedUnreadable)

        // `withKey` lends the identity for exactly this call; nothing here
        // copies it out anywhere else — see `SessionKeyStore`'s own doc
        // comment, "Why `withKey` instead of a getter".
        let outcome: Result<AtomicWriteReceipt, SecretFileCreator.Failure>? = keyStore.withKey { key in
            do {
                return .success(
                    try SecretFileCreator.create(
                        source, plan: resolved, at: destination, in: projectRoot, sessionKey: key))
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
                planError = message
                readiness = .blocked(message)
            }
            return nil
        }

        switch outcome {
        case .success(let receipt):
            planError = nil
            discoveredUnreadable = false
            return receipt.destination
        case .failure(let failure):
            let message = CreationFailurePresenter.message(for: failure)
            planError = message
            if case .wouldBeUnreadable = failure, !acknowledgedUnreadable {
                // The one discovery this model is allowed to make about
                // self-readability — see this type's doc comment,
                // "Self-readability cannot be predicted, only discovered".
                discoveredUnreadable = true
                readiness = .needsAcknowledgement
            } else {
                readiness = .blocked(message)
            }
            return nil
        }
    }

    // MARK: - Readiness

    private func computeReadiness() -> Readiness {
        guard !isBlank(relativeName) else { return .needsName }

        // No `default` — a case added to `SourceChoice` later must fail
        // this file's build rather than silently pass through as `.empty`.
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
        if let planError { return .blocked(planError) }
        guard let plan else {
            // Unreachable via `resolvePlan()`'s own flow: by the time this is
            // called, either `planError` was just set above (handled by the
            // branch above this one) or `plan` resolved successfully.
            // Handled rather than force-unwrapped so a future caller of this
            // private function cannot crash the app.
            return .needsName
        }

        switch plan {
        case .governedByRule(let recipients, _):
            // Not `discoveredUnreadable` alone. `acknowledgedUnreadable`'s
            // own `didSet` already handles the *direct* path out of
            // `.needsAcknowledgement` (tick the box while `readiness` is
            // already `.needsAcknowledgement` → `.ready` immediately, no
            // `computeReadiness()` call needed) — but it does not clear
            // `discoveredUnreadable` itself, only `resolvePlan()` and a
            // successful `create()` do that. So a *second* path into this
            // function — `loadPlainYAML(from:)`/`loadDotEnv(from:)`
            // recomputing `readiness` after the box is already ticked, e.g.
            // from picking a different source file — would read
            // `discoveredUnreadable` alone as still `true` and reintroduce
            // `.needsAcknowledgement` with the checkbox still showing
            // ticked (the view binds straight to `acknowledgedUnreadable`).
            // Re-ticking an already-`true` checkbox is a no-op per the
            // `didSet` guard above, so that would be the exact "loop with no
            // visible exit" this type's doc comment describes elsewhere —
            // arrived at through a different door. Checking
            // `!acknowledgedUnreadable` here closes it for every caller of
            // `computeReadiness()`, not just the one that exposed it.
            return discoveredUnreadable && !acknowledgedUnreadable
                ? .needsAcknowledgement : .ready(recipients: recipients)
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
