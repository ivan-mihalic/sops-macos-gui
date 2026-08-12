import Foundation
import SopsEngine

/// Which `.sops.yaml` creation rule would govern a file at a given path if it
/// were created there right now, and whether this app can faithfully carry
/// out what that rule asks for.
///
/// This app encrypts with native age only (see ADR 0001's key-material
/// constraint; this is its recipient-side sibling). A rule that also names
/// PGP, KMS or another backend, or that scopes encryption via
/// `unencrypted_suffix`, `unencrypted_regex` or `encrypted_suffix`, is a
/// shape this app cannot reproduce: creating the file anyway would either
/// silently drop a recipient the rule declared — half the team left unable
/// to read the file — or encrypt (or leave plaintext) a different set of
/// values than sops itself would for the same rule. Refusing and naming
/// exactly what was found is the honest answer; see `unsupportedRule`.
public enum CreationPlan: Equatable, Sendable {
    /// A rule this app fully understands governs the target. `recipients`
    /// are the native age public keys it resolves to. `encryptedRegex` is
    /// the rule's own `encrypted_regex` — empty means "encrypt everything" —
    /// carried through unchanged: it is the one scoping field this app can
    /// reproduce exactly, because `SopsBridge.encryptYAML` takes it
    /// directly.
    case governedByRule(recipients: [String], encryptedRegex: String)
    /// The config loaded fine, but no creation rule matches the target — a
    /// `.sops.yaml` with no `creation_rules` key counts as this too, per
    /// `CreationRuleLookup.matched`. Not a refusal: there is simply nothing
    /// here for this app to reproduce, and a caller such as the wizard is
    /// expected to fall back to a manual recipient picker rather than invent
    /// one here.
    case noRuleMatched
    /// There is no `.sops.yaml` at the project root at all.
    case noConfig
    /// The config exists but sops itself could not parse it — missing file
    /// aside, since that is `.noConfig`. `reason` is sops's own diagnostic,
    /// carried unchanged: rewording it is how this app's understanding of a
    /// config drifts from what sops actually does with it.
    case configUnreadable(reason: String)
    /// A rule governs the target, but names a backend this app cannot hold
    /// (PGP, KMS, …) or a plaintext-scoping field it cannot evaluate
    /// (`unencrypted_regex`, `unencrypted_suffix`, `encrypted_suffix`).
    /// `reason` is a complete sentence naming what was found and what to do
    /// instead — "this rule is not supported" alone would leave a user with
    /// no next step.
    case unsupportedRule(reason: String)
}

