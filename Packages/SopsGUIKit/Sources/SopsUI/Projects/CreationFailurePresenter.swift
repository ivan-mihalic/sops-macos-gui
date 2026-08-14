import SopsHealth
import SopsProjects

/// A whole sentence for a user, built from one caller mistake or refusal
/// this app's new-file wizard can hit.
///
/// `title` and `recovery` are `LocalizedKey` — always a catalog entry, never
/// assembled text — because they never carry anything but fixed, translatable
/// copy. `detail` is a plain `String` rather than a catalog key because it is
/// the one field allowed to carry a path, a recipient count, or the bridge's
/// own diagnostic text: none of that is translatable, and forcing it through
/// the catalog would mean inventing format-string keys for values that are
/// really just interpolated. See `CreationFailurePresenter`'s own doc
/// comment for what `detail` may and may not carry.
public struct CreationFailureMessage: Equatable, Sendable {
    /// A short headline. Always `LocalizedKey`, never built text.
    public let title: LocalizedKey
    /// The whole sentence for a user. May carry a path, a key name, or text
    /// from the bridge — never a value from the document itself, and never a
    /// private identity.
    public let detail: String
    /// What the user can do next. `nil` when nothing but changing the input
    /// helps, or when `detail` already states the next step on its own (see
    /// `.write`'s case below).
    public let recovery: LocalizedKey?

    public init(title: LocalizedKey, detail: String, recovery: LocalizedKey?) {
        self.title = title
        self.detail = detail
        self.recovery = recovery
    }
}

