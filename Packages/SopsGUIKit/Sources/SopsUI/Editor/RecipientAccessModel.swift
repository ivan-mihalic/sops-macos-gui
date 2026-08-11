import Foundation
import Observation
import SopsEngine
import SopsProjects

/// Which age recipients can decrypt the file this model was built for, and
/// the in-memory add/remove changes the user has staged but not yet applied.
///
/// ## Reading needs no key; applying does
/// `SopsBridge.recipients(in:)` reads native age recipient metadata straight
/// off the document — no private identity required — so `load()` never
/// touches `SessionKeyStore`. `apply()` re-wraps the data key, which does
/// need one; see `apply()`'s doc comment for what happens without it.
///
/// ## Staged edits are purely in-memory
/// `stageAdd`/`stageRemove`/`discardStagedChanges` only ever touch
/// `stagedRecipients`, an `@Observable` property on this object. Nothing
/// about them reaches the filesystem or calls into the bridge — the file on
/// disk, and what a fresh `load()` of it reports, stay exactly what they
/// were until `apply()` is called and succeeds. `RecipientAccessTests`
/// pins this directly: it reads the raw bytes of the file back off disk
/// after staging and asserts they are byte-identical to what was there
/// before.
///
/// ## The registry is a label directory, never an access authority
/// `registryRecords` (from `RecipientRegistry`, when `projectURL` is given)
/// only supplies a human label for an age public key this document's own
/// metadata already names. A recipient present in the file but missing from
/// the registry is never hidden — `entries` falls back to showing its raw
/// `age1…` public key, which is what makes it identifiable without a label
/// at all. See `AccessEntry`.
@MainActor
@Observable
public final class RecipientAccessModel {

    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        /// The associated text is `SopsBridgeError.description` verbatim, or
        /// a fixed message for a read/boundary failure this type detects
        /// itself — see `SecretDocumentViewModel.LoadState.failed` for the
        /// same guarantee: never a document value.
        case failed(String)
    }

    /// Why a `stageAdd` was refused. The bridge is the authority on whether a
    /// recipient string is actually a valid, non-private, native age
    /// recipient — that is only re-checked at `apply()`, against the real
    /// document. This only catches what can be known before that: nothing
    /// typed, or the exact same string already staged.
    public enum StageAddRefusal: Equatable, Sendable {
        case notLoaded
        case empty
        case duplicate
    }

    public enum ApplyOutcome: Equatable, Sendable {
        case applied
        /// Staged down to zero recipients. Refused before the bridge or the
        /// file is ever touched — a file with no recipients is unreadable by
        /// anyone, including the person who just removed the last one.
        case refusedEmptyRecipients
        /// No session key is configured. Reading recipients never needed
        /// one; re-wrapping the data key does. Distinct from `.failed` so
        /// the view can explain this rather than show it as a generic
        /// error — see `SessionKeyStore.withKey(_:)`'s "returns nil without
        /// invoking body" contract, which is what produces this case.
        case refusedNoKey
        /// The bridge refused the rewrap, or the write failed. The
        /// associated text is fixed, non-secret diagnostic text — never a
        /// document value or a key.
        case failed(String)
    }

    /// One recipient as the Access panel shows it: the file's own metadata,
    /// a registry label if one exists, and whether it is only staged rather
    /// than applied yet.
    public struct AccessEntry: Identifiable, Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            /// In both the file's current metadata and the staged set.
            case unchanged
            /// In the file's current metadata, staged for removal.
            case pendingRemoval
            /// Staged, not yet in the file's current metadata.
            case pendingAddition
        }

        public let ageRecipient: String
        /// `nil` when no project registry is attached, or the registry has
        /// no record for this public key. Never a reason to hide the entry —
        /// see the type's doc comment.
        public let label: String?
        public let kind: RecipientKind?
        public let note: String?
        public let status: Status

        public var id: String { ageRecipient }
    }

    public private(set) var loadState: LoadState = .idle
    /// Whether an `apply()` is in flight. The view disables Apply/Cancel
    /// while this is true, mirroring `SecretDocumentViewModel.isSaving`.
    public private(set) var isApplying = false

    /// The recipients this document's metadata reported at the last
    /// successful `load()` or `apply()`. Never mutated by staging.
    public private(set) var currentRecipients: [String] = []
    /// The working set staged for the next `apply()`. Starts equal to
    /// `currentRecipients` every time `load()`/`apply()` succeeds.
    public private(set) var stagedRecipients: [String] = []
    public private(set) var registryRecords: [RecipientRecord] = []

    private let fileURL: URL
    private let projectURL: URL?
    private let keyStore: SessionKeyStore
    private let readFile: (URL) throws -> String
    private let fingerprintFile: (URL) -> FileFingerprint?
    private let writeFile: (String, URL, FileFingerprint?) throws -> FileFingerprint?
    private let loadRegistry: (URL) -> [RecipientRecord]

    /// This file's own encrypted bytes, as last read by `load()` or produced
    /// by the most recent successful `apply()`. `nil` until a load has
    /// succeeded at least once.
    private var encryptedContents: String?
    /// What the file looked like when `encryptedContents` was taken from it —
    /// the same second-writer guard `SecretDocumentViewModel` uses, applied
    /// independently here because this type reads and writes the file on its
    /// own, never through the document view model's private state.
    private var loadedFingerprint: FileFingerprint?

    /// - Parameters:
    ///   - fileURL: The encrypted SOPS document this model manages access
    ///     for.
    ///   - projectURL: The project this file belongs to, for registry
    ///     labels. `nil` for a file opened without a project — every
    ///     recipient still shows, only unlabeled.
    ///   - keyStore: Where the session's decryption identity comes from.
    ///     Never copied out of its own lending API — see `apply()`.
    ///   - readFile/fingerprintFile/writeFile: Same seams as
    ///     `SecretDocumentViewModel`'s initializer, for the same reason —
    ///     tests can force a read/write failure without filesystem
    ///     permission tricks.
    ///   - loadRegistry: How the project's recipient registry is read.
    ///     Deliberately non-throwing: the registry is a label directory, not
    ///     an access authority, so a registry this cannot read (missing,
    ///     malformed) degrades to "no labels" rather than blocking the
    ///     recipients the file's own metadata already reports.
    public init(
        fileURL: URL,
        projectURL: URL?,
        keyStore: SessionKeyStore,
        readFile: @escaping (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) },
        fingerprintFile: @escaping (URL) -> FileFingerprint? = { FileFingerprint.of($0) },
        writeFile: @escaping (String, URL, FileFingerprint?) throws -> FileFingerprint? = {
            contents, url, expecting in
            try AtomicFileWriter.write(contents, to: url, expecting: expecting).fingerprint
        },
        loadRegistry: @escaping (URL) -> [RecipientRecord] = { project in
            (try? RecipientRegistry.load(in: project)) ?? []
        }
    ) {
        self.fileURL = fileURL
        self.projectURL = projectURL
        self.keyStore = keyStore
        self.readFile = readFile
        self.fingerprintFile = fingerprintFile
        self.writeFile = writeFile
        self.loadRegistry = loadRegistry
    }

    /// Whether the staged set differs from the file's current metadata.
    /// Order-sensitive on purpose: this type's own add/remove API is the
    /// only thing that ever changes either array, and neither reorders what
    /// it did not touch, so two arrays that differ only in order would mean
    /// this type reordered something on its own — a bug this equality would
    /// otherwise hide.
    public var isDirty: Bool { stagedRecipients != currentRecipients }

    /// Whether `apply()` can actually re-wrap right now. Reading recipients
    /// never needs this; only applying does.
    public var keyConfigured: Bool { keyStore.state == .configured }

    /// Every recipient worth showing: the file's current ones (marked
    /// `.unchanged` or `.pendingRemoval`) plus any staged addition not
    /// already in that set (`.pendingAddition`). Order follows
    /// `currentRecipients` first, then new staged additions in the order
    /// they were staged.
    public var entries: [AccessEntry] {
        var seen = Set<String>()
        var result: [AccessEntry] = []
        for recipient in currentRecipients {
            let status: AccessEntry.Status = stagedRecipients.contains(recipient) ? .unchanged : .pendingRemoval
            result.append(makeEntry(recipient, status: status))
            seen.insert(recipient)
        }
        for recipient in stagedRecipients where !seen.contains(recipient) {
            result.append(makeEntry(recipient, status: .pendingAddition))
        }
        return result
    }

    /// Entries about to lose access if `apply()` runs right now — what a
    /// destructive-confirmation dialog names before the user commits.
    public var pendingRemovals: [AccessEntry] { entries.filter { $0.status == .pendingRemoval } }

    private func makeEntry(_ recipient: String, status: AccessEntry.Status) -> AccessEntry {
        let record = registryRecords.first { $0.ageRecipient == recipient }
        return AccessEntry(
            ageRecipient: recipient, label: record?.label, kind: record?.kind, note: record?.note, status: status)
    }

    /// Reads this document's current recipient metadata and, if a project is
    /// attached, its recipient registry. Replaces `currentRecipients` and
    /// resets `stagedRecipients` to match — any unapplied staging from a
    /// previous load is discarded, exactly as `SecretDocumentViewModel.load()`
    /// discards pending row edits on a reload.
    public func load() async {
        loadState = .loading

        // Fingerprint before the read — same ordering, and the same reason,
        // as `SecretDocumentViewModel.load()`: taken first, a concurrent
        // write leaves this holding an older fingerprint against newer
        // contents, so the next `apply()` refuses rather than clobbers.
        let fingerprint = fingerprintFile(fileURL)

        let contents: String
        do {
            contents = try readFile(fileURL)
        } catch {
            reset()
            loadState = .failed("this file could not be read: \(fileURL.lastPathComponent)")
            return
        }

        if fingerprintFile(fileURL) == nil, FileManager.default.fileExists(atPath: fileURL.path) {
            reset()
            loadState = .failed(
                "this file changed while it was being opened, so this app cannot tell what it read: "
                    + fileURL.lastPathComponent)
            return
        }

        guard contents.crossesCBoundaryIntact else {
            reset()
            loadState = .failed(
                "this file contains a NUL byte, which this app cannot read without silently "
                    + "dropping everything after it: " + fileURL.lastPathComponent)
            return
        }

        do {
            let recipients = try SopsBridge.recipients(in: contents)
            encryptedContents = contents
            loadedFingerprint = fingerprint
            currentRecipients = recipients
            stagedRecipients = recipients
            registryRecords = projectURL.map(loadRegistry) ?? []
            loadState = .loaded
        } catch let error as SopsBridgeError {
            reset()
            loadState = .failed(error.description)
        } catch {
            reset()
            loadState = .failed("this file's recipients could not be read")
        }
    }

    private func reset() {
        currentRecipients = []
        stagedRecipients = []
        registryRecords = []
        encryptedContents = nil
        loadedFingerprint = nil
    }

    /// Stages `ageRecipient` for addition, in memory only. A no-op refusal
    /// (rather than a throw) for the same reason
    /// `SecretDocumentViewModel.refusalForAdding` answers rather than
    /// throws: the view needs this to disable an Add button before the user
    /// commits, not just to catch a mistake after the fact.
    @discardableResult
    public func stageAdd(_ ageRecipient: String) -> StageAddRefusal? {
        guard loadState == .loaded else { return .notLoaded }
        let trimmed = ageRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard !stagedRecipients.contains(trimmed) else { return .duplicate }
        stagedRecipients.append(trimmed)
        return nil
    }

    /// Stages `ageRecipient` for removal, in memory only. Symmetric with
    /// `stageAdd`: calling this on a recipient that only exists because it
    /// was staged (never in `currentRecipients`) simply undoes that
    /// addition, and calling `stageAdd` again on a recipient this staged for
    /// removal undoes the removal — there is no separate "undo" API because
    /// none is needed.
    public func stageRemove(_ ageRecipient: String) {
        stagedRecipients.removeAll { $0 == ageRecipient }
    }

    /// Returns `stagedRecipients` to `currentRecipients`, discarding every
    /// staged add/remove. Never touches the file.
    public func discardStagedChanges() {
        stagedRecipients = currentRecipients
    }

    /// Re-wraps the document's data key for exactly `stagedRecipients` and
    /// writes the result atomically, then adopts the new set as
    /// `currentRecipients` and clears the staged/baseline difference.
    ///
    /// This is the only place this type calls into the bridge, and the only
    /// bridge call it makes is `SopsBridge.updateRecipients` — staging never
    /// does, and neither does reading (`SopsBridge.recipients` needs no
    /// identity and never re-wraps anything).
    ///
    /// Refuses, without calling the bridge or touching the file, when the
    /// staged set is empty (`.refusedEmptyRecipients`) or no session key is
    /// configured (`.refusedNoKey`, from `SessionKeyStore.withKey`'s "no
    /// key configured" contract — the closure passed to it is never
    /// invoked). A no-op that reports `.applied` when nothing is staged
    /// that differs from the current set, mirroring
    /// `SecretDocumentViewModel.save()`'s not-dirty no-op.
    ///
    /// A failure — refused set, no key, bridge error, write error — leaves
    /// `currentRecipients`/`stagedRecipients` exactly as they were: nothing
    /// staged is lost, and nothing on disk changes.
    public func apply() async -> ApplyOutcome {
        guard !isApplying else {
            return .failed("an apply of this file's recipients is already in progress")
        }
        guard loadState == .loaded, let contents = encryptedContents else {
            return .failed("no document is loaded")
        }
        guard !stagedRecipients.isEmpty else {
            return .refusedEmptyRecipients
        }
        guard isDirty else { return .applied }

        isApplying = true
        defer { isApplying = false }

        let recipientsToApply = stagedRecipients
        let applied: Outcome<String>? = await keyStore.withKey { key in
            await Self.rewrap(contents, to: recipientsToApply, agePrivateKey: key)
        }

        guard let applied else { return .refusedNoKey }

        switch applied {
        case .failure(let message):
            return .failed(message)
        case .success(let newEncrypted):
            let written: FileFingerprint?
            do {
                written = try writeFile(newEncrypted, fileURL, loadedFingerprint)
            } catch let error as AtomicFileWriter.Error {
                return .failed("this file's recipients could not be written to disk: \(error.description)")
            } catch {
                return .failed(
                    "this file's recipients could not be written to disk: \(fileURL.lastPathComponent)")
            }
            encryptedContents = newEncrypted
            loadedFingerprint = written
            currentRecipients = recipientsToApply
            stagedRecipients = recipientsToApply
            return .applied
        }
    }

    /// Mirrors `SecretDocumentViewModel`'s private `Outcome`: a plain-message
    /// failure instead of `Swift.Result`'s `Failure: Error`, because
    /// `SopsBridgeError`'s only surface this needs is `description`, and
    /// `Sendable` so it can cross the dedicated thread `runOffCooperativePool`
    /// hops to and back.
    private enum Outcome<Success: Sendable>: Sendable {
        case success(Success)
        case failure(String)
    }

    private static func rewrap(
        _ contents: String, to recipients: [String], agePrivateKey key: String
    ) async -> Outcome<String> {
        await runOffCooperativePool {
            do {
                return .success(try SopsBridge.updateRecipients(contents, to: recipients, agePrivateKey: key))
            } catch let error as SopsBridgeError {
                return .failure(error.description)
            } catch {
                return .failure("this file's recipients could not be updated")
            }
        }
    }

    /// Same reasoning, and the same measured `Task.detached` failure mode, as
    /// `SecretDocumentViewModel.runOffCooperativePool` — duplicated rather
    /// than shared because that one is private to its own file. See that
    /// type's doc comment for the measurements behind not using
    /// `Task.detached` or `DispatchQueue.global()` here.
    private static func runOffCooperativePool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            let thread = Thread {
                continuation.resume(returning: body())
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
