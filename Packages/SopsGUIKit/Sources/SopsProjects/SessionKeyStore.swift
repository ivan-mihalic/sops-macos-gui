import Foundation
import Observation
import SopsHealth

/// Holds the user's age decryption identity for the lifetime of the running
/// process only — never on disk, never in `UserDefaults`, never in the
/// Keychain.
///
/// This is the M2 shape of key storage per the decision recorded for this
/// milestone: Keychain storage with Touch ID and a session TTL is M3. Until
/// then the key is imported by an explicit user gesture (`importKey(_:)` /
/// `importFromLegacyKeyFile(at:)`, both driven by `KeyImportView`, never
/// anything automatic) and lives in a single `private var` for as long as the
/// app runs, or until `forget()` is called.
///
/// Every caller already goes through this type's protocol-shaped surface
/// (`state`, `importKey`, `forget`, `withKey`) rather than a raw `String`, so
/// M3 can swap what backs them for a Keychain-backed implementation without
/// touching a single call site.
///
/// ## Why this class does not itself conform to `KeyStoreStatusProviding`
/// `KeyStoreStatusProviding` inherits `Sendable`, and under Swift 6.2's
/// isolated-conformance rules a `Sendable`-inheriting protocol cannot be
/// satisfied by a conformance isolated to a global actor (the compiler's own
/// diagnostic: "cannot form main actor-isolated conformance ... to
/// SendableMetatype-inheriting protocol") — `state` is main-actor-isolated
/// here (it reads `key`, a main-actor-isolated stored property), so the class
/// cannot conform directly without either losing that isolation or reaching
/// for `nonisolated(unsafe)` storage, which would reintroduce exactly the
/// unsynchronized access this type exists to avoid. `ProjectStore` hits the
/// identical wall against `ProjectSourceProviding` (also `Sendable`) and
/// resolves it the same way this does: a small `Sendable` value-type
/// snapshot — `HealthSource` below — that captures `state` at the moment
/// it's read and satisfies the protocol on its own. `HealthReport.standard`
/// is called with `keyStore: store.healthSource`, exactly as it already is
/// with `projects: store.healthSource`.
///
/// ## Why `withKey` instead of a getter
/// A plain `var key: String? { get }` would let a caller copy the key out
/// into a local variable, pass it around, and hold onto it for as long as it
/// likes — exactly the exposure this type exists to bound. `withKey` lends
/// the key to a closure for the duration of one call; nothing about the key
/// itself needs to survive past that.
///
/// ## What this does *not* protect against
/// Swift's `String` is copy-on-write, immutable-once-shared value storage —
/// there is no supported way to zero its backing buffer on demand, and the
/// runtime is free to keep other copies alive (SwiftUI's own state diffing,
/// `@Observable`'s change tracking, ARC retaining an enclosing closure) for
/// as long as it likes. This type does not attempt to fight that. It holds
/// exactly one `String`, in exactly one place, and never logs, prints, or
/// serializes it — that is the whole of its guarantee. The actual fix for
/// "a Swift `String` cannot be reliably zeroed" is M3's Keychain-backed
/// store, which never materializes the key as a long-lived Swift `String` in
/// the app's own memory in the first place; this type only holds the
/// perimeter (never touches disk, never appears in an error) until then.
@MainActor
@Observable
public final class SessionKeyStore {

