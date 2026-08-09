import Foundation
import Observation
import SopsEngine
import SopsProjects

/// Whether the document currently backing a `SecretDocumentViewModel` could be
/// read and decrypted.
///
/// `.needsKey` and `.failed` are deliberately distinct from `.loaded` with an
/// empty `rows` array: a file this app could not open must never present as
/// though it were open and simply empty. A blank editor the user can "save"
/// is how their secrets get overwritten with nothing — the M1 lesson
/// ("a check that cannot establish something must SAY so, never render as if
/// it had"), applied to the editor.
public enum LoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    /// No decryption identity is configured in the session key store. This is
    /// reported before any bridge call is made — the file itself was never
    /// even attempted, so this is not a claim about the file being unreadable.
    case needsKey
    /// The file could not be decrypted with the identity that is configured:
    /// a wrong key, a MAC mismatch, a damaged value, or a document sops does
    /// not recognise as its own.
    ///
    /// The associated text is `SopsBridgeError.description` verbatim — sops's
    /// own classified message. `Engine/gobridge` (Task 7) guarantees it never
    /// contains a value from the document: only fixed English and, where
    /// relevant, a key path.
    case failed(String)
}

/// The result of `SecretDocumentViewModel.save()`.
public enum SaveOutcome: Equatable, Sendable {
    case saved
    /// The associated text never contains a row's value — see
    /// `LoadState.failed`'s doc comment for why that guarantee holds.
    case failed(String)
}

/// An outcome that carries a plain message on failure, instead of
/// `Swift.Result`'s `Failure: Error` — `SopsBridgeError`'s only public
/// surface this type needs is its `description`, and its initializer is
/// internal to `SopsEngine`, so there is nothing to re-wrap as an `Error`
/// here anyway. `Sendable` because it crosses onto a dedicated `Thread` and
/// back — see `SecretDocumentViewModel.runOffCooperativePool(_:)`.
private enum Outcome<Success: Sendable>: Sendable {
    case success(Success)
    case failure(String)
}

/// Loads one SOPS document into editable rows, tracks which values the user
/// changed, and saves.
///
/// This type never parses or re-emits YAML itself — it only holds the
/// `SecretRow` values the bridge produced and hands edited ones back to
/// `SopsBridge.applyEdits`. See `SecretRow`'s doc comment for why: a second
/// YAML implementation on this side would silently diverge from sops's own
/// round trip (ADR 0002).
///
/// ## Add/remove rows
/// `addRow` and `removeRow` are backed by real bridge operations
/// (`SopsBridge.applyChanges`), not by splicing `rows` and hoping — a
/// structural edit that looked successful in the UI and vanished on save is
/// the exact failure this milestone exists to close.
///
/// The pending state is kept as *changes against the loaded document* —
/// which values were edited, which rows were removed, which rows were added —
/// and `rows` is recomposed from the baseline plus those changes on every
/// mutation. Nothing is spliced in place. That is what makes the dirty flag
/// exact rather than approximate: adding a row and then removing it again
/// leaves no pending change at all, so the document is clean, not "dirty
/// because something happened once".
///
/// **Every** save reloads from the bytes it just produced instead of trusting
/// the in-memory rows. It has to: removing a list element renumbers everything
/// after it, so the paths this type is holding stop matching the file the
/// moment such a save succeeds, and the next edit would land on the wrong
/// element. A value-only save cannot move a path — but it can still change
/// what the file says about a row (whether the value is ciphertext, for one),
/// so it is re-read too. See `adoptSavedDocument(_:)` for the fast path that
/// used to be here and the padlock it got wrong.
///
/// ## Merge keys
/// A row whose path contains the literal segment `"<<"` comes from a YAML
/// merge key (`<<: *anchor`) — sops's own row walk inlines the merged map
/// and reports it that way (Task 7 §10/§14). This type does nothing special
/// with such a row: it loads, displays, edits and saves exactly like any
/// other, because at the tree level it *is* an ordinary leaf — editing it
/// changes the inlined copy, not the anchor, which is the same thing
/// `sops set` would do. The `"<<"` segment stays visible in `row.path` for
/// any caller that wants to detect it (`row.path.contains("<<")`); Task 9's
/// view decides whether to render that plainly or refuse it, since that is a
/// presentation choice, not a correctness one — this type does not hide,
/// filter, or relabel the row.
///
/// ## `isEncrypted` on empty strings and nulls
/// `SecretRow.isEncrypted` is honestly `false` for an empty string or a
/// null, because sops itself never encrypts either (Task 7 §"Concerns
/// to carry forward"). This type passes that flag through unchanged rather
/// than inferring "protected" from the file having an `encrypted_regex` —
/// Task 9's masking UI should read `row.isEncrypted` per row, not the file's
/// rules, or a cleared secret would read as exposed when it never really
/// held a value.
@MainActor
@Observable
public final class SecretDocumentViewModel {

    public private(set) var rows: [SecretRow] = []
    public private(set) var loadState: LoadState = .idle
    public private(set) var isDirty = false

    /// Bumped every time a row id may have come to name a **different value**
    /// than it did before.
    ///
    /// `SecretRow.id` is derived purely from the row's path
    /// (`SopsDocument.swift`), which is what makes it stable across reloads of
    /// the same document — and also what makes it *unstable* across anything
    /// that renumbers a list: remove `ports[0]` and the id `ports.1` stops
    /// meaning the value it meant a moment ago and starts meaning the one
    /// after it. Anything holding a row id across such a change is holding a
    /// pointer that has been silently re-aimed.
    ///
    /// A view cannot work this out from `rows` alone. "The id list is
    /// unchanged" is not enough — one save can remove a list element and
    /// append another, leaving the same ids over shifted values. So the type
    /// that *does* know says so, once, with a counter: state keyed by row id
    /// (which row is revealed, which row is selected) is valid only for the
    /// generation it was recorded under and is void for any other. See
    /// `RevealedRows`/`RowSelection` in `SecretEditorView.swift`, which is why
    /// this is not a private detail.
    ///
    /// Deliberately **not** bumped by `update(rowID:to:)`: typing a new value
    /// into a row cannot move any path, and masking a field the moment the
    /// user types into it would make a revealed row unusable.
    public private(set) var rowIdentityGeneration = 0