/// Resolves `CreationPlan` for a not-yet-existing file, purely by asking
/// sops's own config parser what it would do — never by re-parsing
/// `.sops.yaml` on the Swift side. A hand-rolled Swift YAML scanner for this
/// file existed in this codebase once and was deleted after three separate
/// silent-corruption bugs; see `ProjectHealthCheck.swift`'s account of why.
/// Everything here goes through `SopsBridge.lookupCreationRule`.
///
/// ## Which containment predicate, and why it differs from `SecretFileCreator`'s
///
/// `SecretFileCreator.refuseIfOutsideProject` resolves symlinks
/// (`CanonicalPath.of` plus its walk-upward-to-an-existing-ancestor trick)
/// before comparing `target` against `projectRoot`, because that type is
/// about to *write a file* and a symlinked directory is a real way to escape
/// the project on disk. This type never writes anything, and the question it
/// exists to answer is narrower and more literal: "what would
/// `SopsBridge.lookupCreationRule` say about this `target` right now?" — and
/// that call's own containment logic is not symlink-aware at all, it strips
/// `projectRoot` as a plain string prefix (see `Error`'s own doc comment for
/// the exact mechanism and the wrong answer it produces when the prefix does
/// not match). Resolving symlinks here would make this type's notion of
/// "inside `projectRoot`" disagree with the one the bridge call it wraps
/// actually uses — passing a `target` this type approved as contained into a
/// bridge call that would itself compute a *different* relative path for it.
/// So the guard below uses the identical literal-prefix comparison
/// `SopsConfigGenerator.relativePath` uses, for the identical reason that
/// type's own doc comment gives ("Containment is enforced here,
/// independently of `SecretFileCreator`" — its closing paragraph makes
/// exactly this same call, for the same reason: matching what
/// `lookupCreationRule` itself computes, not introducing a second,
/// disagreeing notion of "inside").
public enum CreationPlanResolver {
    /// Thrown before `.sops.yaml` is ever looked at, when `target` or
    /// `projectRoot` is not an absolute path.
    ///
    /// This is not optional defensive coding: `SopsBridge.lookupCreationRule`
    /// matches a rule's `path_regex` against the target *relative to the
    /// config's own directory*, computed by stripping that directory as a
    /// literal prefix, and a relative or differently-rooted path silently
    /// fails to strip rather than erroring — every `path_regex` then gets
    /// matched against the wrong string, a confident, wrong answer rather
    /// than a failure. Nor does the bridge catch it lower down:
    /// `Engine/gobridge/config.go`'s `LookupCreationRule` calls Go's
    /// `filepath.Abs` on the target, which does not reject a relative path,
    /// it silently joins it onto the *Go process's own working directory*
    /// and proceeds. Left unchecked, the one caller mistake this type's own
    /// doc comment warns about would not surface as an error anywhere in the
    /// stack — this guard is what makes that warning actually true.
    ///
    /// A thrown error rather than a `precondition`, deliberately:
    /// `plan(forTarget:in:)` sits behind a wizard where `target` can
    /// originate from a path the user typed, and a caller's mistake here
    /// should be something the caller's existing `try` already handles, not
    /// a process crash over what is, from the user's chair, just a typo.
    ///
    /// `.projectRootDoesNotExist` and `.targetOutsideProjectRoot` are the
    /// same discipline, for a related shape of mistake: without them,
    /// `target` is handed to `SopsBridge.lookupCreationRule` as-is, and that
    /// call matches `path_regex` against `target` *relative to the config's
    /// own directory*, computed the identical way — stripping that
    /// directory as a literal prefix
    /// (`Engine/gobridge/config.go`'s `LookupCreationRule`, and one level
    /// below it, the vendored sops `config.parseCreationRuleForFile`). A
    /// `target` that does not share that literal prefix does not fail to
    /// strip loudly — `strings.TrimPrefix` is a no-op when the prefix is not
    /// there, leaving `target`'s *full absolute path*, which then gets
    /// matched against every rule's `path_regex` **unanchored**
    /// (`regexp.MatchString`, not an anchored match). A rule such as
    /// `path_regex: secrets/.*\.yaml$`, asked about
    /// `/somewhere/else/secrets/prod.yaml`, matches that unrelated path as a
    /// substring and reports `.governedByRule` with that project's
    /// recipients — a confidently wrong answer, not a failure. See this
    /// type's own doc comment for why this is the same shape of mistake
    /// `.targetNotAbsolute`/`.projectRootNotAbsolute` already guard, just one
    /// step further down the same code path.
    public enum Error: Swift.Error, Equatable, Sendable, CustomStringConvertible {
        case targetNotAbsolute(String)
        case projectRootNotAbsolute(String)
        /// `projectRoot` does not exist, or exists as something other than a
        /// directory. Checked before containment, for the identical reason
        /// `SopsConfigGenerator.requireProjectRootExists` and
        /// `SecretFileCreator.refuseIfOutsideProject` check it: "inside
        /// `projectRoot`" is not a claim a literal-prefix comparison can
        /// honestly make against a root that is not really there.
        case projectRootDoesNotExist(String)
        /// `target` contains a literal `..` path component, or does not lie
        /// under `projectRoot` at all — including a `target` that shares
        /// `projectRoot`'s string prefix only to walk back out via `..`
        /// components, which a plain prefix check alone would miss (see
        /// `SopsConfigGeneratorTests.dotDotComponentIsRefused` for the
        /// identical concrete escape, pinned there first). `path` is
        /// `target`, always — `projectRoot` is not the thing that was
        /// rejected.
        case targetOutsideProjectRoot(String)

        public var description: String {
            switch self {
            case .targetNotAbsolute(let path):
                return "the target path \(path) is not absolute, so no creation rule could be resolved for it"
            case .projectRootNotAbsolute(let path):
                return "the project root \(path) is not absolute, so no creation rule could be resolved for it"
            case .projectRootDoesNotExist(let path):
                return "the project root \(path) does not exist or is not a directory, so no creation rule "
                    + "could be resolved for it"
            case .targetOutsideProjectRoot(let path):
                return "the target path \(path) does not lie inside the project root, so no creation rule "
                    + "could be honestly resolved for it"
            }
        }
    }

    /// Decides which creation rule would govern a file at `target` if it
    /// were created there right now.
    ///
    /// `target` and `projectRoot` must both be absolute paths, `projectRoot`
    /// must exist as a real directory, and `target` must lie inside
    /// `projectRoot` with no literal `..` component anywhere in it — throws
    /// `Error` otherwise, before `.sops.yaml` is ever looked at. See
    /// `Error`'s own doc comment for why this is enforced rather than merely
    /// documented, and this type's own doc comment, "Which containment
    /// predicate", for why the check is a literal string-prefix comparison
    /// rather than `SecretFileCreator`'s symlink-aware one. `target` itself
    /// need not exist: this answers "if a file were created here", not "what
    /// governs this file today".
    ///
    /// Decision order is load-bearing, because the cases genuinely overlap —
    /// a rule can name a non-age backend *and* set an unsupported scoping
    /// field at once, and the two verdicts are not interchangeable:
    ///
    /// 1. No `.sops.yaml` at the project root → `.noConfig`, without ever
    ///    calling the bridge. There is nothing to ask sops about.
    /// 2. The bridge throws → `.configUnreadable`, sops's own text.
    /// 3. No rule matches → `.noRuleMatched`.
    /// 4. The rule names a non-age backend → `.unsupportedRule`, naming it.
    ///    Checked before the scoping fields below: a user who cannot hold
    ///    half the recipients needs to hear that first, not a sentence about
    ///    which keys get encrypted.
    /// 5. The rule sets `unencrypted_regex`, `unencrypted_suffix` or
    ///    `encrypted_suffix` → `.unsupportedRule`, naming the field.
    ///    `encrypted_regex` is deliberately not in this list — see
    ///    `CreationPlan.governedByRule`.
    /// 6. Otherwise → `.governedByRule`.
    public static func plan(forTarget target: URL, in projectRoot: URL) throws -> CreationPlan {
        guard target.path.hasPrefix("/") else {
            throw Error.targetNotAbsolute(target.path)
        }
        guard projectRoot.path.hasPrefix("/") else {
            throw Error.projectRootNotAbsolute(projectRoot.path)
        }
        try Self.refuseIfOutsideProject(target, projectRoot: projectRoot)

        let configURL = projectRoot.appendingPathComponent(".sops.yaml")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return .noConfig
        }

