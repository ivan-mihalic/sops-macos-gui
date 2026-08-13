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

/// Turns a refusal from any of the four types the new-file wizard calls in
/// sequence — `CreationPlanResolver`, `SecretFileCreator`,
/// `SopsConfigGenerator`, `DotEnvParser` — into one sentence for a user, in
/// one voice.
///
/// ## Why one type, not a `catch` at each call site
///
/// Phase 1's final whole-branch review measured that these three types
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
/// ## Every `switch` below has no `default`
///
/// A `default` case would silently swallow a case added later to any of the
/// four consumed types — and swallowing it, unnoticed, is exactly the defect
/// this type exists to prevent: a wizard that hits a case with no sentence
/// and shows nothing, or shows a stale one. The compiler is the completeness
/// check; `CreationFailurePresenterTests` checks the text.
///
/// ## Bridge text passes through unchanged
///
/// `SecretFileCreator.Failure.engine(String)` carries sops's own diagnostic.
/// It is never rewritten, prefixed, or prettified here — `CreationPlanResolver`
/// held the identical line for the identical reason (see that type's own doc
/// comment): re-wording what sops says is how this app's understanding of a
/// failure drifts from what sops actually reports. Where a sentence below
/// wraps that text in a lead-in ("Encryption failed: …"), the bridge's own
/// words still survive verbatim inside it.
///
/// ## What `detail` is never allowed to carry
///
/// A path, a key name, an errno-derived reason, or the bridge's own
/// diagnostic text is fine — a value from the document being created, or a
/// private identity, is not. None of the four types this presenter consumes
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

    public static func message(for failure: DotEnvParseFailure) -> CreationFailureMessage {
        switch failure {
        case .notUTF8:
            return CreationFailureMessage(
                title: .creationFailureDotEnvTitle,
                detail: "That file isn't valid UTF-8 text, so it can't be read as a .env file.",
                recovery: .creationRecoveryReencodeAsUTF8)
        }
    }
}
