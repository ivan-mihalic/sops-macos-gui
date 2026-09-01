import CSopsBridge
import Darwin
import Foundation

public struct SopsBridgeError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    /// A stable, Go-owned classification for the handful of bridge errors
    /// that have one — `nil` for every other error, which is most of them.
    /// Ticket #10, claim 2: this is what lets `SecretFileCreator` tell "this
    /// identity genuinely is not among the file's recipients" apart from a
    /// genuine engine fault at decrypt time, without pattern-matching
    /// `description`'s own prose — see `Engine/gobridge/document.go`'s
    /// `classifiedError` for where a value originates, and `call(_:)` below
    /// for how it crosses the C boundary.
    public let kind: Kind?

    /// `kind` defaults to `nil`: every construction site in this file for a
    /// *Swift*-side failure (malformed JSON from the bridge, an encoding
    /// failure before a call is even made) has no classification to give —
    /// only `call(_:)`, decoding a real bridge failure, ever passes one
    /// explicitly.
    init(description: String, kind: Kind? = nil) {
        self.description = description
        self.kind = kind
    }

    public enum Kind: String, Sendable {
        /// `Engine/gobridge/document.go`'s `ErrKindNoMatchingIdentity`,
        /// verbatim — this is the one place that string is spelled twice,
        /// once per language, and `SopsBridgeErrorKindTests` pins that they
        /// still agree.
        case noMatchingIdentity = "no-matching-identity"
    }
}

/// Which creation rule in a `.sops.yaml` governs a specific target file,
/// resolved by sops's own config parser (`github.com/getsops/sops/v3/config`)
/// through the bridge — never re-parsed on the Swift side. See
/// `SopsBridge.lookupCreationRule(configPath:targetFilePath:)`.
public struct CreationRuleLookup: Decodable, Equatable, Sendable {
    /// False when the config loaded successfully but no rule governs the
    /// target file — including a `.sops.yaml` with no `creation_rules` key
    /// at all, which sops itself treats as "no rule", not an error.
    public let matched: Bool
    /// Bech32 age public keys (`age1...`) the matched rule resolves to.
    /// Empty when `matched` is false or the rule uses no age keys.
    public let ageRecipients: [String]
    /// sops master-key type identifiers ("pgp", "kms", "gcp_kms", "hckms",
    /// "azure_kv", "hc_vault") present anywhere in the matched rule's key
    /// groups. Empty when `matched` is false or the rule is age-only.
    public let nonAgeBackends: [String]
    /// The matched rule's `encrypted_regex`, if it sets one — scopes
    /// encryption to only the document keys it matches, everything else
    /// stays plaintext. Empty when `matched` is false or the rule does not
    /// set this field.
    public let encryptedRegex: String
    /// The matched rule's `unencrypted_regex`, if it sets one — the inverse
    /// of `encryptedRegex`: matching keys stay plaintext, everything else is
    /// encrypted. Empty when `matched` is false or the rule does not set
    /// this field.
    public let unencryptedRegex: String
    /// The matched rule's `unencrypted_suffix`, if it sets one. Empty when
    /// `matched` is false or the rule does not set this field — including
    /// when the rule relies on sops's own implicit default suffix, which is
    /// never conflated with an explicit setting here.
    public let unencryptedSuffix: String
    /// The matched rule's `encrypted_suffix`, if it sets one. Empty when
    /// `matched` is false or the rule does not set this field.
    public let encryptedSuffix: String
}

/// Which key backends a whole `.sops.yaml` declares, anywhere in it —
/// independent of which files exist. The companion to `CreationRuleLookup`,
/// which can only ever speak about a rule that governs a specific file. See
/// `SopsBridge.inspectConfigBackends(configPath:)`.
public struct ConfigBackends: Decodable, Equatable, Sendable {
    /// sops master-key type identifiers ("pgp", "kms", "gcp_kms", "hckms",
    /// "azure_kv", "hc_vault") named anywhere across the config's creation
    /// rules, sorted and deduplicated. The same vocabulary
    /// `CreationRuleLookup.nonAgeBackends` uses. Age is deliberately absent:
    /// it is the one backend this app reads in full, so it is never a caveat.
    /// Empty when the config is age-only.
    public let backends: [String]
}