    /// Whether a `save()` is in flight.
    ///
    /// Exposed because the editor must disable its editing affordances while
    /// it is true, and because the view having its own copy of this is how
    /// the two can disagree. See `save()`.
    public private(set) var isSaving = false

    /// Everyone waiting on `awaitSaveInFlight()`, resumed together when the
    /// save in flight finishes. Not `@ObservationIgnored`-worthy bookkeeping
    /// that anyone reads — it exists only so a caller can *wait* rather than
    /// poll `isSaving`, which is what a "did the save finish yet" loop in a
    /// view would otherwise have to do.
    private var saveCompletionWaiters: [CheckedContinuation<Void, Never>] = []

    private let fileURL: URL
    private let keyStore: SessionKeyStore
    private let readFile: (URL) throws -> String
    private let fingerprintFile: (URL) -> FileFingerprint?
    private let writeFile: (String, URL, FileFingerprint?) throws -> FileFingerprint?

    /// The file's own encrypted bytes, as last read from disk (by `load()`)
    /// or produced by the most recent successful `save()`. `nil` until a
    /// load has succeeded at least once — `save()` refuses without it.
    private var encryptedContents: String?

    /// What the file looked like when `encryptedContents` was taken from it,
    /// so a save can tell whether anything else has written it since.
    ///
    /// This is the *expectation* half of the second-writer check, and it lives
    /// here rather than in `AtomicFileWriter` because this is the only object
    /// that knows what was read. The *verification* half lives in the writer,
    /// immediately before the replace, because that is the latest possible
    /// moment and the writer is what is standing there — see
    /// `AtomicFileWriter`'s "A second writer" section. Splitting it that way
    /// is the only arrangement in which the comparison is both against the
    /// right baseline and as late as it can be; doing it all here would leave
    /// a whole re-encryption (120–380 ms) between the check and the write.
    ///
    /// Refreshed after a successful save from the fingerprint the *writer*
    /// reported, never by re-`stat`ing the file afterwards — see
    /// `AtomicWriteReceipt.fingerprint`.
    private var loadedFingerprint: FileFingerprint?

    /// The document exactly as the bridge last reported it — the last
    /// successful load, or the reload that follows a structural save. Every
    /// pending change below is expressed against *this*, and `rows` is
    /// recomposed from it.
    private var baselineRows: [SecretRow] = []

    /// Edited values, keyed by the baseline row's `SecretRow.id` (stable
    /// across reloads of the same document — Task 7 derives it from position,
    /// not content). An entry is removed when the value is typed back to what
    /// it was, so "no entries" really means "nothing edited".
    private var editedValues: [String: String] = [:]

    /// Baseline rows the user removed. A `Set` for lookup; the removals a
    /// save sends are emitted in baseline order so a batch is reproducible.
    private var removedRowIDs: Set<String> = []

    /// Rows added in this session, in the order they were added.
    private var pendingAdditions: [PendingAddition] = []

    /// Composed row id → index into `pendingAdditions`. Rebuilt with `rows`,
    /// because a pending row's id is derived from its path and a list
    /// entry's path depends on what else is in the list.
    private var pendingAdditionIndexByRowID: [String: Int] = [:]

    /// One row the user added but has not saved.
    private struct PendingAddition {
        let document: Int
        /// The map or list it goes into; empty means the document root.
        let parent: [String]
        /// The new map key's name, or `""` when `parent` is a list, where the
        /// position comes from appending rather than from a name.
        let key: String
        let kind: SecretRow.Kind
        var value: String

        var isListEntry: Bool { key.isEmpty }
    }