/// Turns a refusal — or, for `CreationPlan`, a blocking answer — from any of
/// the types the new-file wizard calls in sequence — `CreationPlanResolver`,
/// `SecretFileCreator`, `SopsConfigGenerator`, `DotEnvParser` — into one
/// sentence for a user, in one voice.
///
/// ## Why one type, not a `catch` at each call site
///
/// Phase 1's final whole-branch review measured that three of these types
/// describe the same family of caller mistake in three different
/// vocabularies: `CreationPlanResolver.Error` has 4 cases,
/// `SecretFileCreator.Failure` has 7 (one of which deliberately folds 4
/// distinct causes into one — see `.destinationOutsideProject`'s own doc
/// comment), `SopsConfigGenerator.Error` has 4. The wizard calls all three in
/// sequence; if each call site wrote its own sentence, the same underlying
/// situation — say, a target outside the project — would read differently
/// depending on which of the three calls caught it first. This type is the
/// single place where any of that becomes text, so the wording is decided
/// once.
///
/// `message(forBlocking:)` joined the other four as an amendment once the
/// same review this doc comment describes noticed `CreationPlan` itself
/// belongs to the identical family: `.unsupportedRule` and
/// `.configUnreadable` are both "the wizard cannot proceed", carrying reason
/// text this presenter must not re-derive, same as `.engine` below. Left
/// out, Task 5's model would have had to build those two sentences itself —
/// precisely the scattering this type exists to prevent. `CreationPlan` is
/// an answer, not a thrown error, hence the different method name and the
/// `Optional` return — see that method's own doc comment.
///
/// `message(forEmptyKeyStore:)` is the same amendment again, one layer
/// further out: `SessionKeyStore.state` is neither a thrown error nor a
/// `CreationPlan` answer, just a fact the wizard has to have an opinion
/// about before it can do anything — and that opinion is exactly this
/// type's job, not Task 2's `NewSecretFileModel`'s. The rule this type
/// exists to enforce was never "every thrown error", it is "every sentence
/// the new-file wizard shows a user" — a *state* that permanently (not just
/// until some future task lands) prevents the wizard from proceeding
/// belongs here on the same terms a thrown error does. `NewSecretFileModel
/// .noPickerYetMessage` used to be the one accepted, dated exception: it
/// existed only because `.noConfig`/`.noRuleMatched` are deliberately *not*
/// failures from this type's point of view (see `message(forBlocking:)`'s
/// own doc comment) — until Task 5's manual recipient picker shipped, which
/// it now has: `RecipientPicker` and `NewSecretFileModel.currentGovernedPlan()`
/// handle both cases directly, and that constant is gone, not promoted, per
/// the plan this paragraph already committed to. A future state that will
/// *never* stop being a refusal — the way an empty key store never stops
/// needing a key — does not get to claim the same exception; it earns a
/// case or a method here instead, the same way `message(forConfigWriteFailure:)`
/// and `messageForStaleProposal()` below do for two more such states.
///
/// `message(forUnreadableSourceFile:)` is the case that paragraph predicted:
/// a Plain YAML or `.env` file the user picked via `NSOpenPanel` whose
/// `Data(contentsOf:)` read then fails (permissions changed, or the file was
/// moved or deleted between picking and reading) is not `.noConfig`/
/// `.noRuleMatched`'s kind of "equipped to handle later" gap — there is no
/// task that resolves it out from under this case, the same way there is
/// none for an empty key store. It earned a method here rather than a
/// second `NewSecretFileModel`-local exception, exactly as instructed.
///
/// `message(forDotEnvWithNoUsableEntries:)` is the same shape of permanent
/// state again: a `.env` file whose every candidate line was rejected has
/// nothing waiting on a future task to unlock it, so it belongs here too,
/// not as a bare `computeReadiness()` branch with its own inline text.
///
/// `message(forEncryptedImportUnlockFailure:)` (Task 6) is the fifth: an
/// `.encryptedYAML` source `SopsBridge.decryptYAML` could not open — a wrong
/// key, a genuine engine fault, or the file simply not being SOPS-encrypted
/// at all; see that method's own doc comment for why it takes the bridge's
/// own diagnostic rather than asserting which of those it was. Not one of
/// the four vocabularies either — decrypting an *import* is a
/// `NewSecretFileModel`-only bridge call none of `CreationPlanResolver`/
/// `SecretFileCreator`/`SopsConfigGenerator`/`DotEnvParseFailure` has a case
/// for — and a permanent state on the same terms as an empty key store: no
/// future task removes this refusal, a file that will not decrypt simply
/// will not decrypt.
///
/// ## Every `switch` below has no `default`
///
/// A `default` case would silently swallow a case added later to any of the
/// consumed types — and swallowing it, unnoticed, is exactly the defect this
/// type exists to prevent: a wizard that hits a case with no sentence and
/// shows nothing, or shows a stale one. The compiler is the completeness
/// check; `CreationFailurePresenterTests` checks the text.
///
/// ## Bridge text passes through unchanged
///
/// `SecretFileCreator.Failure.engine(String)` and `CreationPlan
/// .configUnreadable(reason:)` carry sops's own diagnostic. Neither is
/// rewritten, prefixed, or prettified here — `CreationPlanResolver` held the
/// identical line for the identical reason (see that type's own doc
/// comment): re-wording what sops says is how this app's understanding of a
/// failure drifts from what sops actually reports. Where a sentence below
/// wraps that text in a lead-in ("Encryption failed: …", "…could not be
/// read: …"), the bridge's own words still survive verbatim inside it.
/// `CreationPlan.unsupportedRule(reason:)` is the sibling case: not bridge
/// text, but a whole sentence `CreationPlanResolver` already composed for a
/// user — passed through as-is for the same reason.
///
/// ## What `detail` is never allowed to carry
///
/// A path, a key name, an errno-derived reason, or the bridge's own
/// diagnostic text is fine — a value from the document being created, or a
/// private identity, is not. None of the types this presenter consumes
/// actually has a case that could carry one (see each type's own doc
/// comment), so this is a property of what is fed in, not something this
/// type has to filter — but it is the invariant `CreationFailurePresenterTests
/// .noRealFailureMessageNamesTheSentinelValue` measures directly, by driving
/// a real failure through a document that contains a sentinel value.
public enum CreationFailurePresenter {