/// What the `.sops.yaml` creation rule governing a file would look like with a
/// different age recipient list — a *proposal*, never something that happened.
/// See `SopsBridge.updateConfigRecipients(configPath:targetFilePath:to:candidateFilePaths:)`.
public struct ConfigRecipientUpdate: Decodable, Equatable, Sendable {
    /// Whether the governing rule is a flat, age-only rule this app fully
    /// understands, so `config` may be written over the existing file. False
    /// for every shape the bridge refuses to guess at, and then `reason`
    /// names which one was found.
    public let writable: Bool
    /// A whole sentence for a user: what shape was found and what they can do
    /// instead. Empty exactly when `writable` is true. Never carries a
    /// private identity or any document content.
    public let reason: String
    /// Where the governing rule sits in `creation_rules`, or `-1` when no
    /// rule governs the target file. This is what makes `matchedFiles`
    /// meaningful — "the same rule" is a position, not a resemblance between
    /// two key lists.
    ///
    /// No view reads it, and that is not an oversight. The bridge's rule
    /// *selection* is the load-bearing decision in this whole surface — it is
    /// what decides whose keys get rewritten — and this field is the only
    /// place that decision is observable from the Swift side at all. It is
    /// decoded so `ConfigRecipientUpdateTests` can pin it across the C
    /// boundary rather than inferring it from `matchedFiles`, which would pass
    /// just as happily if the bridge had picked a different rule that happens
    /// to govern the same files.
    public let ruleIndex: Int
    /// The age public keys that rule resolves to today, from sops's own
    /// config parser.
    public let currentRecipients: [String]
    /// The candidate paths that the same rule governs, in the order given.
    public let matchedFiles: [String]
    /// The candidate paths some creation rule *other* than `ruleIndex`
    /// governs, in the order given. Never overlaps `matchedFiles`, and never
    /// names a file no rule governs at all.
    ///
    /// It answers the question `matchedFiles` structurally cannot: when no
    /// rule governs the target file, `matchedFiles` is empty and a caller's
    /// scope falls back to everything it found — including files whose keys
    /// another rule decides. This is how many.
    public let filesGovernedByOtherRules: [String]
    /// Whether `config` differs from what is on disk. False when the rule
    /// already declares exactly the requested set, in which case `config` is
    /// the file's current text.
    public let changed: Bool
    /// The complete proposed `.sops.yaml` text. Empty when `writable` is
    /// false: a refusal never hands back something a caller could write.
    public let config: String
}

/// How many of a SOPS document's leaves are genuinely ciphertext on disk,
/// versus how many the document actually has. See
/// `SopsBridge.inspectLeafEncryption(in:)`.
public struct LeafEncryptionSummary: Decodable, Equatable, Sendable {
    /// How many non-comment scalar leaves the document has, across every
    /// document in a multi-document file. Zero for a document with nothing
    /// to encrypt — never the same shape as every leaf being unencrypted.
    public let leafCount: Int
    /// How many of those leaves are ciphertext on disk right now.
    public let encryptedLeafCount: Int
    /// Whether this file's own metadata names a rule that could
    /// legitimately leave some values unencrypted — an `encrypted_regex`,
    /// `unencrypted_regex`, `encrypted_suffix`, either `_comment_regex`
    /// sibling, or a **non-default** `unencrypted_suffix`. See
    /// `gobridge.LeafEncryptionSummary`'s doc comment for why the default
    /// suffix specifically does not count: sops writes
    /// `unencrypted_suffix: _unencrypted` into nearly every file that
    /// declares no rule at all, so its bare presence is not evidence of a
    /// choice — measured directly, not assumed.
    public let narrowingDeclared: Bool
    /// Whether a declared regex-shaped rule fails to compile under the
    /// same engine sops itself compiles it with. True here is a certain
    /// finding even when `narrowingDeclared` is also true — an
    /// uncompilable pattern can never match anything, so sops's own
    /// (reproduced, tested) fallback is to leave every value in cleartext.
    public let uncompilableRuleDeclared: Bool
}

