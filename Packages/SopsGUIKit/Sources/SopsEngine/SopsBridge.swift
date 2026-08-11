import CSopsBridge
import Foundation

public struct SopsBridgeError: Error, CustomStringConvertible, Equatable {
    public let description: String
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

/// In-process SOPS engine. Every call crosses into the Go runtime linked from
/// the static bridge; no `sops` binary is ever spawned.
public enum SopsBridge {

    public static func encryptYAML(
        _ plain: String,
        recipients: [String],
        encryptedRegex: String = ""
    ) throws -> String {
        try call { out in
            plain.withGoString { plainPtr in
                recipients.joined(separator: ",").withGoString { recipientsPtr in
                    encryptedRegex.withGoString { regexPtr in
                        sops_encrypt_yaml(plainPtr, recipientsPtr, regexPtr, out)
                    }
                }
            }
        }
    }

    public static func decryptYAML(_ encrypted: String, agePrivateKey: String) throws -> String {
        try call { out in
            encrypted.withGoString { encryptedPtr in
                agePrivateKey.withGoString { keyPtr in
                    sops_decrypt_yaml(encryptedPtr, keyPtr, out)
                }
            }
        }
    }

    /// Returns the native age recipients stored in this document's SOPS
    /// metadata. Reading recipient metadata requires no private identity.
    public static func recipients(in encrypted: String) throws -> [String] {
        let json = try call { out in
            encrypted.withGoString { encryptedPtr in
                sops_recipients(encryptedPtr, out)
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
    /// a project config or a key from the environment.
    public static func updateRecipients(
        _ encrypted: String,
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
                recipientsJSON.withGoString { recipientsPtr in
                    agePrivateKey.withGoString { keyPtr in
                        sops_update_recipients(encryptedPtr, recipientsPtr, keyPtr, out)
                    }
                }
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
            throw SopsBridgeError(description: "could not decode creation rule lookup JSON: \(error)")
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
            throw SopsBridgeError(description: "could not decode config backend JSON: \(error)")
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

        let message = String(cString: out)
        guard status == 0 else {
            throw SopsBridgeError(description: message)
        }
        return message
    }
}

public extension String {
    /// The generated header takes non-const `char*`, so hand it a mutable copy.
    /// The pointer is valid only for the duration of `body`.
    func withGoString<R>(_ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
        var bytes = Array(utf8CString)
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
