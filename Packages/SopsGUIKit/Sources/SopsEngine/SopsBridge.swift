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

    /// Shared calling convention: 0 means *out holds the result, anything else
    /// means *out holds an error message. Either way the buffer is Go-allocated
    /// and must go back through sops_free.
    private static func call(
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

extension String {
    /// The generated header takes non-const `char*`, so hand it a mutable copy.
    /// The pointer is valid only for the duration of `body`.
    fileprivate func withGoString<R>(_ body: (UnsafeMutablePointer<CChar>) -> R) -> R {
        var bytes = Array(utf8CString)
        return bytes.withUnsafeMutableBufferPointer { body($0.baseAddress!) }
    }
}