/// In-process SOPS engine. Every call crosses into the Go runtime linked from
/// the static bridge; no `sops` binary is ever spawned.
public enum SopsBridge {

    /// `format` has no default: every call site states which document shape
    /// it means, rather than the bridge silently assuming YAML. See
    /// `SopsFileFormat`'s own doc comment for why.
    public static func encrypt(
        _ plain: String,
        format: SopsFileFormat,
        recipients: [String],
        encryptedRegex: String = ""
    ) throws -> String {
        try call { out in
            plain.withGoString { plainPtr in
                format.rawValue.withGoString { formatPtr in
                    recipients.joined(separator: ",").withGoString { recipientsPtr in
                        encryptedRegex.withGoString { regexPtr in
                            sops_encrypt(plainPtr, formatPtr, recipientsPtr, regexPtr, out)
                        }
                    }
                }
            }
        }
    }

    /// `format` has no default — see `encrypt(_:format:recipients:encryptedRegex:)`.
    public static func decrypt(_ encrypted: String, format: SopsFileFormat, agePrivateKey: String) throws -> String {
        try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    agePrivateKey.withGoString { keyPtr in
                        sops_decrypt(encryptedPtr, formatPtr, keyPtr, out)
                    }
                }
            }
        }
    }

    /// Returns the native age recipients stored in this document's SOPS
    /// metadata. Reading recipient metadata requires no private identity.
    /// `format` has no default — see
    /// `encrypt(_:format:recipients:encryptedRegex:)`.
    public static func recipients(in encrypted: String, format: SopsFileFormat) throws -> [String] {
        let json = try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    sops_recipients(encryptedPtr, formatPtr, out)
                }
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw SopsBridgeError(description: "bridge returned non-UTF8 JSON for recipients")
        }
        do {
            return try JSONDecoder().decode([String].self, from: data)
        } catch {
            throw SopsBridgeError(description: "could not decode recipient JSON")
        }
    }

    /// Explicitly replaces the document's native age recipient set, re-wrapping
    /// the existing data key with the supplied private identity. It never reads
    /// a project config or a key from the environment. `format` has no default —
    /// see `encrypt(_:format:recipients:encryptedRegex:)`.
    public static func updateRecipients(
        _ encrypted: String,
        format: SopsFileFormat,
        to recipients: [String],
        agePrivateKey: String
    ) throws -> String {
        let recipientsJSON: String
        do {
            recipientsJSON = String(decoding: try JSONEncoder().encode(recipients), as: UTF8.self)
        } catch {
            throw SopsBridgeError(description: "could not encode recipient list")
        }
        return try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    recipientsJSON.withGoString { recipientsPtr in
                        agePrivateKey.withGoString { keyPtr in
                            sops_update_recipients(encryptedPtr, formatPtr, recipientsPtr, keyPtr, out)
                        }
                    }
                }
            }
        }
    }

    /// Derives the native age public key ("age1…") that corresponds to
    /// `privateKey`, without decrypting anything.
    ///
    /// SOPS-38 phase F3: detecting a read-only ciphertext file — one whose
    /// recipients do not include the session's own key — needs the session's
    /// *public* key to compare against a file's own recipient metadata
    /// (`EncryptedFileMetadata`), and `SessionKeyStore` holds only the
    /// private identity a user pasted in. This is the one call that turns
    /// that into the public key it corresponds to; it is no more sensitive
    /// than the "# public key: …" line `age-keygen` itself prints alongside
    /// a freshly generated identity.
    ///
    /// Throws when `privateKey` is not a valid age identity — never a panic,
    /// and the message never echoes what was supplied.
    public static func agePublicKey(forPrivateKey privateKey: String) throws -> String {
        try call { out in
            privateKey.withGoString { keyPtr in
                sops_age_public_key(keyPtr, out)
            }
        }
    }

    /// Resolves which creation rule in the `.sops.yaml` at `configPath`
    /// governs `targetFilePath`, via sops's own config parser end to end.
    /// `targetFilePath` must be absolute — sops matches each rule's
    /// `path_regex` against the target path relative to `configPath`'s own
    /// directory, computed by stripping that directory as a literal prefix,
    /// so a relative or differently-rooted path would silently fail to
    /// strip and every `path_regex` would be matched against the wrong
    /// string.
    ///
    /// Throws only when the config could not be loaded at all (missing
    /// file, malformed YAML, an unresolvable key, an unparseable
    /// `path_regex`) — sops's own error text, not a heuristic's. "No rule
    /// matches this file" is not an error: it comes back as
    /// `CreationRuleLookup(matched: false, ...)`, because sops itself does
    /// not treat that as a failure.
    public static func lookupCreationRule(configPath: String, targetFilePath: String) throws -> CreationRuleLookup {
        let json = try call { out in
            configPath.withGoString { confPtr in
                targetFilePath.withGoString { targetPtr in
                    sops_lookup_creation_rule(confPtr, targetPtr, out)
                }
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw SopsBridgeError(description: "bridge returned non-UTF8 JSON for creation rule lookup")
        }
        do {
            return try JSONDecoder().decode(CreationRuleLookup.self, from: data)
        } catch {
            // Fixed text, `error` deliberately unused — see the same catch in
            // `updateConfigRecipients` for why a `DecodingError`'s own
            // description may not be relayed.
            throw SopsBridgeError(
                description: "the bridge's answer about this project's .sops.yaml could not be read")
        }
    }

    /// Reports which key backends the `.sops.yaml` at `configPath` declares
    /// across all of its creation rules, whether or not any file currently
    /// matches the rule declaring them.
    ///
    /// `lookupCreationRule` is per-file by construction — sops's own config
    /// API resolves a rule *for a target path* and exposes no
    /// enumerate-every-rule call. A rule declaring pgp/KMS/Vault with no
    /// matching file was therefore invisible, and a check that says nothing
    /// about it ends up implying everything is fine. This call closes that
    /// gap: it is the only way to know that a config contains something this
    /// app cannot evaluate before any file is even looked at.
    ///
    /// Throws when the config cannot be read or is not valid YAML. Parsing is
    /// done by the same real YAML parser sops's own config loader uses, never
    /// by hand — ADR 0002.
    public static func inspectConfigBackends(configPath: String) throws -> ConfigBackends {
        let json = try call { out in
            configPath.withGoString { confPtr in
                sops_inspect_config_backends(confPtr, out)
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw SopsBridgeError(description: "bridge returned non-UTF8 JSON for config backend inspection")
        }
        do {
            return try JSONDecoder().decode(ConfigBackends.self, from: data)
        } catch {
            // Fixed text, `error` deliberately unused — see the same catch in
            // `updateConfigRecipients`.
            throw SopsBridgeError(
                description: "the bridge's answer about this project's .sops.yaml could not be read")
        }
    }

    /// Computes what the `.sops.yaml` at `configPath` would look like if the
    /// creation rule governing `targetFilePath` declared exactly `recipients`
    /// as its age recipient list, and reports which of
    /// `candidateFilePaths` that same rule governs.
    ///
    /// **This writes nothing.** The bridge is structurally incapable of
    /// changing a project's configuration: it only ever computes text, and
    /// the caller writes it — atomically, and only after the user has
    /// confirmed — or does not. Changing who can read a project's secrets is
    /// never a side effect of anything.
    ///
    /// Only a flat, age-only creation rule is rewritable. A rule using
    /// `key_groups`, a `shamir_threshold`, another key backend, or a YAML
    /// anchor — and a config using merge keys, holding several documents, or
    /// mixing line endings — comes back `writable == false` with a `reason`
    /// naming what was found. That is not an error: it is the app declining
    /// to guess at a configuration it does not fully understand.
    ///
    /// `targetFilePath` and `candidateFilePaths` must be absolute, for the
    /// same reason `lookupCreationRule` requires it.
    ///
    /// Throws when the config cannot be read, is not valid YAML, or a
    /// supplied recipient is not a native age public key — the bridge's own
    /// fixed, value-free error text.
    public static func updateConfigRecipients(
        configPath: String,
        targetFilePath: String,
        to recipients: [String],
        candidateFilePaths: [String] = []
    ) throws -> ConfigRecipientUpdate {
        let recipientsJSON: String
        let candidatesJSON: String
        do {
            recipientsJSON = String(decoding: try JSONEncoder().encode(recipients), as: UTF8.self)
            candidatesJSON = String(decoding: try JSONEncoder().encode(candidateFilePaths), as: UTF8.self)
        } catch {
            throw SopsBridgeError(description: "could not encode the recipient or candidate list")
        }

        let json = try call { out in
            configPath.withGoString { confPtr in
                targetFilePath.withGoString { targetPtr in
                    recipientsJSON.withGoString { recipientsPtr in
                        candidatesJSON.withGoString { candidatesPtr in
                            sops_update_config_recipients(
                                confPtr, targetPtr, recipientsPtr, candidatesPtr, out)
                        }
                    }
                }
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw SopsBridgeError(description: "bridge returned non-UTF8 JSON for the config update")
        }
        do {
            return try JSONDecoder().decode(ConfigRecipientUpdate.self, from: data)
        } catch {
            // Fixed text, and the `error` deliberately unused. A
            // `DecodingError`'s description quotes the payload it choked on,
            // and that payload is this project's `.sops.yaml` — public, but
            // the rule in this codebase is that an error carries no content at
            // all rather than content someone has judged harmless, because the
            // judgement is what rots. The condition is a bridge-contract
            // break, not something a user can act on: the two sides of a
            // statically linked struct disagreeing about their own JSON.
            throw SopsBridgeError(
                description: "the bridge's answer about this project's .sops.yaml could not be read")
        }
    }

    /// Reports how many of `encrypted`'s leaves are genuinely ciphertext on
    /// disk versus how many the document actually has — read straight off
    /// the file's own shape, never by decrypting it, so this needs no age
    /// identity. See `gobridge.LeafEncryptionSummary`'s doc comment (Go
    /// side) for why this exists and what a caller may and may not
    /// conclude from the answer: a document whose own metadata narrows
    /// encryption to some keys (`encrypted_regex` and its siblings) can
    /// legitimately have `encryptedLeafCount < leafCount`, so only a
    /// caller that has independently confirmed no such narrowing applies
    /// may read that as a problem.
    ///
    /// Throws when `encrypted` has no sops metadata at all, or is not
    /// valid YAML — the same failure shape `recipients(in:)` has. `format`
    /// has no default — see `encrypt(_:format:recipients:encryptedRegex:)`.
    public static func inspectLeafEncryption(in encrypted: String, format: SopsFileFormat) throws -> LeafEncryptionSummary {
        let json = try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    sops_leaf_encryption_summary(encryptedPtr, formatPtr, out)
                }
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw SopsBridgeError(description: "bridge returned non-UTF8 JSON for the leaf encryption summary")
        }
        do {
            return try JSONDecoder().decode(LeafEncryptionSummary.self, from: data)
        } catch {
            throw SopsBridgeError(description: "could not decode the leaf encryption summary")
        }
    }

    /// Shared calling convention: 0 means *out holds the result, anything else
    /// means *out holds an error message. Either way the buffer is Go-allocated
    /// and must go back through sops_free.
    ///
    /// Internal rather than private so that the entry points which live in
    /// their own files (`SopsDocument.swift`) share this one `defer`, instead
    /// of each re-implementing the ownership rule.
    static func call(
        _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
    ) throws -> String {
        var out: UnsafeMutablePointer<CChar>?
        let status = body(&out)

        guard let out else {
            throw SopsBridgeError(description: "bridge returned no result (status \(status))")
        }
        defer { sops_free(out) }

        let payload = String(cString: out)
        guard status == 0 else {
            throw errorEnvelope(payload)
        }
        return payload
    }

    /// The shape `Engine/cshim/main.go`'s `result()` writes to `*out` on
    /// every failure: `{"kind": "...", "message": "..."}`, `kind` empty for
    /// the overwhelming majority of errors that have no classification.
    private struct ErrorEnvelope: Decodable {
        let kind: String
        let message: String
    }

    /// Decodes `raw` as an `ErrorEnvelope` and builds the `SopsBridgeError`
    /// it describes. Falls back to treating `raw` itself as the message,
    /// with no `kind`, if it does not decode — defensive only: every failure
    /// this bridge can produce today already crosses as this JSON shape, but
    /// a caller reading a decode failure as "the bridge is broken" would be
    /// strictly worse than one reading it as an unclassified error with a
    /// slightly odd message.
    private static func errorEnvelope(_ raw: String) -> SopsBridgeError {
        guard let data = raw.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data)
        else {
            return SopsBridgeError(description: raw)
        }
        return SopsBridgeError(
            description: envelope.message, kind: SopsBridgeError.Kind(rawValue: envelope.kind))
    }

    /// Ticket #4: the one buffer on this side of the cgo boundary that this
    /// app actually owns and can zero on the way out — unlike the `String`
    /// `withGoString` copies it from, which is copy-on-write, possibly
    /// small-string-optimized into its own struct, and possibly retained by
    /// other holders SwiftUI's own diffing made without this app's
    /// involvement (see `SessionKeyStore`'s doc comment for the full
    /// account of why a `String` itself cannot be reliably zeroed). `bytes`
    /// here has none of that: it is a plain heap array this function
    /// allocated, nothing else can hold a reference to it, and it is about
    /// to be freed regardless — the only question is whether an age private
    /// key's bytes are still sitting in that freed page in the meantime.
    ///
    /// `memset_s`, not a `for byte in bytes { byte = 0 }` loop: a store to
    /// memory nothing reads afterward is a dead store, and the optimizer is
    /// free to elide a dead store entirely once it can see nothing observes
    /// it — which is exactly the case here, since `bytes` goes out of scope
    /// immediately after. `memset_s` (ISO/IEC 9899:2011 Annex K) is defined
    /// never to be optimized away for precisely this reason; a plain
    /// `memset` carries no such guarantee and a future compiler is free to
    /// remove it.
    static func zeroCString(_ bytes: inout [CChar]) {
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            _ = memset_s(base, raw.count, 0, raw.count)
        }
    }
}