    public static func message(for error: CreationPlanResolver.Error) -> CreationFailureMessage {
        switch error {
        case .targetNotAbsolute(let path):
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "\(path) isn't a complete file path, so this app can't tell which project it "
                    + "belongs to.",
                recovery: .creationRecoveryPickLocationAgain)
        case .projectRootNotAbsolute(let path):
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "\(path) isn't a complete folder path, so this app can't tell what governs files "
                    + "inside it.",
                recovery: .creationRecoveryPickLocationAgain)
        case .projectRootDoesNotExist(let path):
            // Measured in phase 1: this case used to come back as
            // `.noConfig` — "no .sops.yaml" — which is honest for a project
            // that is really there and just has no config yet, and false for
            // one that is not reachable at all (deleted, or on an unmounted
            // volume). Naming ".sops.yaml" here would repeat that mistake in
            // this presenter's own words. See
            // `CreationFailurePresenterTests.missingRootIsNotMissingConfig`.
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "The project at \(path) could not be found. It may have been moved, deleted, "
                    + "or its disk may not be connected right now.",
                recovery: .creationRecoveryCheckProjectConnected)
        case .targetOutsideProjectRoot(let path):
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "\(path) is outside this project, so this app can't work out which rules "
                    + "would govern it.",
                recovery: .creationRecoveryChooseLocationInsideProject)
        }
    }

    public static func message(for failure: SecretFileCreator.Failure) -> CreationFailureMessage {
        switch failure {
        case .destinationExists(let path):
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "A file already exists at \(path), so nothing was overwritten.",
                recovery: .creationRecoveryChooseAnotherName)
        case .destinationOutsideProject(let path):
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "\(path) is outside this project, so the file was not created there.",
                recovery: .creationRecoveryChooseLocationInsideProject)
        case .roundTripMismatch:
            // Not always evidence of corruption — see `Failure
            // .roundTripMismatch`'s own doc comment: a `.dotEnv` value
            // containing U+0085 (NEL) reaches this case today purely
            // because `FlatYAMLEmitter.quotedValue` does not yet escape it,
            // not because anything was tampered with. "Corrupted" or
            // "damaged" would be a false claim about the user's own
            // document, so neither word appears here — pinned directly by
            // `CreationFailurePresenterTests
            // .roundTripMismatchDoesNotClaimCorruption`.
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "This app could not verify that every value in this file would decrypt back "
                    + "exactly as entered, so it was not created. This can happen even when nothing "
                    + "is wrong with your data — for example, a value containing an unusual "
                    + "line-break character.",
                recovery: .creationRecoveryCheckUnusualCharacters)
        case .wouldBeUnreadable:
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "This session's key is not among the chosen recipients, so this app could not "
                    + "confirm the file could be decrypted again once created.",
                recovery: .creationRecoveryAddYourKeyOrAcknowledge)
        case .engine(let text):
            // `text` is the bridge's own diagnostic, carried through
            // unchanged — see this type's own doc comment, "Bridge text
            // passes through unchanged".
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "Encryption failed: \(text)",
                recovery: .creationRecoveryCheckRecipients)
        case .couldNotCreateDirectory(let path, let reason):
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "Could not create the folder \(path): \(reason)",
                recovery: .creationRecoveryCheckFolderPermissions)
        case .write(let error):
            // `error.description` is already a complete, situation-specific
            // sentence — for several `AtomicFileWriter.Error` cases it
            // already states what to do (see that type's own doc comment,
            // "Errors never contain the file's contents"). A second,
            // generic recovery hint here would either repeat it or
            // contradict it depending on which case actually fired, so this
            // is the one case this presenter gives no `recovery` for.
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "The file could not be saved: \(error.description)",
                recovery: nil)
        }
    }

    public static func message(for error: SopsConfigGenerator.Error) -> CreationFailureMessage {
        switch error {
        case .targetNotAbsolute(let path):
            return CreationFailureMessage(
                title: .creationFailureConfigTitle,
                detail: "\(path) isn't a complete file path, so no .sops.yaml rule can be proposed "
                    + "for it.",
                recovery: .creationRecoveryPickLocationAgain)
        case .projectRootNotAbsolute(let path):
            return CreationFailureMessage(
                title: .creationFailureConfigTitle,
                detail: "\(path) isn't a complete folder path, so no .sops.yaml rule can be proposed "
                    + "for it.",
                recovery: .creationRecoveryPickLocationAgain)
        case .projectRootDoesNotExist(let path):
            return CreationFailureMessage(
                title: .creationFailureConfigTitle,
                detail: "The project at \(path) could not be found. It may have been moved, deleted, "
                    + "or its disk may not be connected right now.",
                recovery: .creationRecoveryCheckProjectConnected)
        case .targetOutsideProjectRoot(let path):
            return CreationFailureMessage(
                title: .creationFailureConfigTitle,
                detail: "\(path) is outside this project, so no .sops.yaml rule can be proposed "
                    + "for it.",
                recovery: .creationRecoveryChooseLocationInsideProject)
        }
    }

    /// A `.sops.yaml` write that failed after `SopsConfigGenerator.propose`
    /// had already verified the text against sops's own parser —
    /// `AtomicFileWriter.write(_:to:expecting: .absent)` itself refusing:
    /// the destination appeared between the proposal and the write
    /// (`.destinationExists`), a permissions problem, a full volume, or any
    /// other `AtomicFileWriter.Error` case. Not one of the four
    /// vocabularies this presenter otherwise unifies — `SopsConfigGenerator`
    /// itself never writes, by design (see its own doc comment, "Never
    /// writes the config") — so this is the one place a `.sops.yaml`
    /// write's own failure becomes a sentence, the identical shape
    /// `message(forUnreadableSourceFile:)` already earned for the read side
    /// of an equally permanent gap in the other four types' vocabularies.
    /// Shares `.creationFailureConfigTitle` with `message(for:
    /// SopsConfigGenerator.Error)`: both are about proposing/writing
    /// `.sops.yaml`, a different action from creating the secret file
    /// itself.
    public static func message(forConfigWriteFailure error: AtomicFileWriter.Error) -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureConfigTitle,
            detail: "The .sops.yaml could not be saved: \(error.description)",
            recovery: nil)
    }

    public static func message(for failure: DotEnvParseFailure) -> CreationFailureMessage {
        switch failure {
        case .notUTF8:
            return CreationFailureMessage(
                title: .creationFailureDotEnvTitle,
                detail: "That file isn't valid UTF-8 text, so it can't be read as a .env file.",
                recovery: .creationRecoveryReencodeAsUTF8)
        }
    }

    /// The two blocking outcomes of a `CreationPlan`. `CreationPlan` is an
    /// answer, not a thrown error — but two of its cases are exactly the
    /// "the wizard cannot proceed" situation this presenter exists to voice,
    /// so translating them to text belongs here rather than being
    /// re-derived by whatever calls `CreationPlanResolver.plan`.
    ///
    /// `.noConfig` and `.noRuleMatched` are deliberately **not** handled
    /// here — they are not blocking. `.noRuleMatched` in particular is a
    /// legitimate state, established in phase 1: a project can have a
    /// `.sops.yaml` whose rules simply don't cover a location yet, and
    /// `RecipientPicker` (Task 5) is where both of these are resolved.
    /// Returning a failure sentence for either would be actively wrong, not
    /// merely unhelpful — it would tell a user this app refuses something it
    /// is in fact equipped to handle by falling back to the picker.
    /// `.governedByRule` returns `nil` for the simpler reason that nothing
    /// is blocked.
    public static func message(forBlocking plan: CreationPlan) -> CreationFailureMessage? {
        switch plan {
        case .noConfig, .noRuleMatched, .governedByRule:
            return nil
        case .unsupportedRule(let reason):
            // `reason` is already a complete sentence written for a user —
            // `CreationPlanResolver.nonAgeBackendsReason`/`.scopingFieldReason`
            // compose it, name the offending backend or field, and each
            // already ends with what to do about it ("Create the file with
            // sops and it will appear here."). A second recovery hint here
            // would repeat that, so this is the one blocking case with none.
            return CreationFailureMessage(title: .creationFailureTitle, detail: reason, recovery: nil)
        case .configUnreadable(let reason):
            // `reason` is sops's own diagnostic, carried unchanged — the
            // same discipline `.engine` above keeps, for the same reason:
            // rewording it is how this app's understanding of the config
            // drifts from what sops actually reports.
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "This project's .sops.yaml could not be read: \(reason)",
                recovery: .creationRecoveryCheckSopsYamlSyntax)
        }
    }

    /// The fallback `NewSecretFileModel.readiness` shows if
    /// `message(forBlocking:)` is ever called with a `CreationPlan` it is
    /// documented to answer for (`.unsupportedRule`/`.configUnreadable`) and
    /// somehow returns `nil` anyway — unreachable today, kept only so that
    /// contract breaking in the future fails as a wrong sentence rather than
    /// a crash. A model-local sentence used to live at the call site instead
    /// (`NewSecretFileModel.swift`, before this task's review); moved here
    /// because this type's own doc comment is exactly "every sentence the
    /// new-file wizard shows a user belongs here" — an unreachable fallback
    /// is not an exemption from that, and least of all in the file that had
    /// just finished removing the *previous* accepted exception
    /// (`noPickerYetMessage`).
    public static func messageForUnexpectedlyUnblockedPlan() -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureTitle,
            detail: "This app could not describe why creation is blocked here.",
            recovery: nil)
    }

    /// `NewSecretFileModel.readiness`'s refusal for a `.governedByRule` plan
    /// whose own recipient list is empty — a real, sops-admitted shape
    /// (`CreationPlanResolverTests
    /// .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients` measured it
    /// directly against the real bridge: a creation rule whose `path_regex`
    /// matches but which names no key group at all is `.governedByRule(
    /// recipients: [], …)`, not a refusal from `CreationPlanResolver`
    /// itself), not a hypothetical this presenter is padding out.
    ///
    /// Not `CreationPlanResolver`'s own vocabulary — `CreationPlan` carries
    /// no case for "matched, but no recipients", so this belongs here on
    /// the same terms `messageForStaleProposal()`/`message(forEmptyKeyStore:)`
    /// already do: a permanent state this app's own bookkeeping has an
    /// opinion about, not a thrown error to translate. Reached from
    /// `NewSecretFileModel.currentGovernedPlan()`'s own empty-recipients
    /// guard — see that method's own doc comment, "An empty recipient list
    /// is not a target", for the disclosure finding this refusal closes.
    public static func messageForRuleWithNoRecipients() -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureTitle,
            detail: "The matching rule in this project's .sops.yaml names no recipients at all, so "
                + "nothing could be encrypted for anyone. Add at least one recipient to the rule in "
                + ".sops.yaml, or choose a different location.",
            recovery: nil)
    }

    /// `NewSecretFileModel.writeProposedConfig()`'s refusal when there is no
    /// proposal on file for the name and recipients currently chosen — either
    /// nothing has been proposed yet, or the name/selection has changed since
    /// the last `proposeConfig()` call (`ProposalSubject`'s own doc comment
    /// has the full account of what that guards against). Reachable — it is
    /// the primary refusal path of that guard, not a theoretical one — so it
    /// belongs here on the same terms every other permanent, real state does:
    /// this is not `SopsConfigGenerator`'s vocabulary (there is no bridge
    /// call or thrown error to translate), the same way an empty key store
    /// is not any called type's vocabulary either — `message(forEmptyKeyStore:)`
    /// is the precedent, not the exception, for a state that is purely this
    /// app's own bookkeeping still earning a method here rather than a
    /// sentence composed at the call site.
    public static func messageForStaleProposal() -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureConfigTitle,
            detail: "This proposal is no longer for the name or recipients currently chosen. "
                + "Propose again before writing.",
            recovery: nil)
    }

    /// Whether `SessionKeyStore.state` currently prevents the wizard from
    /// proceeding at all. `nil` for `.configured` — nothing is blocked.
    ///
    /// Unlike `message(forBlocking:)`'s two blocking `CreationPlan` cases,
    /// this situation is permanent: `SecretFileCreator.create`'s round-trip
    /// verification (see that type's own doc comment, "Self-readability is
    /// the default") needs a session identity to attempt a decrypt at all,
    /// so no future task removes this refusal the way `RecipientPicker`
    /// (Task 5) removed `.noConfig`/`.noRuleMatched`'s. See this type's own
    /// doc comment, "Why one type, not a `catch` at each call site", for why
    /// that permanence is exactly what earns this a method here rather than
    /// a locally composed sentence in `NewSecretFileModel`.
    public static func message(forEmptyKeyStore state: KeyStoreState) -> CreationFailureMessage? {
        switch state {
        case .configured:
            return nil
        case .empty:
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "No key is unlocked for this session, so this app cannot verify that a new file "
                    + "could be decrypted again once created. Import a key to continue.",
                recovery: nil)
        case .unavailable(let reason):
            // Not reachable through `SessionKeyStore` today — its `state` is
            // only ever `.configured` or `.empty` (M2; Keychain storage is
            // M3) — but `KeyStoreState` is a shared `SopsHealth` type this
            // presenter does not own, so this switch has no `default` for
            // the same reason none of the switches above do: a case this
            // presenter has not been taught to word must fail the build,
            // not fall through to a stale sentence.
            return CreationFailureMessage(
                title: .creationFailureTitle,
                detail: "No key is available for this session (\(reason)), so this app cannot verify that "
                    + "a new file could be decrypted again once created.",
                recovery: nil)
        }
    }

    /// A Plain YAML or `.env` source file the user picked via `NSOpenPanel`
    /// that could not be turned into bytes this app can look at:
    /// `Data(contentsOf:)` itself failing, after the panel already returned
    /// a URL for it — permissions changed, or the file was moved or deleted
    /// in the gap between picking and reading. Not one of
    /// `CreationPlanResolver.Error`/`SecretFileCreator.Failure`/
    /// `SopsConfigGenerator.Error`/`DotEnvParseFailure`: none of those four
    /// types has a case for "the read itself failed", because none of them
    /// is ever asked to *read* an arbitrary user-picked file — `SopsConfigGenerator`
    /// and `SecretFileCreator` only ever *write*, and `CreationPlanResolver`
    /// only ever reads `.sops.yaml`, never a source file. So this is a
    /// dedicated method rather than a case squeezed into one of the four
    /// switches above.
    ///
    /// Always called with a genuine failure already in hand — unlike
    /// `message(forEmptyKeyStore:)`, there is no "fine" case to return `nil`
    /// for, so this returns a `CreationFailureMessage` directly rather than
    /// an `Optional`. See this type's own doc comment for why this earned a
    /// method here instead of a `NewSecretFileModel`-local exception the way
    /// `noPickerYetMessage` — since removed — used to be.
    public static func message(forUnreadableSourceFile: Void = ()) -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureTitle,
            detail: LocalizedKey.creationFailureSourceFileUnreadable.text,
            recovery: nil)
    }

    /// A chosen encrypted source file that reads fine as UTF-8 but carries a
    /// raw NUL byte — valid UTF-8, so it survives the read, and then ends the
    /// argument early at the Go bridge's C boundary
    /// (`String.crossesCBoundaryIntact`'s own doc comment has the mechanism).
    /// `SecretDocumentViewModel.load()`/`RecipientAccessModel.load()` refuse
    /// the identical shape for a document already part of a project; this is
    /// the same refusal at the point a file is *chosen to become* one,
    /// closing ticket #17 claim 4's fourth crossing point.
    public static func message(forNULByteInSourceFile filename: String) -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureTitle,
            detail: "This file contains a NUL byte, which this app cannot read without silently "
                + "dropping everything after it: " + filename,
            recovery: nil)
    }

    /// A `.dotEnv` source that parsed without throwing but produced **no
    /// usable entries** while still holding lines `DotEnvParser` could not
    /// read as `KEY=value` at all (`ParsedDotEnv.skipped`, non-empty;
    /// `.entries`, empty).
    ///
    /// Deliberately narrower than "entries is empty": a genuinely empty or
    /// comments-only `.env` file (`entries` *and* `skipped` both empty) is
    /// not this case — `FlatYAMLEmitter.emit([])` produces `"{}\n"`, the
    /// same legitimate empty document `.empty`'s own source produces, and
    /// creating it is an honest reflection of an empty input. What this
    /// case catches is different: lines that *looked like* assignments and
    /// very plausibly held secrets, all rejected by the parser, with
    /// nothing salvaged. `NewSecretFileModel.create()` would otherwise
    /// happily hand `SecretFileCreator` the same empty `{}` document while
    /// `DotEnvPreviewTable` is showing the user exactly those lines,
    /// discarding whatever they held with nothing but a masked preview
    /// standing between "nothing was imported" and a "Create" button that
    /// still reads as success.
    public static func message(forDotEnvWithNoUsableEntries: Void = ()) -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureDotEnvTitle,
            detail: "None of this file's lines could be read as KEY=value assignments, so nothing would "
                + "be imported. Check the lines below, fix the file, or choose a different source.",
            recovery: nil)
    }

    /// An `.encryptedYAML` source (Task 6) `SopsBridge.decryptYAML` (or, once
    /// that succeeds, `.recipients(in:)`) could not open with this session's
    /// key — a wrong or missing identity, a genuine engine fault, or the
    /// file simply not being a SOPS document at all. `reason` is the
    /// bridge's own diagnostic, carried through unchanged — see this type's
    /// own doc comment, "Bridge text passes through unchanged". That
    /// distinction is load-bearing here specifically: an earlier version of
    /// this method took no reason and asserted unconditionally that "this
    /// session's key could not decrypt this file", which is not true of
    /// every path that reaches here — a plain (unencrypted) YAML file picked
    /// for this source fails at the identical call site with a completely
    /// different cause, and telling that user their *key* is wrong, with
    /// advice to import a different one, can never be corrected by anything
    /// they do with a key. `CreationFailurePresenterTests
    /// .encryptedImportUnlockFailureNamesTheBridgesOwnReason` pins that the
    /// bridge's own words survive into `detail`, not a fixed claim about the
    /// key.
    ///
    /// Unlike `SecretFileCreator.Failure.wouldBeUnreadable`, there is
    /// nothing here for `acknowledgedUnreadable` to waive. That flag exists
    /// to skip *content verification* for a file this app is about to
    /// *write*, once encryption has already produced something to compare
    /// against. Here nothing has been decrypted at all — there is no
    /// plaintext to import, acknowledged or not — so the only way past this
    /// refusal is a session key that actually decrypts the file, which is
    /// what `recovery` points at, phrased to cover the "this isn't SOPS at
    /// all" case too rather than presuming the key is the problem.
    ///
    /// Also reached — deliberately, not as an oversight — when a decrypt
    /// *succeeds* but reading this file's own recipients afterward
    /// (`SopsBridge.recipients(in:)`) then fails: unreachable in practice (a
    /// document that decrypted has already proven its own metadata parses),
    /// but a caller that cannot tell why recipient metadata failed to read
    /// has nothing more specific to say than the bridge's own words either.
    public static func message(forEncryptedImportUnlockFailure reason: String) -> CreationFailureMessage {
        CreationFailureMessage(
            title: .creationFailureEncryptedImportTitle,
            detail: "This file could not be unlocked: \(reason)",
            recovery: .creationRecoveryImportAKeyThatCanDecryptThisFile)
    }
}