    public enum Error: Swift.Error, Equatable, Sendable {
        /// The text, once trimmed, does not start with `AGE-SECRET-KEY-1`.
        ///
        /// This also covers a well-formed `AGE-PLUGIN-…` identity.
        /// `Engine/gobridge/bridge.go` documents why that matters: sops's own
        /// `parseIdentity` routes an `AGE-PLUGIN-…` string to
        /// `plugin.NewIdentity`, which executes an `age-plugin-*` binary
        /// found on `PATH` — a second code-execution vector past the one
        /// ADR 0001 already closed for ambient key discovery. The bridge
        /// rejects it too (`agePrivateKeyPrefix`), so this is not the only
        /// thing standing between a plugin identity and execution — but
        /// failing here means it never crosses the Swift/Go boundary at all,
        /// and the message names the app's own import UI instead of an
        /// internal bridge error.
        case notAnAgeKey
        /// The text, once whitespace is trimmed and comment lines are
        /// stripped, has nothing left in it — an empty paste, a
        /// whitespace-only paste, or a comment-only paste (e.g. someone
        /// selected only the `# public key: age1…` line of a `keys.txt` by
        /// mistake).
        case empty
        /// A `keys.txt` import found more than one non-comment line. See
        /// `importFromKeysFileContents(_:)`'s doc comment for the decision
        /// behind refusing rather than guessing which one the user meant.
        case multipleKeysInFile(count: Int)
        /// The paste field was given more than one line.
        ///
        /// Its own case rather than `.multipleKeysInFile`, because the message
        /// for that one names a *file* and a count of keys, and on this path
        /// there is no file and the extra line is very often the `# public
        /// key:` comment `age-keygen` prints — not a second key at all. Carries
        /// no count: what the extra lines are is not something this can know,
        /// and a number here was read as "keys" by the only thing that showed
        /// it.
        case multipleLinesPasted
        /// A key file holds at most one age key, but also holds lines that are
        /// neither a key nor a comment, so which line to import is not
        /// something this app should guess at.
        ///
        /// Distinct from `.multipleKeysInFile`, whose message counts keys and
        /// tells the user to remove the extra ones. There are no extra keys
        /// here — there is other content — and "trim the file to the one you
        /// want" sends the reader hunting for a second key that is not there.
        case unreadableKeysFile
    }

    private static let agePrivateKeyPrefix = "AGE-SECRET-KEY-1"

    private var key: String?

    public init() {}

    public var state: KeyStoreState {
        key == nil ? .empty : .configured
    }

    /// Validates and stores `text` as the session's decryption identity.
    ///
    /// Trims surrounding whitespace and newlines first — a paste from a
    /// terminal `age-keygen -o keys.txt; cat keys.txt` session routinely
    /// carries a trailing newline, and the paste field itself may add
    /// leading/trailing whitespace depending on how the user selected the
    /// text. What is left must be non-empty and start with
    /// `AGE-SECRET-KEY-1` (see `Error.notAnAgeKey` for why that specific
    /// prefix, and not merely "non-empty").
    ///
    /// This check duplicates one the Go bridge already makes
    /// (`Engine/gobridge/bridge.go`'s `agePrivateKeyPrefix` guard) — that is
    /// deliberate, not redundant. Failing here gives a message that belongs
    /// to this app's own import flow rather than an internal bridge error,
    /// and it keeps a bad key from crossing the Swift/Go boundary at all.
    public func importKey(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Error.empty }

        // A pasted blob containing more than one line is a `keys.txt`, not a
        // key. It used to be accepted whole: `trimmingCharacters` only touches
        // the ends, so two keys separated by a newline went straight into
        // `key`, and `parseDecryptionIdentities` on the Go side imported
        // **both**. That contradicted this type's own doc comment — "the paste
        // field … always accepts exactly one key, by construction" — and it
        // routed around the `.multipleKeysInFile` refusal that
        // `importFromKeysFileContents` enforces. `cat keys.txt`, paste, done.
        guard trimmed.hasPrefix(Self.agePrivateKeyPrefix) else { throw Error.notAnAgeKey }

        let lines = trimmed.split(whereSeparator: \.isNewline)
        guard lines.count == 1 else {
            // `.multipleLinesPasted`, not `.multipleKeysInFile`: this is the
            // paste field and there is no file. The old case produced "That
            // file has 2 keys in it … trim the file to the one you want" for
            // someone who pasted a key and the `# public key:` comment
            // underneath it — naming a file they never touched, counting a
            // comment as a key, and advising an edit that would not help.
            throw Error.multipleLinesPasted
        }

