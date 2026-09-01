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

    /// Whether this row's immediate parent is a list rather than a map.
    ///
    /// The editor needs this before it can offer to add a sibling — a map key
    /// needs a name, a list entry is appended — and it cannot be read off the
    /// path, because a map key `"0"` and list index `0` are the same text.
    /// The bridge's walk decides it by looking at the container itself.
    public let isInList: Bool

    /// Whether this row was added in this editing session and is not in the
    /// file yet.
    ///
    /// It exists so the editor can avoid making a claim it cannot support:
    /// `isEncrypted` is honestly `false` for a row that is not in the file at
    /// all, but an open padlock next to a value that *will* be encrypted the
    /// moment it is saved would tell the user something untrue. A pending row
    /// says "new" instead of claiming either way. Never decoded from the
    /// bridge — the bridge only ever describes what is on disk.
    public var isPendingAdd: Bool = false

    /// Whether this value is ciphertext in the file on disk. Read from the
    /// file, not derived from `.sops.yaml`, so with an `encrypted_regex` the
    /// editor knows which values are actually protected. Note that sops never
    /// encrypts a null or an empty string, so those report `false` whatever
    /// the rules say.
    public let isEncrypted: Bool

    /// Stable across reloads of the same document, because it is derived from
    /// the row's path rather than from its value — a row keeps its identity
    /// when its value changes.
    ///
    /// ## Why the path components are base64, not the text
    ///
    /// The previous form was `"\(component.count):\(component)"`, and a
    /// length prefix does make a *byte* encoding injective. This is a Swift
    /// `String`, and Swift string equality is canonical equivalence: `café`
    /// written NFC and NFD are one value here and `.count` is 4 for both,
    /// while go-yaml, sops and the C boundary see five bytes and six. Two
    /// genuinely different keys therefore produced **one** `id`.
    ///
    /// What that cost: `SecretDocumentViewModel.pendingChangeSet()` looks each
    /// baseline row up in `editedValues` by `id`, so both rows matched. One
    /// edit became two `SecretEdit`s, one deletion became two `SecretRemoval`s,
    /// and the untouched key was silently overwritten with the edited one's
    /// value. The Go side cannot catch it — `planChanges` keys by bytes, so
    /// those are legitimately distinct paths and nothing is contradictory.
    ///
    /// Base64 of the UTF-8 bytes is injective over exactly what the rest of
    /// the stack considers distinct, and it needs no separator discipline
    /// because the alphabet excludes `:`. Mixing NFC and NFD is not exotic on
    /// macOS — HFS+ paths and pasted text produce it routinely — and the
    /// failure mode was permanent loss of a secret the user never touched.
    public var id: String {
        ([String(document)] + path.map { Data($0.utf8).base64EncodedString() })
            .joined(separator: ":")
    }

    public init(
        document: Int = 0,
        path: [String],
        value: String,
        kind: Kind,
        isInList: Bool = false,
        isPendingAdd: Bool = false,
        isEncrypted: Bool
    ) {
        self.document = document
        self.path = path
        self.value = value
        self.kind = kind
        self.isInList = isInList
        self.isPendingAdd = isPendingAdd
        self.isEncrypted = isEncrypted
    }

    private enum CodingKeys: String, CodingKey {
        case document, path, value, kind
        case isInList = "inList"
        case isEncrypted = "encrypted"
    }
}

/// A new value for one existing row.
///
/// Adding and removing keys changes the shape of the document; those are
/// `SecretAddition` and `SecretRemoval` below, and all three travel together
/// in a `SecretChangeSet`.
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

/// A new entry in a map or a list that is already in the document.
///
/// The new entry always goes at the **end** of its container. There is no way
/// to express "insert at position N", deliberately: an insertion renumbers
/// every later list element exactly as a removal does, and the bridge refuses
/// that ambiguity rather than resolving it by guesswork.
public struct SecretAddition: Encodable, Equatable, Sendable {
    public let document: Int
    /// The map or list to add into. Empty means the document's root map.
    public let parent: [String]
    /// The new map key's name. Required when `parent` is a map, and must be
    /// empty when `parent` is a list, where the position comes from appending
    /// rather than from the caller.
    public let key: String
    public let value: String
    public let kind: SecretRow.Kind

    public init(document: Int = 0, parent: [String], key: String = "", value: String, kind: SecretRow.Kind) {
        self.document = document
        self.parent = parent
        self.key = key
        self.value = value
        self.kind = kind
    }
}

