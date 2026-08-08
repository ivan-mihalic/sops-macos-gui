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
/// A save that changed the document's **shape** reloads from the bytes it
/// just produced instead of trusting the in-memory rows. It has to: removing
/// a list element renumbers everything after it, so the paths this type is
/// holding stop matching the file the moment such a save succeeds, and the
/// next edit would land on the wrong element. A value-only save keeps the
/// fast path, because nothing about it can move a path.
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

    /// Whether a `save()` is in flight.
    ///
    /// Exposed because the editor must disable its editing affordances while
    /// it is true, and because the view having its own copy of this is how
    /// the two can disagree. See `save()`.
    public private(set) var isSaving = false

    private let fileURL: URL
    private let keyStore: SessionKeyStore
    private let readFile: (URL) throws -> String
    private let writeFile: (String, URL) throws -> Void

    /// The file's own encrypted bytes, as last read from disk (by `load()`)
    /// or produced by the most recent successful `save()`. `nil` until a
    /// load has succeeded at least once — `save()` refuses without it.
    private var encryptedContents: String?

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
    ///     a plain `String.write(to:atomically:encoding:)`. Atomic
    ///     replacement (encrypt to a temp file beside the target, `fsync`,
    ///     `replaceItemAt`) is Task 10's `AtomicFileWriter` — this
    ///     injection point is what lets that land without this type
    ///     changing.
    public init(
        fileURL: URL,
        keyStore: SessionKeyStore,
        readFile: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) },
        writeFile: @escaping (String, URL) throws -> Void = { contents, url in
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
        self.readFile = readFile
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
        rows = []
        encryptedContents = nil
    }

    /// Takes `newRows` as the new truth and drops every pending change.
    private func adoptBaseline(_ newRows: [SecretRow]) {
        baselineRows = newRows
        discardPendingChanges()
        recompose()
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
        recompose()

        guard let id = pendingAdditionIndexByRowID.first(where: { $0.value == pendingAdditions.count - 1 })?.key
        else {
            // Unreachable: recompose always produces a row per pending
            // addition. Undo rather than report an id that does not exist.
            pendingAdditions.removeLast()
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
        defer { isSaving = false }

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
            do {
                try writeFile(newEncrypted, fileURL)
            } catch {
                return .failed("the saved file could not be written to disk: \(fileURL.lastPathComponent)")
            }
            encryptedContents = newEncrypted
            await adoptSavedDocument(newEncrypted, changedShape: !changes.adds.isEmpty || !changes.removes.isEmpty)
            return .saved
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
                        value: edited, kind: baseline.kind))
            }
        }
        let adds = pendingAdditions.map {
            SecretAddition(
                document: $0.document, parent: $0.parent, key: $0.key,
                value: $0.value, kind: $0.kind)
        }
        return SecretChangeSet(sets: sets, adds: adds, removes: removes)
    }

    /// Resyncs this type with the file it just wrote.
    ///
    /// A value-only save cannot move a path, so the rows already on screen
    /// are still correct and become the new baseline directly. A save that
    /// added or removed something can move paths — removing a list element
    /// renumbers every element after it — so the in-memory paths stop
    /// matching the file and the next edit would land on the wrong element.
    /// That case re-reads the bytes it just produced, which is the only
    /// source of truth for where things ended up.
    ///
    /// If that re-read fails the *file is still saved* — the bytes are on
    /// disk. The document simply can no longer be shown, and saying so is
    /// more honest than leaving a stale editor open over it.
    private func adoptSavedDocument(_ newEncrypted: String, changedShape: Bool) async {
        guard changedShape else {
            adoptBaseline(rows.map {
                SecretRow(
                    document: $0.document, path: $0.path, value: $0.value, kind: $0.kind,
                    isInList: $0.isInList, isPendingAdd: false, isEncrypted: $0.isEncrypted)
            })
            return
        }

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