        // The prefix is 16 characters; a real age identity is Bech32 with a
        // fixed length. Checking only the prefix meant `AGE-SECRET-KEY-1` plus
        // anything — a truncated paste, a typo'd character — was accepted,
        // `state` became `.configured`, and `SecurityPostureCheck` then
        // reported `.ok`: "An age key is imported for this session." The user
        // read an all-clear and could not decrypt a thing, because the real
        // refusal came from `gobridge` on every single file open.
        //
        // This is a shape check, not a validity check: it cannot tell a
        // well-formed key from one that decrypts nothing, and it does not try.
        // What it stops is the *shape* of failure that Health calls healthy.
        guard Self.looksLikeACompleteAgeKey(trimmed) else { throw Error.notAnAgeKey }

        key = trimmed
    }

    /// Whether `candidate` has the length and alphabet `age-keygen` produces.
    ///
    /// age private keys are Bech32 over the `age-secret-key-` HRP: the body is
    /// the Bech32 charset (`qpzry9x8gf2tvdw0s3jn54khce6mua7l`, upper-cased by
    /// age), and `age-keygen` emits a fixed 74-character identity. Anything
    /// shorter is a truncated paste; anything containing `b`, `i`, `o` or `1`
    /// in the body is not Bech32 at all.
    private static func looksLikeACompleteAgeKey(_ candidate: String) -> Bool {
        guard candidate.count == 74 else { return false }
        let body = candidate.dropFirst(agePrivateKeyPrefix.count)
        let bech32 = Set("QPZRY9X8GF2TVDW0S3JN54KHCE6MUA7L")
        return body.allSatisfy { bech32.contains($0) }
    }

    /// Extracts a single decryption identity from `keys.txt`-shaped content
    /// (comment lines starting with `#`, blank lines, and key lines — the
    /// format `age-keygen -o keys.txt` writes) and imports it exactly as
    /// `importKey(_:)` would.
    ///
    /// ## The multi-key decision
    /// A `keys.txt` this app did not write itself can legitimately contain
    /// more than one key — a user's own multi-environment habit, or years of
    /// `age-keygen -o keys.txt` output getting appended to rather than
    /// overwritten. This session store holds exactly one identity at a time,
    /// and picking one automatically ("first line wins", "last line wins")
    /// would silently discard a key the user may actually need without ever
    /// telling them a choice was made on their behalf. That is worse than
    /// refusing outright, so this refuses: `.multipleKeysInFile(count:)`
    /// names how many candidate lines were found, and the caller
    /// (`KeyImportView`) is expected to tell the user to either trim the
    /// file to the one key they want, or paste that specific key into the
    /// paste field directly — which always accepts exactly one key, by
    /// construction.
    /// Splitting on `"\n"` (a single-`Character` separator) does not do what
    /// it looks like it does: Swift's `Character` is an extended grapheme
    /// cluster, and CRLF (`"\r\n"`) is *one* such cluster, not two. A
    /// `keys.txt` written on Windows, or passed through `git
    /// core.autocrlf=true`, or edited on a shared drive, never contains a
    /// bare `"\n"` character at all — splitting on it left the whole file as
    /// a single "line", which broke this method two different ways at once:
    /// an all-comment CRLF file was refused as `.empty` even with a good key
    /// present (the key line was never separated out), and a key-first CRLF
    /// file had its key *and* every following `\r\n#comment` line accepted
    /// as one `AGE-SECRET-KEY-1…`-prefixed blob — silently defeating the
    /// multi-key refusal this method exists to enforce, since nothing was
    /// ever split into candidates to count.
    ///
    /// This is the second time this exact gotcha has bitten this codebase —
    /// Task 1b's `String.contains("\nsops:")` had the identical blind spot
    /// against `"\r\nsops:"`. `Character.isNewline` is the fix both times:
    /// it recognizes LF, CR, and the CRLF cluster as a single newline each,
    /// so `split(whereSeparator:)` breaks the content into lines correctly
    /// under any of the three.
    func importFromKeysFileContents(_ contents: String) throws {
        let keyLines = contents
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }

        guard !keyLines.isEmpty else { throw Error.empty }

        // Two different problems, two different sentences. Reporting both as
        // "that file has N keys in it" is how this got told a user their
        // one-key file had 1 keys in it and to trim it to one — a count that
        // named the right number and still described nothing, with the advice
        // pointing at a second key that does not exist. (The first attempt at
        // this only changed the number; the number was never the defect.)
        let keyCount = keyLines.filter { $0.hasPrefix(Self.agePrivateKeyPrefix) }.count
        if keyCount > 1 { throw Error.multipleKeysInFile(count: keyCount) }
        guard keyLines.count == 1 else { throw Error.unreadableKeysFile }
        try importKey(keyLines[0])
    }

    /// Reads `path` and imports it via `importFromKeysFileContents(_:)`.
    ///
    /// This is a **read**, nothing more — CLAUDE.md's "the app never mutates
    /// the system" applies to this file exactly as it does everywhere else.
    /// The file is never moved, chmod'd, or deleted by this call; the only
    /// mutation possible from calling this is to this store's own in-memory
    /// `key`, and only on success.
    ///
    /// This is also always an explicit user gesture from `KeyImportView`'s
    /// key-file import control — a button when exactly one candidate file
    /// exists, a menu the user picks from when several do (see
    /// `LegacyKeyFileImportOptions`) — never something this app does on its
    /// own, and never a path this app chose. `SecurityPostureCheck`'s
    /// `security.legacy-key-file` finding exists precisely to warn that this
    /// file sits unprotected, and silently reading it on the app's own
    /// initiative would contradict that warning.
    public func importFromLegacyKeyFile(at path: String) throws {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        try importFromKeysFileContents(contents)
    }

    /// Returns the store to empty.
    ///
    /// The previous key is dropped — not zeroed, see the type's doc comment
    /// for why that is not a promise this type can make — and becomes
    /// unreachable through this store. Whether the Swift runtime has
    /// actually freed the backing storage afterward is outside this app's
    /// control.
    public func forget() {
        key = nil
    }

    /// Lends the key to `body` for the duration of the call, and only for
    /// that duration — nothing about the key is retained past `body`
    /// returning (or throwing).
    ///
    /// Returns `nil`, without invoking `body`, if no key is configured.
    /// Callers that need to distinguish "no key was configured" from "`body`
    /// itself produced `nil`" should check `state` first.
    public func withKey<R>(_ body: (String) throws -> R) rethrows -> R? {
        guard let key else { return nil }
        return try body(key)
    }

    /// The `async` twin of `withKey(_:)`, for a caller whose use of the key is
    /// itself long-running enough to need to run off the main actor (a
    /// whole-document decrypt/encrypt over a few thousand keys measures in
    /// the hundreds of milliseconds — long enough to stall the UI if it runs
    /// inline here).
    ///
    /// The lending guarantee is the same, just spanning an `await`: `body`
    /// receives the key, is free to hop off this actor to do its work (e.g.
    /// `Task.detached { ... }`), and nothing about the key is retained by
    /// this store — or by the caller — past `body` returning. The caller
    /// never holds the key itself; only `body`, which this store invokes
    /// directly, ever sees it, exactly as with the synchronous overload.
    public func withKey<R>(_ body: (String) async throws -> R) async rethrows -> R? {
        guard let key else { return nil }
        return try await body(key)
    }

    // MARK: - SopsHealth adapter

    /// Adapts this store to `KeyStoreStatusProviding` so `SecurityPostureCheck`
    /// can report whether a key is configured, instead of the
    /// `UnshippedKeyStore` stub. See the type's doc comment ("Why this class
    /// does not itself conform...") for why this snapshot exists rather than
    /// a direct conformance.
    public struct HealthSource: KeyStoreStatusProviding {
        public let state: KeyStoreState

        fileprivate init(state: KeyStoreState) {
            self.state = state
        }
    }

    public var healthSource: HealthSource {
        HealthSource(state: state)
    }
}