/// One entry to delete: a map key or a list element.
///
/// A removal that finds nothing is an error, not a quiet success — the
/// caller's picture of the document and the file on disk disagree, and
/// reporting a save that did not happen is the failure this whole editor
/// exists to avoid. A key that still has entries under it is refused too:
/// every row the editor shows is a leaf or an empty container, so nothing the
/// user can point at is lost by refusing, and a mis-specified path can never
/// take a whole subtree with it.
public struct SecretRemoval: Encodable, Equatable, Sendable {
    public let document: Int
    public let path: [String]

    public init(document: Int = 0, path: [String]) {
        self.document = document
        self.path = path
    }
}

/// Everything one save does to a document.
///
/// ## The index-shift rule
/// Every path here is resolved against the document **as it was loaded**.
/// Removing a list element renumbers everything after it, so a change set
/// that removes from a list *and* addresses a later position in that same
/// list is refused by the bridge rather than guessed at — the two possible
/// readings are different values and there is no way to tell which was meant.
/// For an accepted change set both readings coincide, so the result is
/// certain rather than plausible.
///
/// Two things that are therefore *not* refused: appending to the very list a
/// removal came out of (an addition names a container, never a position), and
/// removing map keys, which are addressed by name and renumber nothing.
public struct SecretChangeSet: Encodable, Equatable, Sendable {
    public var sets: [SecretEdit]
    public var adds: [SecretAddition]
    public var removes: [SecretRemoval]

    public init(sets: [SecretEdit] = [], adds: [SecretAddition] = [], removes: [SecretRemoval] = []) {
        self.sets = sets
        self.adds = adds
        self.removes = removes
    }

    public var isEmpty: Bool { sets.isEmpty && adds.isEmpty && removes.isEmpty }
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
    /// their file. `format` has no default — see
    /// `SopsBridge.encrypt(_:format:recipients:encryptedRegex:)`.
    public static func decryptToRows(
        _ encrypted: String, format: SopsFileFormat, agePrivateKey: String
    ) throws -> [SecretRow] {
        let json = try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    agePrivateKey.withGoString { keyPtr in
                        sops_decrypt_to_rows(encryptedPtr, formatPtr, keyPtr, out)
                    }
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
    /// crash report, and this path handles plaintext. `format` has no
    /// default — see `SopsBridge.encrypt(_:format:recipients:encryptedRegex:)`.
    public static func applyEdits(
        _ encrypted: String, format: SopsFileFormat, edits: [SecretEdit], agePrivateKey: String
    ) throws -> String {
        let editsJSON = try encodeToJSON(edits, failureMessage: "the edits could not be encoded")
        return try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    editsJSON.withGoString { editsPtr in
                        agePrivateKey.withGoString { keyPtr in
                            sops_apply_edits(encryptedPtr, formatPtr, editsPtr, keyPtr, out)
                        }
                    }
                }
            }
        }
    }

    /// Applies a whole change set — edits, additions and removals — to an
    /// existing SOPS YAML document and returns the re-encrypted file.
    ///
    /// Everything `applyEdits` guarantees holds here unchanged: the file
    /// keeps **its own** metadata, nothing reads `.sops.yaml`, and an error
    /// names the key path that failed and never the value.
    ///
    /// The change set is validated in full before the document is touched, so
    /// a refusal never leaves half a save applied, and a failure returns no
    /// bytes at all. See `SecretChangeSet` for the one rule that is specific
    /// to structural changes: a batch whose list indices could be read two
    /// ways is refused rather than guessed at. `format` has no default — see
    /// `SopsBridge.encrypt(_:format:recipients:encryptedRegex:)`.
    public static func applyChanges(
        _ encrypted: String, format: SopsFileFormat, changes: SecretChangeSet, agePrivateKey: String
    ) throws -> String {
        let changesJSON = try encodeToJSON(changes, failureMessage: "the changes could not be encoded")
        return try call { out in
            encrypted.withGoString { encryptedPtr in
                format.rawValue.withGoString { formatPtr in
                    changesJSON.withGoString { changesPtr in
                        agePrivateKey.withGoString { keyPtr in
                            sops_apply_changes(encryptedPtr, formatPtr, changesPtr, keyPtr, out)
                        }
                    }
                }
            }
        }
    }

    /// The payload being encoded is plaintext, so an encoding failure is
    /// reported with a fixed message — `EncodingError`'s own description
    /// quotes the value it choked on.
    private static func encodeToJSON<T: Encodable>(_ value: T, failureMessage: String) throws -> String {
        do {
            let data = try JSONEncoder().encode(value)
            guard let text = String(data: data, encoding: .utf8) else {
                throw SopsBridgeError(description: failureMessage)
            }
            return text
        } catch let error as SopsBridgeError {
            throw error
        } catch {
            throw SopsBridgeError(description: failureMessage)
        }
    }
}
