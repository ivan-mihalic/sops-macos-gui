import Foundation
import Observation
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

    /// Which kind of content a not-yet-created file would start from. Only
    /// `.empty` is implemented by this task — `.plainYAML`, `.encryptedYAML`
    /// and `.dotEnv` exist purely so Tasks 3, 5 and 6 have somewhere to hang
    /// their own source-specific state. Choosing any of the other three
    /// reports `.needsSource` until one of those tasks lands.
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
    public var sourceChoice: SourceChoice = .empty
    public var relativeName: String = ""
    public private(set) var plan: CreationPlan?
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
    /// recipients. Reset at the top of every `resolvePlan()` call — a freshly
    /// resolved plan, even one that resolves to the exact same rule again,
    /// has not itself been tried yet, so nothing has actually been
    /// discovered about *it*. See this type's doc comment for why this can
    /// only be learned by attempting `create()`, never predicted ahead of
    /// time.
    private var discoveredUnreadable = false

    /// Note 1 from this task's own brief: without a session key nothing can
    /// be created at all, and `SecretFileCreator.create`'s round-trip
    /// verification stands on it — so an empty `SessionKeyStore` has to be a
    /// stated `.blocked` reason, never a silent or empty state.
    private static let noSessionKeyMessage = CreationFailureMessage(
        title: .creationFailureTitle,
        detail: "No key is unlocked for this session, so this app cannot verify that a new file could be "
            + "decrypted again once created. Import a key to continue.",
        recovery: nil)

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
        // A fresh resolve means nothing has been discovered yet about
        // whatever plan comes back — see `discoveredUnreadable`'s own doc
        // comment.
        discoveredUnreadable = false

        // `CreationPlanResolver.plan(forTarget:in:)` must never be asked
        // about `projectRoot` itself: an empty name would make `target` and
        // `projectRoot` the identical URL, and every rule's `path_regex`
        // would then be matched against the project root's own path rather
        // than against nothing at all. Short-circuiting here means that call
        // is never made with a name the user has not actually typed
        // anything into yet.
        guard !relativeName.isEmpty else {
            plan = nil
            planError = nil
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
        // Tasks 3, 5 and 6 add the actual source content for the other
        // three choices; until one of them lands there is nothing to build
        // a document from, and `readiness` already reports `.needsSource`
        // for exactly this reason.
        guard sourceChoice == .empty else { return nil }
        guard case .governedByRule(let recipients, let encryptedRegex) = plan else { return nil }
        guard !relativeName.isEmpty else { return nil }

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
                        .empty, plan: resolved, at: destination, in: projectRoot, sessionKey: key))
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
            // See `noSessionKeyMessage`'s own doc comment.
            planError = Self.noSessionKeyMessage
            readiness = .blocked(Self.noSessionKeyMessage)
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
        guard !relativeName.isEmpty else { return .needsName }
        guard sourceChoice == .empty else { return .needsSource }
        guard keyStore.state == .configured else { return .blocked(Self.noSessionKeyMessage) }
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
            return discoveredUnreadable ? .needsAcknowledgement : .ready(recipients: recipients)
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
}
