import CSopsBridge
import Foundation

/// One editable line of a SOPS document.
///
/// Swift holds these to *display* values and to hand edits back. It never
/// parses or re-emits the document itself: doing that would round-trip the
/// user's YAML through a second implementation, silently dropping comments,
/// reordering keys and rewriting scalar quoting. The document lives in Go and
/// sops's own stores do the round trip — ADR 0002's rule, applied to the file
/// format rather than the configuration format.
public struct SecretRow: Identifiable, Equatable, Sendable, Decodable {

    /// The YAML type of a value. Carrying this is what stops a port number the
    /// editor displayed as `5432` from being written back as the string
    /// `"5432"` — a one-character change to the user's file that nobody asked
    /// for. It is handed back with an edit, so an untouched type stays
    /// untouched and changing a type is something the caller had to choose.
    public enum Kind: String, Codable, Sendable {
        case string
        case int
        case float
        case bool
        case null
        case timestamp
        /// A key whose value is an empty map or list. It has no value of its
        /// own to edit, but it is in the file, so the editor shows it rather
        /// than leaving the key invisible.
        case emptyMap
        case emptyList

        /// Whether this row holds a value the editor can change.
        public var isEditable: Bool {
            switch self {
            case .emptyMap, .emptyList: return false
            default: return true
            }
        }
    }

    /// Which YAML document within the file this row belongs to. Almost always
    /// `0`; a multi-document file needs it so an edit cannot land in the wrong
    /// document.
    public let document: Int

    /// The key path to the value. Map keys appear verbatim, list elements as
    /// their decimal index. The two never collide, because the path is
    /// resolved against the document — a level is either a map or a list, so
    /// `"0"` means the key `0` under a map and index 0 under a list, decided
    /// by what is actually there.
    public let path: [String]

    /// The decrypted value as text.
    public var value: String

    public let kind: Kind

    /// Whether this value is ciphertext in the file on disk. Read from the
    /// file, not derived from `.sops.yaml`, so with an `encrypted_regex` the
    /// editor knows which values are actually protected. Note that sops never
    /// encrypts a null or an empty string, so those report `false` whatever
    /// the rules say.
    public let isEncrypted: Bool

    /// Stable across reloads of the same document, because it is derived from
    /// the row's position in the file rather than from its contents — a row
    /// keeps its identity when its value changes.
    public var id: String {
        ([String(document)] + path.map { "\($0.count):\($0)" }).joined(separator: ":")
    }

    public init(document: Int = 0, path: [String], value: String, kind: Kind, isEncrypted: Bool) {
        self.document = document
        self.path = path
        self.value = value
        self.kind = kind
        self.isEncrypted = isEncrypted
    }

    private enum CodingKeys: String, CodingKey {
        case document, path, value, kind
        case isEncrypted = "encrypted"
    }
}

/// A new value for one existing row.
///
/// Adding and removing keys changes the shape of the document and is not part
/// of this API.
public struct SecretEdit: Encodable, Equatable, Sendable {
    public let document: Int
    public let path: [String]
    public let value: String
    public let kind: SecretRow.Kind

    public init(document: Int = 0, path: [String], value: String, kind: SecretRow.Kind) {
        self.document = document
        self.path = path
        self.value = value
        self.kind = kind
    }

    /// The edit that writes `row`'s current value back.
    public init(row: SecretRow) {
        self.init(document: row.document, path: row.path, value: row.value, kind: row.kind)
    }
}

extension SopsBridge {

    /// Decrypts a SOPS YAML document into the ordered rows the editor renders.
    ///
    /// `agePrivateKey` must be a native `AGE-SECRET-KEY-1…` identity. A key
    /// argument that yields no identity throws — it is never a signal to look
    /// at `SOPS_AGE_KEY`, `SOPS_AGE_KEY_FILE`, `SOPS_AGE_KEY_CMD` or
    /// `~/.config/sops/age/keys.txt` (ADR 0001).
    ///
    /// Throws when the document cannot be read: a wrong identity, a MAC that
    /// does not verify, a file that is not a SOPS document. It never returns an
    /// empty row list to mean "could not decrypt" — a document the app could
    /// not read must not present as an empty form the user might save over
    /// their file.
    public static func decryptToRows(
        _ encrypted: String, agePrivateKey: String
    ) throws -> [SecretRow] {
        let json = try call { out in
            encrypted.withGoString { encryptedPtr in
                agePrivateKey.withGoString { keyPtr in
                    sops_decrypt_to_rows(encryptedPtr, keyPtr, out)
                }
            }
        }
        guard let data = json.data(using: .utf8) else {
            throw SopsBridgeError(description: "bridge returned non-UTF8 JSON for the row list")
        }
        do {
            return try JSONDecoder().decode([SecretRow].self, from: data)
        } catch {
            // The payload contains plaintext values, so the decoding error —
            // which quotes the input it choked on — is deliberately not
            // included in the message.
            throw SopsBridgeError(description: "could not decode the row list returned by the bridge")
        }
    }

    /// Applies edited values to an existing SOPS YAML document and returns the
    /// re-encrypted file.
    ///
    /// The saved file keeps **its own** metadata: recipients, `encrypted_regex`,
    /// MAC settings, `shamir_threshold`, and the sops version recorded in it.
    /// Nothing here reads `.sops.yaml`. A file whose rules have drifted from
    /// the project config is not silently rewritten to match it — re-wrapping
    /// data keys is `sops updatekeys`, an operation the user asks for, not a
    /// side effect of pressing save.
    ///
    /// Errors name the key path that failed and never the value: an error
    /// string is exactly the kind of text that reaches a log, a screenshot or a
    /// crash report, and this path handles plaintext.
    public static func applyEdits(
        _ encrypted: String, edits: [SecretEdit], agePrivateKey: String
    ) throws -> String {
        let editsJSON: String
        do {
            let data = try JSONEncoder().encode(edits)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SopsBridgeError(description: "the edits could not be encoded")
            }
            editsJSON = text
        } catch let error as SopsBridgeError {
            throw error
        } catch {
            throw SopsBridgeError(description: "the edits could not be encoded")
        }

        return try call { out in
            encrypted.withGoString { encryptedPtr in
                editsJSON.withGoString { editsPtr in
                    agePrivateKey.withGoString { keyPtr in
                        sops_apply_edits(encryptedPtr, editsPtr, keyPtr, out)
                    }
                }
            }
        }
    }
}