        let lookup: CreationRuleLookup
        do {
            lookup = try SopsBridge.lookupCreationRule(
                configPath: configURL.path, targetFilePath: target.path)
        } catch let error as SopsBridgeError {
            return .configUnreadable(reason: error.description)
        } catch {
            // Not expected in practice — `lookupCreationRule` is documented
            // to throw only `SopsBridgeError` — but a caller must never see
            // this function fail silently for a type it did not anticipate.
            return .configUnreadable(reason: "this project's .sops.yaml could not be read")
        }

        guard lookup.matched else {
            return .noRuleMatched
        }

        guard lookup.nonAgeBackends.isEmpty else {
            return .unsupportedRule(reason: Self.nonAgeBackendsReason(lookup.nonAgeBackends))
        }

        if !lookup.unencryptedRegex.isEmpty {
            return .unsupportedRule(reason: Self.scopingFieldReason("unencrypted_regex"))
        }
        if !lookup.unencryptedSuffix.isEmpty {
            return .unsupportedRule(reason: Self.scopingFieldReason("unencrypted_suffix"))
        }
        if !lookup.encryptedSuffix.isEmpty {
            return .unsupportedRule(reason: Self.scopingFieldReason("encrypted_suffix"))
        }

        return .governedByRule(recipients: lookup.ageRecipients, encryptedRegex: lookup.encryptedRegex)
    }

    // MARK: - Containment

    /// Refuses `target` unless `projectRoot` exists as a real directory and
    /// `target` lies inside it with no literal `..` component anywhere in
    /// it. See this type's own doc comment, "Which containment predicate",
    /// for why the check below is a literal string-prefix comparison —
    /// matching what `SopsBridge.lookupCreationRule` itself computes — and
    /// not `SecretFileCreator`'s symlink-aware one.
    private static func refuseIfOutsideProject(_ target: URL, projectRoot: URL) throws {
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: projectRoot.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw Error.projectRootDoesNotExist(projectRoot.path)
        }

        // Refused outright, before the prefix comparison below, for the
        // identical reason `SecretFileCreator.Failure.destinationOutsideProject`'s
        // doc comment gives ("Why `..` is refused rather than resolved") and
        // `SopsConfigGeneratorTests.dotDotComponentIsRefused` measures
        // directly: a `target` can share `projectRoot`'s literal string
        // prefix and still walk back outside it via `..` components, which
        // the prefix check alone cannot see.
        guard !target.path.split(separator: "/").contains("..") else {
            throw Error.targetOutsideProjectRoot(target.path)
        }

        let rootPath = projectRoot.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard target.path.hasPrefix(prefix) else {
            throw Error.targetOutsideProjectRoot(target.path)
        }
    }

    /// Names every non-age backend the matched rule found, in the sops CLI's
    /// own vocabulary — "pgp", "kms" and so on — rather than a generic
    /// "unsupported backend" that would leave a user guessing which line of
    /// their own `.sops.yaml` is the problem.
    private static func nonAgeBackendsReason(_ backends: [String]) -> String {
        "The creation rule that would govern this file also uses " + joinWithAnd(backends) + ". This app "
            + "manages native age recipients only, so creating the file here would leave out every "
            + "recipient it cannot hold as a native age key. Create the file with sops and it will appear "
            + "here."
    }

    /// Names the specific scoping field this app does not evaluate, so a
    /// user can find it in their own `.sops.yaml` rather than guessing which
    /// setting triggered the refusal.
    private static func scopingFieldReason(_ field: String) -> String {
        "The creation rule that would govern this file sets \(field), which decides per key whether to "
            + "keep a value in plaintext in a way this app does not evaluate. Creating the file here could "
            + "encrypt, or leave in plaintext, a different set of values than sops itself would for the "
            + "same rule. Create the file with sops and it will appear here."
    }

    private static func joinWithAnd(_ names: [String]) -> String {
        switch names.count {
        case 0: return "another key backend"
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }
}