public extension String {
    /// The generated header takes non-const `char*`, so hand it a mutable copy.
    /// The pointer is valid only for the duration of `body`. Zeroed in a
    /// `defer` before the copy is freed — see `SopsBridge.zeroCString` for
    /// why this is a real guarantee and not a nominal one, unlike the
    /// `String` this copy was made from.
    func withGoString<R>(_ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
        var bytes = Array(utf8CString)
        defer { SopsBridge.zeroCString(&bytes) }
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }

    /// Whether this string can cross a NUL-terminated C boundary intact.
    ///
    /// A raw NUL is valid UTF-8, so it survives `String(contentsOf:)` and
    /// reaches `withGoString`, where `utf8CString` ends the argument early and
    /// **everything after it is silently gone**. Two complete, individually
    /// valid SOPS documents joined by one NUL byte open without complaint
    /// showing only the first document's rows — and the next save writes back
    /// what was shown, permanently deleting the second document's secrets. The
    /// user never saw them and nothing reported anything. The real `sops` CLI
    /// refuses the same file (`yaml: control characters are not allowed`), so
    /// this was also a read-direction divergence from the CLI that ADR 0001
    /// requires round-tripping with.
    ///
    /// The durable fix is a length-prefixed boundary, which ADR 0001 already
    /// anticipates for the binary format. Until that exists, refusing is the
    /// honest answer: this app cannot read the file, and saying so beats
    /// showing half of it.
    public var crossesCBoundaryIntact: Bool {
        !utf8.contains(0)
    }
}
