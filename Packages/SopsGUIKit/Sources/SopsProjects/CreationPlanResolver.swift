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
public enum CreationPlanResolver {
    /// Decides which creation rule would govern a file at `target` if it
    /// were created there right now.
    ///
    /// `target` must be an absolute path. `SopsBridge.lookupCreationRule`
    /// matches a rule's `path_regex` against the target *relative to the
    /// config's own directory*, computed by stripping that directory as a
    /// literal prefix — a relative or differently-rooted `target` would
    /// silently fail to strip, and every `path_regex` would then be matched
    /// against the wrong string, producing a confident, wrong answer rather
    /// than an error. `target` itself need not exist: this answers "if a
    /// file were created here", not "what governs this file today".
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
