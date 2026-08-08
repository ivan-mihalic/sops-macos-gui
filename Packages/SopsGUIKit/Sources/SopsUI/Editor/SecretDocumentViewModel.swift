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
/// The brief for this type asks for `addRow(path:)` and `removeRow(id:)`.
/// They are deliberately **not implemented here**. `SopsBridge.applyEdits`
/// only sets existing values — Task 7's report states the scope explicitly
/// ("Scope: set only") — there is no bridge call that adds or removes a key
/// from the tree. A view-model-only implementation could splice `rows` in
/// memory, but `save()` would then have no way to carry that change into the
/// file: the structural edit would look successful in the UI and silently
/// vanish on save, which is exactly the "presents as something it is not"
/// failure this milestone exists to close. Task 7's report names the
/// follow-up directly and flags a real hazard for whoever writes it:
/// removing a list element shifts every later element's index, which
/// invalidates the paths of any other pending edit in the same batch. That
/// belongs with the Go API extension, not against a call that does not
/// exist.
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

    private let fileURL: URL
    private let keyStore: SessionKeyStore
    private let readFile: (URL) throws -> String
    private let writeFile: (String, URL) throws -> Void

    /// The file's own encrypted bytes, as last read from disk (by `load()`)
    /// or produced by the most recent successful `save()`. `nil` until a
    /// load has succeeded at least once — `save()` refuses without it.
    private var encryptedContents: String?

    /// Each editable row's value as of the last successful load or save —
    /// the baseline `isDirty` and the edit set compare against. Keyed by
    /// `SecretRow.id`, which Task 7 documents as stable across reloads of the
    /// same document (derived from position, not content).
    private var baselineValues: [String: String] = [:]

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
            rows = newRows
            baselineValues = Dictionary(uniqueKeysWithValues: newRows.map { ($0.id, $0.value) })
            isDirty = false
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
        rows = []
        baselineValues = [:]
        isDirty = false
        encryptedContents = nil
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
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return }
        guard rows[index].kind.isEditable else { return }
        rows[index].value = newValue
        recomputeIsDirty()
    }

    private func recomputeIsDirty() {
        isDirty = rows.contains { baselineValues[$0.id] != $0.value }
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
    /// ## Failure leaves everything as the user left it
    /// A failure — no document loaded, no key configured, a bridge refusal,
    /// a write error — never touches `rows`, `baselineValues` or
    /// `encryptedContents`, and `isDirty` stays exactly as it was. The
    /// caller must not be able to read a failed save as "your edits are
    /// gone": they are still sitting in `rows`, unsaved, exactly where the
    /// user left them.
    public func save() async -> SaveOutcome {
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

        let edits = rows
            .filter { baselineValues[$0.id] != $0.value }
            .map { SecretEdit(row: $0) }

        // Same reasoning as `load()`: `body` receives the key and hops off
        // this actor itself; the key never lives in a local variable here.
        let applied: Outcome<String>? = await keyStore.withKey { key in
            await Self.applyEdits(contents, edits: edits, agePrivateKey: key)
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
            baselineValues = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.value) })
            isDirty = false
            return .saved
        }
    }

    /// Runs `SopsBridge.applyEdits` off the main actor via
    /// `runOffCooperativePool` — the encrypt-side twin of
    /// `decrypt(_:agePrivateKey:)` above, same reasoning and same measured
    /// `Task.detached` failure mode: ~120ms for a 3,000-key/447KB fixture and
    /// ~382ms for an 8,000-key/1.19MB fixture when run off the cooperative
    /// pool; over nine seconds when it wasn't. `key`'s lifetime is exactly
    /// this call.
    private static func applyEdits(
        _ contents: String, edits: [SecretEdit], agePrivateKey key: String
    ) async -> Outcome<String> {
        await runOffCooperativePool {
            do {
                return .success(try SopsBridge.applyEdits(contents, edits: edits, agePrivateKey: key))
            } catch let error as SopsBridgeError {
                return .failure(error.description)
            } catch {
                return .failure("this file could not be saved")
            }
        }
    }
}