    /// - Parameters:
    ///   - fileURL: The encrypted SOPS document on disk.
    ///   - keyStore: Where the session's decryption identity comes from.
    ///     Never copied out of `SessionKeyStore`'s own lending API — see
    ///     `load()`/`save()`.
    ///   - readFile: How the encrypted bytes are read. Defaults to a plain
    ///     synchronous file read. Overridable so tests can force a read
    ///     failure without needing filesystem permission tricks, and so a
    ///     later task can swap in whatever `AtomicFileWriter`'s companion
    ///     read path turns out to be without changing this type's logic.
    ///   - writeFile: How the re-encrypted bytes are persisted. Defaults to
    ///     `AtomicFileWriter.write(_:to:)`: stage in a temp file *beside* the
    ///     target, `F_FULLFSYNC`, preserve the original's mode, then
    ///     `replaceItemAt`. See that type's doc comment for exactly what it
    ///     guarantees and what it does not.
    ///
    ///     It replaced a plain `String.write(to:atomically:encoding:)`, which
    ///     was atomic in the "no reader sees a partial file" sense but wrong
    ///     in two others, both established empirically: it **destroys a
    ///     symlink**, leaving a regular file where the link was while the real
    ///     target keeps the stale secrets, and it never `fsync`s, so a crash
    ///     shortly after a save could lose a write the app had already
    ///     reported as succeeded.
    ///
    ///     Still overridable so tests can force a write failure without
    ///     filesystem permission tricks. Takes the fingerprint the load
    ///     captured and returns the one the write produced; see
    ///     `loadedFingerprint`.
    ///   - fingerprintFile: How the file's identity is captured, so `save()`
    ///     can refuse to overwrite a file something else has written since.
    ///     Defaults to `FileFingerprint.of`. Injectable for the same reason
    ///     `readFile` is — a test with an in-memory reader has no real file to
    ///     `stat` — and a `nil` answer means "no expectation", which skips the
    ///     check rather than failing the save.
    public init(
        fileURL: URL,
        keyStore: SessionKeyStore,
        readFile: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) },
        fingerprintFile: @escaping (URL) -> FileFingerprint? = { FileFingerprint.of($0) },
        writeFile: @escaping (String, URL, FileFingerprint?) throws -> FileFingerprint? = {
            contents, url, expecting in
            try AtomicFileWriter.write(contents, to: url, expecting: expecting).fingerprint
        }
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.readFile = readFile
        self.fingerprintFile = fingerprintFile
        self.writeFile = writeFile
    }

    /// Reads and decrypts the document, replacing `rows`.
    ///
    /// Reaches `.needsKey` — without attempting a decrypt at all — when the
    /// session has no identity configured, and `.failed` — with `rows` left
    /// empty — on any decrypt failure. It never reaches `.loaded` with an
    /// empty `rows` array to mean "could not read this file": that state
    /// would be indistinguishable, in the editor, from a genuinely empty
    /// document, and saving over it would write nothing over the user's real
    /// content.
    public func load() async {
        loadState = .loading

        // Fingerprint *before* the read, deliberately, and this is the one
        // ordering that is safe. Taken first, a write that lands between the
        // two leaves this holding the older fingerprint against the newer
        // contents, so the next save refuses — a false refusal the user clears
        // by reloading. Taken after the read, the same interleaving would
        // leave this holding the *writer's* fingerprint against the contents
        // from before it, and the next save would sail past the check and
        // delete their work. One ordering is wrong in a recoverable direction
        // and the other is wrong in the direction this whole check exists to
        // prevent.
        let fingerprint = fingerprintFile(fileURL)

        let contents: String
        do {
            contents = try readFile(fileURL)
        } catch {
            resetToEmpty()
            // The path/filename is not a secret (CLAUDE.md); the underlying
            // read error (permissions, missing file) never carries document
            // content, so nothing more needs to be withheld here.
            loadState = .failed("this file could not be read: \(fileURL.lastPathComponent)")
            return
        }

        // A load that produced no fingerprint over a file that *is* there did
        // not read what it thinks it read. `FileFingerprint.of` answers `nil`
        // for anything that is not a regular file — a dangling symlink
        // included — and the fingerprint and the read are two separate
        // syscalls, so a symlink flipped between them yields a successful load
        // with no fingerprint. The save then resolves the link and overwrites
        // whatever it points at *now*, reporting success: reproduced
        // overwriting a file outside the repository with SOPS ciphertext while
        // the real document went unchanged, at 20–28% of loads under a flipping
        // symlink.
        //
        // Refused here rather than in `AtomicFileWriter`: `expecting: nil` is a
        // legitimate contract there — writing through a symlink and creating a
        // file that was never there both rely on it, and both are covered by
        // tests that encode them as intended. Tightening the writer reddened
        // eight of them. What is not legitimate is *this* type reaching a save
        // with no fingerprint for a file it just read.
        if fingerprintFile(fileURL) == nil, FileManager.default.fileExists(atPath: fileURL.path) {
            resetToEmpty()
            loadState = .failed(
                "this file changed while it was being opened, so this app cannot tell what it read: "
                + fileURL.lastPathComponent)
            return
        }

        // A raw NUL is valid UTF-8, so it survives the read and then ends the
        // argument early at the C boundary — everything after it is silently
        // gone. Two complete SOPS documents joined by one NUL byte opened
        // showing only the first, and the next save wrote back what was shown,
        // deleting the second document's secrets permanently. The real `sops`
        // CLI refuses the same file. Refusing is the honest answer until the
        // boundary is length-prefixed; showing half a file is not.
        guard contents.crossesCBoundaryIntact else {
            resetToEmpty()
            loadState = .failed(
                "this file contains a NUL byte, which this app cannot read without silently "
                + "dropping everything after it: " + fileURL.lastPathComponent)
            return
        }

        // `body` receives the key and immediately hops off this actor itself
        // (`Self.decrypt`, below) — the key is never copied out into a local
        // variable here. See `SessionKeyStore.withKey(_:)`'s async overload.
        let decrypted: Outcome<[SecretRow]>? = await keyStore.withKey { key in
            await Self.decrypt(contents, agePrivateKey: key)
        }

        guard let decrypted else {
            // No key configured — `withKey` never called the closure, so no
            // bridge call and no risk of a stale rows/dirty state lingering.
            resetToEmpty()
            loadState = .needsKey
            return
        }

        switch decrypted {
        case .success(let newRows):
            encryptedContents = contents
            loadedFingerprint = fingerprint
            adoptBaseline(newRows)
            loadState = .loaded
        case .failure(let message):
            resetToEmpty()
            loadState = .failed(message)
        }
    }

    /// Clears everything a previous successful load left behind: `rows`,
    /// `baselineValues`, `isDirty`, and — the part that matters even though
    /// nothing can reach it today — `encryptedContents`.
    ///
    /// Without clearing `encryptedContents`, a failed *reload* after an
    /// earlier successful load would leave this type holding the previous
    /// load's ciphertext while `rows` reports empty. Nothing can set
    /// `isDirty` against an empty `rows` array today, and `save()` now gates
    /// on `loadState == .loaded` before it even looks at `encryptedContents`
    /// (see `save()`), so this is not reachable as of this change. It is one
    /// line against the exact property this type exists to hold, so it is
    /// closed rather than left to depend on `save()`'s guard ordering never
    /// changing.
    private func resetToEmpty() {
        baselineRows = []
        discardPendingChanges()
        invalidateRowIdentity()
        rows = []
        encryptedContents = nil
        // Cleared alongside the ciphertext it describes. A fingerprint left
        // behind here would be an expectation about a file this type is no
        // longer holding the contents of.
        loadedFingerprint = nil
    }

    /// Takes `newRows` as the new truth and drops every pending change.
    private func adoptBaseline(_ newRows: [SecretRow]) {
        baselineRows = newRows
        discardPendingChanges()
        invalidateRowIdentity()
        recompose()
    }

    /// See `rowIdentityGeneration`. Called from every place a row id can come
    /// to name a different value — a new baseline, a reset, an addition, a
    /// removal — and from nowhere else. `&+=` because the only thing anyone
    /// may do with this number is compare two of them for equality; wrapping
    /// after 2⁶³ edits is not a correctness question, but trapping would be.
    private func invalidateRowIdentity() {
        rowIdentityGeneration &+= 1
    }

    private func discardPendingChanges() {
        editedValues = [:]
        removedRowIDs = []
        pendingAdditions = []
        pendingAdditionIndexByRowID = [:]
        isDirty = false
    }

    /// Runs `SopsBridge.decryptToRows` off the main actor, via
    /// `runOffCooperativePool` (below).
    ///
    /// A whole-document decrypt scales with key count — measured ~73ms for a
    /// 3,000-key/447KB fixture and ~256ms for an 8,000-key/1.19MB fixture,
    /// both realistic sizes for a real service's secrets file — long enough
    /// to read as a stall if run inline on `@MainActor`, which is where
    /// `load()` otherwise runs.
    ///
    /// `key` is a parameter, not something this function reaches into the
    /// key store for — it is handed in by `SessionKeyStore.withKey(_:)`'s
    /// async overload, which is the only place a caller ever sees the key at
    /// all. It lives in this function's own local scope for the duration of
    /// one call and is never stored in a property, logged, or retained past
    /// this function returning.
    private static func decrypt(_ contents: String, agePrivateKey key: String) async -> Outcome<[SecretRow]> {
        await runOffCooperativePool {
            do {
                return .success(try SopsBridge.decryptToRows(contents, agePrivateKey: key))
            } catch let error as SopsBridgeError {
                return .failure(error.description)
            } catch {
                return .failure("this file could not be decrypted")
            }
        }
    }

    /// Runs a synchronous, blocking `body` on a dedicated OS thread instead
    /// of Swift's cooperative thread pool, and bridges the result back into
    /// `async`.
    ///
    /// **Not** `Task.detached` — the first version of this used it, and
    /// measured *worse* than useless: on a 3,000-key/447KB fixture, `load()`
    /// went from ~73ms (called inline on `@MainActor`) to over ten
    /// *seconds*. `Task.detached` still schedules its closure onto Swift's
    /// cooperative global executor, which is deliberately sized to the
    /// core count on the assumption that everything running on it yields at
    /// `await` points. The cgo call into the Go engine does not yield — it
    /// blocks its thread synchronously for the whole decrypt/encrypt — so
    /// under any concurrent load on that pool (this app's own health checks,
    /// or, as measured, `swift test`'s own parallel test execution) it
    /// starves out the pool for everything else sharing it, including,
    /// self-defeatingly, the very call this function exists to speed up.
    ///
    /// `SopsHealth/ProjectScanner.swift`'s `runOffCooperativePool` already
    /// diagnosed and solved the identical problem for the project directory
    /// walk (Task 1b), including the sharper follow-up that
    /// `DispatchQueue.global().async` — a shared elastic pool — does not
    /// solve it either, because a caller can still queue behind other
    /// long-held submissions on that shared pool. This is the same fix,
    /// duplicated here rather than reused across modules: a genuinely new
    /// `Thread`, started immediately, with nothing to queue behind. Called a
    /// small, fixed number of times per `load()`/`save()` (once each), which
    /// is exactly the usage profile `ProjectScanner`'s doc comment names as
    /// the reason a whole new OS thread per call is the right tradeoff
    /// rather than something that "would not scale."
    private static func runOffCooperativePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: body())
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// Changes one row's value in memory.
    ///
    /// A no-op for a row id that is not present, or whose kind is not
    /// editable (`SecretRow.Kind.isEditable` — an empty map or list has no
    /// value of its own to type into).
    public func update(rowID: String, to newValue: String) {
        // See `save()`: a change made while a save is in flight has no
        // baseline it can be expressed against once that save lands.
        guard !isSaving else { return }
        guard let row = rows.first(where: { $0.id == rowID }), row.kind.isEditable else { return }

        if let index = pendingAdditionIndexByRowID[rowID] {
            pendingAdditions[index].value = newValue
        } else if let baseline = baselineRows.first(where: { $0.id == rowID }) {
            // Typed back to what it was is not an edit. Without this, saving
            // would send a set for a value that did not change, rewriting a
            // line of the user's file for nothing.
            if baseline.value == newValue {
                editedValues.removeValue(forKey: rowID)
            } else {
                editedValues[rowID] = newValue
            }
        } else {
            return
        }
        recompose()
    }

    // MARK: - Adding and removing rows

    /// Why an `addRow` call was refused. The bridge is the authority on all
    /// of these — it re-checks every one against the real document — but
    /// answering here lets the UI say so before the user commits to a save.
    public enum AddRowRefusal: Equatable, Sendable {
        /// No document is open, so there is nothing to add to.
        case notLoaded
        /// A new key in a map needs a name.
        case emptyKey
        /// A key by that name is already in this map. Changing its value is
        /// an edit, not an addition — silently turning one into the other
        /// would overwrite a value nobody chose.
        case duplicateKey
        /// The kind has no value to type into (`emptyMap`/`emptyList`).
        case unsupportedKind
        /// The name is one a new key may not have. `<<` is YAML's merge key
        /// and a document that uses it for an ordinary value cannot be read
        /// back at all — by this app or by the sops CLI — so a two-character
        /// typo would cost the user every other secret in the file. `sops` at
        /// the top level is where SOPS keeps its own metadata. The bridge
        /// refuses both; this mirrors it so the sheet can say so before the
        /// user commits.
        case reservedKey
        /// A save is in flight. See `save()`.
        case saveInProgress
    }

    /// Names a new key may not have, mirroring `refuseReservedKey` in
    /// `Engine/gobridge/documentchanges.go`. The bridge is the authority —
    /// this is here so the sheet can refuse before the user presses Add, not
    /// instead of the bridge's check.
    private static let yamlMergeKey = "<<"
    private static let sopsMetadataKey = "sops"

    public enum AddRowOutcome: Equatable, Sendable {
        /// The id of the new row, as it now appears in `rows`.
        case added(String)
        case refused(AddRowRefusal)
    }

    /// Where an `addRow` would put a new row, given what is selected.
    ///
    /// This lives here rather than in the view because it is a fact about the
    /// document, and because getting it wrong is a correctness problem, not a
    /// presentation one: a map needs a key name and a list is appended, and
    /// the two cannot be told apart from a path — `"0"` is a legitimate map
    /// key. `SecretRow.isInList` carries the bridge's own answer.
    public struct AddDestination: Equatable, Sendable {
        public let document: Int
        /// The container to add into; empty means the document's root map.
        public let parent: [String]
        /// Whether that container is a list, in which case the new entry is
        /// appended and has no name.
        public let isList: Bool

        public init(document: Int, parent: [String], isList: Bool) {
            self.document = document
            self.parent = parent
            self.isList = isList
        }
    }

    /// The destination for a `+` pressed while `selectedRowID` is selected.
    ///
    /// - A selected empty map or list is added *into*, so `foo: {}` is not a
    ///   dead end nothing can ever be put in.
    /// - Any other selected row means "another one of these", i.e. its own
    ///   container.
    /// - Nothing selected means the document's root map.
    public func addDestination(forSelectedRowID selectedRowID: String?) -> AddDestination {
        guard let selectedRowID, let row = rows.first(where: { $0.id == selectedRowID }) else {
            return AddDestination(document: 0, parent: [], isList: false)
        }
        switch row.kind {
        case .emptyMap:
            return AddDestination(document: row.document, parent: row.path, isList: false)
        case .emptyList:
            return AddDestination(document: row.document, parent: row.path, isList: true)
        default:
            return AddDestination(
                document: row.document, parent: Array(row.path.dropLast()), isList: row.isInList)
        }
    }

    /// Adds a row to the document in memory. Nothing reaches disk until
    /// `save()`.
    ///
    /// `key` names the new map key and must be empty when
    /// `destination.isList` — a list entry is appended, and there is no way
    /// to ask for a position, deliberately: an insertion renumbers every
    /// later element exactly as a removal does. See `SecretChangeSet`.
    @discardableResult
    public func addRow(
        in destination: AddDestination, key: String, kind: SecretRow.Kind, value: String
    ) -> AddRowOutcome {
        guard loadState == .loaded else { return .refused(.notLoaded) }
        guard kind.isEditable else { return .refused(.unsupportedKind) }
        if let refusal = refusalForAdding(key, in: destination) { return .refused(refusal) }

        // Trimmed here rather than trusted from the caller: a key that is
        // only spaces is not a name, and YAML would happily accept it as one.
        let name = destination.isList ? "" : key.trimmingCharacters(in: .whitespacesAndNewlines)

        pendingAdditions.append(
            PendingAddition(
                document: destination.document, parent: destination.parent,
                key: name, kind: kind, value: value))
        invalidateRowIdentity()
        recompose()

        guard let id = pendingAdditionIndexByRowID.first(where: { $0.value == pendingAdditions.count - 1 })?.key
        else {
            // Unreachable: recompose always produces a row per pending
            // addition. Undo rather than report an id that does not exist.
            pendingAdditions.removeLast()
            invalidateRowIdentity()
            recompose()
            return .refused(.notLoaded)
        }
        return .added(id)
    }

    /// Why adding `key` at `destination` would be refused, or `nil` if it
    /// would be accepted. Used both by `addRow` and by the `+` sheet, so the
    /// two cannot answer differently.
    ///
    /// The duplicate check reads `rows`, which **excludes rows the user has
    /// already removed**. That is deliberate and it is what makes "remove
    /// this key, then add it back with a different type" work: the bridge
    /// applies removals before additions and accepts exactly that pair
    /// (`documentchanges.go`, `planChanges`). Reading the baseline here
    /// instead would refuse on screen something the bridge is happy to do,
    /// or — worse, and what an earlier version of this did — accept it on
    /// screen and have the save refuse it with a message contradicting what
    /// the user is looking at.
    public func refusalForAdding(_ key: String, in destination: AddDestination) -> AddRowRefusal? {
        if isSaving { return .saveInProgress }
        if loadState != .loaded { return .notLoaded }
        if destination.isList { return nil }

        let name = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .emptyKey }
        if name == Self.yamlMergeKey { return .reservedKey }
        if name == Self.sopsMetadataKey && destination.parent.isEmpty { return .reservedKey }

        let candidate = destination.parent + [name]
        let taken = rows.contains { row in
            row.document == destination.document
                && row.path.count >= candidate.count
                && Array(row.path.prefix(candidate.count)) == candidate
        }
        return taken ? .duplicateKey : nil
    }

    /// Removes a row from the document in memory. Nothing reaches disk until
    /// `save()`.
    ///
    /// Removing a row that was added in this session simply undoes the
    /// addition — there is nothing in the file to remove — and leaves the
    /// document exactly as clean as it was before the addition.
    ///
    /// A no-op for an id that is not in `rows`.
    public func removeRow(id: String) {
        // See `save()`.
        guard !isSaving else { return }
        if let index = pendingAdditionIndexByRowID[id] {
            pendingAdditions.remove(at: index)
        } else if baselineRows.contains(where: { $0.id == id }), !removedRowIDs.contains(id) {
            removedRowIDs.insert(id)
            editedValues.removeValue(forKey: id)
        } else {
            return
        }
        invalidateRowIdentity()
        recompose()
    }

    /// Rebuilds `rows` from the baseline plus the pending changes, and with
    /// it the dirty flag and the pending-row index.
    private func recompose() {
        var composed: [SecretRow] = []
        for baseline in baselineRows where !removedRowIDs.contains(baseline.id) {
            var row = baseline
            if let edited = editedValues[baseline.id] { row.value = edited }
            composed.append(row)
        }

        var indexByRowID: [String: Int] = [:]
        for (index, addition) in pendingAdditions.enumerated() {
            let row = SecretRow(
                document: addition.document,
                path: pendingPath(for: addition, in: composed),
                value: addition.value,
                kind: addition.kind,
                isInList: addition.isListEntry,
                isPendingAdd: true,
                // Honest: it is not ciphertext in the file, because it is not
                // in the file. Whether it will be is the file's own rules'
                // decision at save time, which is why the editor shows this
                // row as new rather than as unprotected.
                isEncrypted: false)
            composed.insert(row, at: insertionIndex(for: addition, in: composed))
            indexByRowID[row.id] = index
        }

        // A container that has something in it is no longer an empty
        // container, so its `{}` / `[]` row goes — which is what a reload
        // would show, and what keeps the same key from appearing twice.
        let snapshot = composed
        composed = composed.filter { row in
            guard row.kind == .emptyMap || row.kind == .emptyList else { return true }
            return !snapshot.contains { other in
                other.document == row.document
                    && other.path.count > row.path.count
                    && Array(other.path.prefix(row.path.count)) == row.path
            }
        }

        rows = composed
        pendingAdditionIndexByRowID = indexByRowID
        isDirty = !editedValues.isEmpty || !removedRowIDs.isEmpty || !pendingAdditions.isEmpty
    }

    /// The path a pending row shows up under. For a map that is the key; for
    /// a list it is the next free index, which is what the bridge's append
    /// will produce.
    private func pendingPath(for addition: PendingAddition, in composed: [SecretRow]) -> [String] {
        guard addition.isListEntry else { return addition.parent + [addition.key] }
        var next = 0
        for row in composed where row.document == addition.document {
            guard row.path.count > addition.parent.count,
                Array(row.path.prefix(addition.parent.count)) == addition.parent,
                let index = Int(row.path[addition.parent.count])
            else { continue }
            next = max(next, index + 1)
        }
        return addition.parent + [String(next)]
    }

    /// Where the new row goes in the displayed order: after the last row
    /// already inside its container, or — for a container that has no rows of
    /// its own yet — directly after that container's own row.
    private func insertionIndex(for addition: PendingAddition, in composed: [SecretRow]) -> Int {
        var last: Int?
        for (index, row) in composed.enumerated() where row.document == addition.document {
            if row.path.count > addition.parent.count,
                Array(row.path.prefix(addition.parent.count)) == addition.parent {
                last = index
            }
        }
        if let last { return last + 1 }
        if let container = composed.firstIndex(where: {
            $0.document == addition.document && $0.path == addition.parent
        }) {
            return container + 1
        }
        return composed.count
    }

    /// Writes the current rows back to `fileURL`.
    ///
    /// ## Nothing loaded is a failure, never `.saved`
    /// `.saved` means "your edits are safely on disk." Reporting it for a
    /// document this type never opened — a fresh instance, or one that
    /// reached `.needsKey` or `.failed` — would tell a caller (a future
    /// "save all open documents" flow, say) that a file was written when
    /// nothing was. This is checked *before* the `isDirty` no-op check
    /// below, precisely because a never-loaded document also has
    /// `isDirty == false`, and the earlier ordering let that case fall into
    /// `.saved` by accident.
    ///
    /// ## No-op when nothing changed
    /// Past that gate, if `isDirty` is false — including when every edited
    /// value was set back to its original — `save()` does nothing: no
    /// bridge call, no write, `encryptedContents` untouched. The
    /// alternative (always calling `applyEdits`, even with zero edits) is a
    /// real choice too — Task 7 proved it is a "clean rewrite" that only
    /// ever touches `lastmodified` and `mac` — but it would mean every
    /// no-op Cmd-S rewrites the file's MAC for no reason: needless git-diff
    /// noise on a file nothing actually changed in. This type chooses the
    /// no-op, and `SecretDocumentViewModelTests` pins it.
    ///
    /// ## A save is not interruptible
    /// `isSaving` is set for the whole of this method, and `update`,
    /// `addRow` and `removeRow` refuse while it is. A save snapshots the
    /// pending changes and then spends 120–380 ms encrypting; anything the
    /// user did in that window used to be adopted as though it had been
    /// saved, so it vanished from the file while the editor showed it as
    /// clean.
    ///
    /// The alternative — rebasing what is left onto the snapshot instead of
    /// refusing — was rejected, and the reason is worth stating. It is sound
    /// only for a value-only save. A save that changed the document's shape
    /// renumbers list paths, so a mid-save pending change, expressed against
    /// the *old* baseline, may afterwards point at a different element than
    /// the user meant. A fix that is right for one branch and quietly wrong
    /// for the other is the plausible-instead-of-certain pattern this
    /// project keeps paying for. Refusing is certain, and it closes the same
    /// hole in `update` that predates this method.
    ///
    /// The editor disables the affordances too, so in practice nothing
    /// reaches these guards; they are what makes that a property of the type
    /// rather than of one view remembering to.
    ///
    /// ## A file something else has written since is refused, never merged
    /// and never clobbered
    /// The re-encryption starts from `encryptedContents` — the bytes read at
    /// `load()` — so a save is, by construction, "the file as I last saw it,
    /// plus my edits". If something else has written the file in between, that
    /// is a different file, and writing over it deletes whatever they did:
    /// verified before this check existed, with the real `sops set` as the
    /// other writer, the save reported `.saved` and the other writer's key was
    /// gone.
    ///
    /// So `loadedFingerprint` goes to the writer as `expecting:`, and a
    /// mismatch comes back as `AtomicFileWriter.Error.destinationChangedOnDisk`
    /// — surfaced verbatim, like the writer's other errors, because it names
    /// the file and says to reload it. Nothing is merged: reconciling two
    /// versions of a secrets file is not something this app can do correctly,
    /// and doing it silently would be worse than either alternative. The
    /// user's edits stay in `rows`, `isDirty` stays set, and a `load()` clears
    /// the refusal (`SecretDocumentViewModelTests` drives exactly that
    /// sequence).
    ///
    /// ## Failure leaves everything as the user left it
    /// A failure — no document loaded, no key configured, a bridge refusal,
    /// a write error — never touches `rows`, `baselineValues` or
    /// `encryptedContents`, and `isDirty` stays exactly as it was. The
    /// caller must not be able to read a failed save as "your edits are
    /// gone": they are still sitting in `rows`, unsaved, exactly where the
    /// user left them.
    public func save() async -> SaveOutcome {
        guard !isSaving else {
            return .failed("a save of this document is already in progress")
        }
        guard loadState == .loaded else {
            return .failed("no document is loaded")
        }
        guard isDirty else { return .saved }
        guard let contents = encryptedContents else {
            // Not reachable given the `loadState == .loaded` guard above —
            // the two are always set together — but this is the guard that
            // makes that an invariant rather than an assumption.
            return .failed("no document is loaded")
        }

        let changes = pendingChangeSet()

        // From here until this function returns, `update`, `addRow` and
        // `removeRow` all refuse. See the "A save is not interruptible"
        // section of this method's doc comment.
        isSaving = true
        defer {
            isSaving = false
            // Taken and cleared before resuming, so a waiter that immediately
            // starts another save cannot find itself in a list this `defer` is
            // still walking.
            let waiters = saveCompletionWaiters
            saveCompletionWaiters = []
            for waiter in waiters { waiter.resume() }
        }

        // Same reasoning as `load()`: `body` receives the key and hops off
        // this actor itself; the key never lives in a local variable here.
        let applied: Outcome<String>? = await keyStore.withKey { key in
            await Self.applyChanges(contents, changes: changes, agePrivateKey: key)
        }

        guard let applied else {
            return .failed("no decryption key is configured")
        }

        switch applied {
        case .failure(let message):
            return .failed(message)
        case .success(let newEncrypted):
            let written: FileFingerprint?
            do {
                written = try writeFile(newEncrypted, fileURL, loadedFingerprint)
            } catch let error as AtomicFileWriter.Error {
                // Surfaced verbatim, and *only* for this one error type.
                // `AtomicFileWriter.Error`'s cases are built from a path and
                // an `errno` string and never see the document's bytes at
                // all, so it is safe to show — and it is materially more
                // useful than the generic line below: "…is not writable" and
                // "could not create a temporary file next to …" send the user
                // to two entirely different places. Any other error (an
                // injected one in tests, anything a future `writeFile` throws)
                // falls through to the generic message rather than being
                // interpolated on trust.
                return .failed("the saved file could not be written to disk: \(error.description)")
            } catch {
                return .failed("the saved file could not be written to disk: \(fileURL.lastPathComponent)")
            }
            encryptedContents = newEncrypted
            // The writer's own answer, not a fresh `stat` of the file. A
            // re-`stat` here would pick up a second writer that landed
            // immediately after this save and adopt *their* file as this
            // type's baseline, so the following save would overwrite it —
            // the same hole one write later. See
            // `AtomicWriteReceipt.fingerprint`.
            loadedFingerprint = written
            await adoptSavedDocument(newEncrypted)
            return .saved
        }
    }

    /// Returns once the save currently in flight has finished, or immediately
    /// if there is none.
    ///
    /// This exists for the workspace's "you are leaving a dirty document"
    /// prompt. That prompt used to be put to the user *during* a save, where
    /// both of its answers were wrong: "Save and continue" called `save()`,
    /// which refuses a re-entrant save, so the user was shown a save-failed
    /// alert while the save was in fact succeeding; and "Discard changes" tore
    /// the editor down while the `Task` running the save kept a strong
    /// reference to this object and went on to write the discarded changes to
    /// disk. The window is 133–380 ms, measured, and both outcomes were
    /// reproduced in it.
    ///
    /// Waiting is the answer rather than cancelling because the save is not
    /// cancellable and should not be: past the point where `applyChanges` has
    /// produced bytes, the only choices are to write them or to throw away a
    /// completed encryption, and a half-applied save is the one outcome this
    /// type refuses to have. So the switch is *deferred* by at most that
    /// window and then decided again against a settled document — see
    /// `WorkspaceSwitchDecision.waitForSaveInFlight`.
    public func awaitSaveInFlight() async {
        guard isSaving else { return }
        await withCheckedContinuation { continuation in
            saveCompletionWaiters.append(continuation)
        }
    }

    /// The pending changes as the bridge takes them. Removals are emitted in
    /// baseline order rather than in a `Set`'s arbitrary one, so the same
    /// user actions always produce the same batch.
    private func pendingChangeSet() -> SecretChangeSet {
        var sets: [SecretEdit] = []
        var removes: [SecretRemoval] = []
        for baseline in baselineRows {
            if removedRowIDs.contains(baseline.id) {
                removes.append(SecretRemoval(document: baseline.document, path: baseline.path))
            } else if let edited = editedValues[baseline.id] {
                sets.append(
                    SecretEdit(
                        document: baseline.document, path: baseline.path,
                        value: edited, kind: Self.editedKind(of: baseline, newValue: edited)))
            }
        }
        let adds = pendingAdditions.map {
            SecretAddition(
                document: $0.document, parent: $0.parent, key: $0.key,
                value: $0.value, kind: $0.kind)
        }
        return SecretChangeSet(sets: sets, adds: adds, removes: removes)
    }

    /// The type an edited row should be written back as.
    ///
    /// Everything keeps the type it had, except a `null` row the user has typed
    /// into. A null cannot carry a value: the bridge's `KindNull` used to
    /// return `nil` and discard the text, so a user could reveal a null row,
    /// type a real secret, watch "Unsaved changes" appear, press Save, see no
    /// error — and the secret never reached the file. Two edits in one save,
    /// one of them to a null row, came back reported as fully saved with one
    /// silently dropped.
    ///
    /// Typing text into a null field is an unambiguous request for a string;
    /// clearing it back to empty leaves it null, which is what the row already
    /// was. The bridge refuses a null edit carrying text outright, so this is
    /// the honest translation rather than the only thing standing between the
    /// user and the loss.
    static func editedKind(of baseline: SecretRow, newValue: String) -> SecretRow.Kind {
        guard baseline.kind == .null, !newValue.isEmpty else { return baseline.kind }
        return .string
    }

    /// Resyncs this type with the file it just wrote, by re-reading the bytes
    /// it just produced. Always — there is no fast path.
    ///
    /// There used to be one, for a save that changed no keys: such a save
    /// cannot move a path, so the rows already on screen were re-adopted
    /// directly, carrying each row's fields over from before the save. That
    /// reasoning was sound about paths and wrong about everything else a
    /// `SecretRow` carries. `isEncrypted` is the one that bit: sops does not
    /// encrypt an empty string, so `blank: ""` loads with `isEncrypted ==
    /// false`, and after the user typed a real value and saved it, the file on
    /// disk held `ENC[…]` while the row carried the old `false` — so the
    /// editor drew an open padlock, labelled `editorValueNotEncrypted`, over a
    /// value that *was* encrypted, until the next reload. The reverse (clearing
    /// an encrypted value) drew a closed padlock over plaintext on disk. A
    /// padlock is not decoration; it is the app's answer to "is this
    /// protected", and answering it from memory that predates the write is
    /// exactly the "screen disagrees with the file" failure this milestone is
    /// about.
    ///
    /// It could have been narrowed instead — only a value crossing
    /// empty↔non-empty can flip sops's answer for an unchanged path, so only
    /// those saves need the re-read. That is very probably true, and "very
    /// probably" is the standard `save()`'s own doc comment refuses ("a fix
    /// that is right for one branch and quietly wrong for the other is the
    /// plausible-instead-of-certain pattern this project keeps paying for").
    /// Reading it back is certain, it is the only source of truth for what the
    /// file now says, and it costs one decrypt of bytes already in memory —
    /// measured at ~73 ms for a 3,000-key document against the 120–380 ms the
    /// encrypt in front of it already spends, off the cooperative pool
    /// (`runOffCooperativePool`). Certainty is worth that here.
    ///
    /// If the re-read fails the *file is still saved* — the bytes are on
    /// disk. The document simply can no longer be shown, and saying so is
    /// more honest than leaving a stale editor open over it.
    private func adoptSavedDocument(_ newEncrypted: String) async {
        let reloaded: Outcome<[SecretRow]>? = await keyStore.withKey { key in
            await Self.decrypt(newEncrypted, agePrivateKey: key)
        }
        switch reloaded {
        case .success(let newRows)?:
            adoptBaseline(newRows)
        case .failure(let message)?:
            resetToEmpty()
            loadState = .failed(message)
        case nil:
            resetToEmpty()
            loadState = .needsKey
        }
    }

    /// Runs `SopsBridge.applyEdits` off the main actor via
    /// `runOffCooperativePool` — the encrypt-side twin of
    /// `decrypt(_:agePrivateKey:)` above, same reasoning and same measured
    /// `Task.detached` failure mode: ~120ms for a 3,000-key/447KB fixture and
    /// ~382ms for an 8,000-key/1.19MB fixture when run off the cooperative
    /// pool; over nine seconds when it wasn't. `key`'s lifetime is exactly
    /// this call.
    private static func applyChanges(
        _ contents: String, changes: SecretChangeSet, agePrivateKey key: String
    ) async -> Outcome<String> {
        await runOffCooperativePool {
            do {
                return .success(try SopsBridge.applyChanges(contents, changes: changes, agePrivateKey: key))
            } catch let error as SopsBridgeError {
                return .failure(error.description)
            } catch {
                return .failure("this file could not be saved")
            }
        }
    }
}
