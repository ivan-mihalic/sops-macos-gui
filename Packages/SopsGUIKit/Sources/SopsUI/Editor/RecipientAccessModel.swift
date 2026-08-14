import Foundation
import Observation
import SopsEngine
import SopsHealth
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
    /// Set when the last registry read found `recipients.json` present but
    /// undecodable and moved it aside — see `RecipientRegistry
    /// .loadOrQuarantine(in:)`. `nil` on every ordinary path, including a
    /// project that has simply never named a recipient: that is a legitimate
    /// empty registry, not a problem to report. The view renders this as a
    /// banner rather than folding it into `loadState`, because losing
    /// *labels* does not mean this file's own recipients — the thing
    /// `loadState` is about — failed to load.
    public private(set) var registryQuarantineNotice: String?
    /// Rotation debt this app has already recorded for this file — see
    /// `SopsHealth.RotationDebtSource`. Empty when `projectURL` is `nil`
    /// (there is nowhere to read a ledger from) or when nothing is owed.
    /// Populated in `load()` and refreshed by `acknowledgeRotationDebt(_:)`;
    /// never touched by `apply()` re-recording a *new* debt, which reads
    /// straight through to the ledger and does not update this in-memory
    /// copy until the next load — the same "staged view can go stale, and
    /// that is fine" contract `registryRecords` already has via
    /// `reloadRegistry()`.
    public private(set) var rotationDebtEntries: [RotationDebtEntry] = []
    /// The age recipients this file's SOPS metadata named **more than once**,
    /// each listed here exactly once.
    ///
    /// sops does not deduplicate a flat age list, so a real file can carry the
    /// same public key twice — verified directly against the bridge, not
    /// assumed. `currentRecipients` collapses those to one entry apiece,
    /// because access is a set property: a data key wrapped twice for one
    /// public key grants precisely what wrapping it once grants, and a panel
    /// about who can read a file must not model multiplicity as if it were
    /// access. What it must also not do is collapse *silently* — a file whose
    /// metadata is shaped oddly is a thing the user may want told about — so
    /// this is what the panel's disclosure sentence counts. See
    /// `collapsingDuplicates(_:)`.
    public private(set) var duplicatedRecipients: [String] = []

    private let fileURL: URL
    /// The project this file belongs to, for registry labels. `nil` for a file
    /// opened without one. Readable so the label editor knows which project's
    /// `.sops-gui/recipients.json` a name would be written to — naming a
    /// recipient is a registry-only act and never consults this model's
    /// document state.
    public let projectURL: URL?
    private let keyStore: SessionKeyStore
    private let readFile: (URL) throws -> String
    private let fingerprintFile: (URL) -> FileFingerprint?
    private let writeFile: (String, URL, FileFingerprint?) throws -> FileFingerprint?
    private let loadRegistry: (URL) -> (records: [RecipientRecord], quarantineNotice: String?)
    /// The one bridge call `apply()` may make. A seam — not just
    /// `SopsBridge.updateRecipients` called inline — so a test can prove
    /// "apply calls only this" directly (spy on the closure) instead of only
    /// inferring it from decrypt behavior after the fact. `async` so the
    /// default implementation can hop off the main actor for the real
    /// crypto (`runOffCooperativePool`) while a test's substitute can just
    /// call straight through — see `RecipientAccessTests`'s seam-injection
    /// suite.
    private let rewrapRecipients: (String, [String], String) async throws -> String

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
    ///     recipients the file's own metadata already reports. Returns a
    ///     notice alongside the records exactly when the registry existed
    ///     but could not be decoded and was moved aside — see
    ///     `registryQuarantineNotice`.
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
        loadRegistry: @escaping (URL) -> (records: [RecipientRecord], quarantineNotice: String?) = { project in
            RecipientRegistry.loadOrQuarantine(in: project)
        },
        rewrapRecipients: @escaping (String, [String], String) async throws -> String = RecipientAccessModel
            .defaultRewrap
    ) {
        self.fileURL = fileURL
        self.projectURL = projectURL
        self.keyStore = keyStore
        self.readFile = readFile
        self.fingerprintFile = fingerprintFile
        self.writeFile = writeFile
        self.loadRegistry = loadRegistry
        self.rewrapRecipients = rewrapRecipients
    }

    /// Whether the staged set differs from the file's current metadata.
    ///
    /// Compared as sets, not arrays: `stageRemove` deletes in place and
    /// `stageAdd` appends, so undoing a removal by re-adding the same
    /// recipient (exactly what `RecipientAccessView`'s row toggle does)
    /// reorders it to the end without changing *what* is staged. An earlier
    /// version of this compared arrays and asserted the opposite as a
    /// rationale — that no legitimate sequence of this type's own
    /// add/remove calls could produce a same-membership, different-order
    /// result. That claim was false for exactly that undo sequence: with
    /// `currentRecipients == [A, B]`, remove(A) → `[B]`, then add(A) (the
    /// undo) → `[B, A]` — same members, reordered by the very API this type
    /// exposes. An array comparison read that as dirty, which enabled Apply
    /// for a no-op change: a real `updateRecipients` rewrap and disk write
    /// (new MAC, new `lastmodified`) for a set that never actually changed.
    public var isDirty: Bool { Set(stagedRecipients) != Set(currentRecipients) }

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
            // `AccessEntry.id` is the public key, so a repeated recipient here
            // would be two `List` rows carrying one identity. `load()` already
            // collapses what it reads (see `collapsingDuplicates`); this is the
            // same guarantee restated where the identity is actually minted, so
            // a future path that sets `currentRecipients` some other way cannot
            // reintroduce it.
            guard seen.insert(recipient).inserted else { continue }
            let status: AccessEntry.Status = stagedRecipients.contains(recipient) ? .unchanged : .pendingRemoval
            result.append(makeEntry(recipient, status: status))
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
            let collapsed = Self.collapsingDuplicates(recipients)
            encryptedContents = contents
            loadedFingerprint = fingerprint
            currentRecipients = collapsed.distinct
            stagedRecipients = collapsed.distinct
            duplicatedRecipients = collapsed.duplicated
            let registry = projectURL.map(loadRegistry)
            registryRecords = registry?.records ?? []
            registryQuarantineNotice = registry?.quarantineNotice
            rotationDebtEntries = loadRotationDebtEntries()
            loadState = .loaded
        } catch let error as SopsBridgeError {
            reset()
            loadState = .failed(error.description)
        } catch {
            reset()
            loadState = .failed("this file's recipients could not be read")
        }
    }

    /// Re-reads the project's registry, and *only* that.
    ///
    /// What the label editor calls after it writes a name. It deliberately does
    /// not go through `load()`: a reload would re-read the document and reset
    /// `stagedRecipients`, throwing away access edits the user staged and has
    /// not applied — and naming a recipient is not an act on the document at
    /// all. Nothing encrypted is read or written here.
    public func reloadRegistry() {
        guard let projectURL else { return }
        let registry = loadRegistry(projectURL)
        registryRecords = registry.records
        registryQuarantineNotice = registry.quarantineNotice
    }

    /// Tells this file's `RotationDebtLedger` entry that the user says the
    /// rotation is done, and removes it from `rotationDebtEntries` on
    /// success. Never verifies anything — see `RotationDebtEntry`'s and
    /// `RotationDebtSource`'s doc comments for why this app cannot.
    ///
    /// Best-effort in the same direction `recordRotationDebtIfNeeded` is,
    /// but the other way: a failure here (a read-only `.sops-gui`, a
    /// concurrent writer) leaves the entry in place rather than hiding it
    /// while the disk still disagrees, so the user sees it did not clear
    /// and can try again — silently dropping it from the list on a failed
    /// write would be the "confident, wrong" failure mode this app's
    /// findings are held to everywhere else.
    public func acknowledgeRotationDebt(_ id: UUID) {
        guard let projectURL else { return }
        guard (try? RotationDebtLedger.acknowledge(id, in: projectURL)) != nil else { return }
        rotationDebtEntries.removeAll { $0.id == id }
    }

    private func loadRotationDebtEntries() -> [RotationDebtEntry] {
        guard let projectURL else { return [] }
        let path = Self.projectRelativePath(of: fileURL, in: projectURL)
        return ((try? RotationDebtLedger.load(in: projectURL)) ?? []).filter { $0.path == path }
    }

    private func reset() {
        currentRecipients = []
        stagedRecipients = []
        duplicatedRecipients = []
        registryRecords = []
        registryQuarantineNotice = nil
        rotationDebtEntries = []
        encryptedContents = nil
        loadedFingerprint = nil
    }

    /// Splits a recipient list read off a document or a creation rule into the
    /// distinct recipients, in first-seen order, and the ones that appeared
    /// more than once.
    ///
    /// The collapse is deliberate, and the alternative was considered and
    /// rejected. Giving each occurrence a *positional* identity would make
    /// `List` legal, but it would leave two rows that must behave identically —
    /// `stageRemove` deletes every occurrence, so one tap strikes both — which
    /// is a lie about their independence. Making them genuinely independent
    /// would need multiset staging: the ability to remove one of two copies of
    /// a key, an operation the rewrap underneath has no meaning for, since it
    /// wraps the data key once per *distinct* recipient. The set is what access
    /// is; multiplicity is a spelling of the metadata.
    ///
    /// The duplicates are returned rather than dropped so that the panel can
    /// say a file is shaped this way, which is the part a user might want to
    /// know.
    static func collapsingDuplicates(_ recipients: [String]) -> (distinct: [String], duplicated: [String]) {
        var seen = Set<String>()
        var reported = Set<String>()
        var distinct: [String] = []
        var duplicated: [String] = []
        for recipient in recipients {
            if seen.insert(recipient).inserted {
                distinct.append(recipient)
            } else if reported.insert(recipient).inserted {
                duplicated.append(recipient)
            }
        }
        return (distinct, duplicated)
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
    /// call it makes is through the `rewrapRecipients` seam — which, by
    /// default, is exactly `SopsBridge.updateRecipients` and nothing else —
    /// staging never calls it, and neither does reading
    /// (`SopsBridge.recipients` needs no identity and never re-wraps
    /// anything). `RecipientAccessSeamTests` proves this directly by
    /// injecting a counting substitute for the seam, rather than only
    /// inferring it from decrypt behavior after the fact.
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
        // Captured before anything below mutates `currentRecipients` — this
        // is the only point in `apply()` that still holds both "what the
        // file protected before" and "what it is about to protect after" at
        // once. See `recordRotationDebtIfNeeded`.
        let removedRecipients = Set(currentRecipients).subtracting(recipientsToApply)
        let applied: String?
        do {
            // `withKey` is `rethrows`: it returns `nil` without ever calling
            // this closure when no key is configured (`.refusedNoKey`
            // below), and otherwise rethrows whatever the closure throws —
            // so a bridge failure is caught in exactly one place, here,
            // rather than needing a second manual result-wrapping layer the
            // way `SecretDocumentViewModel` uses `Outcome` for its
            // non-`rethrows` call sites.
            applied = try await keyStore.withKey { key in
                try await rewrapRecipients(contents, recipientsToApply, key)
            }
        } catch let error as SopsBridgeError {
            return .failed(error.description)
        } catch {
            return .failed("this file's recipients could not be updated")
        }

        guard let newEncrypted = applied else { return .refusedNoKey }

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
        recordRotationDebtIfNeeded(removedRecipients: removedRecipients)
        return .applied
    }

    /// Records, in the project's `RotationDebtLedger`, that this file now
    /// owes a rotation — called only after `apply()` has already re-wrapped
    /// and written the file, and only when that rewrap actually dropped a
    /// recipient who could therefore have already seen every value the file
    /// held.
    ///
    /// Best-effort and silent on failure, deliberately: the access change
    /// this follows has already succeeded and is already on disk, so a
    /// ledger write failing (a read-only `.sops-gui`, a concurrent writer)
    /// must never turn a successful `apply()` into a reported one — see
    /// `RotationDebtLedger`'s own doc comment for why this record exists and
    /// why an app that cannot verify a rotation happened records the debt
    /// rather than trying to detect its resolution.
    private func recordRotationDebtIfNeeded(removedRecipients: Set<String>) {
        guard let projectURL, !removedRecipients.isEmpty else { return }
        let path = Self.projectRelativePath(of: fileURL, in: projectURL)
        try? RotationDebtLedger.record(path: path, reason: .recipientRemoved, in: projectURL)
        // Reflected immediately rather than waiting for the next `load()` —
        // a user who just removed a recipient and applied should see this
        // file now owes a rotation without having to close and reopen the
        // panel.
        rotationDebtEntries = loadRotationDebtEntries()
    }

    /// `fileURL`'s path relative to `projectURL`, for the ledger entry's
    /// `path` field — which must never be absolute (see
    /// `RotationDebtEntry.path`'s doc comment). Falls back to the file's own
    /// last component for a file this simple prefix comparison cannot place
    /// under the project (a symlink resolving outside it); a debt recorded
    /// under a less precise name is still a debt recorded, and this is a
    /// narrower problem than `ProjectHealthCheck.relativeName` solves, in
    /// the same way `CanonicalPath.of` is a narrower tool than
    /// `.ofLeaf` — this module has no need of the leaf-preserving symlink
    /// case that helper exists for.
    private static func projectRelativePath(of fileURL: URL, in projectURL: URL) -> String {
        let filePath = CanonicalPath.of(fileURL.path)
        let rootPrefix = CanonicalPath.of(projectURL.path) + "/"
        guard filePath.hasPrefix(rootPrefix) else { return fileURL.lastPathComponent }
        return String(filePath.dropFirst(rootPrefix.count))
    }

    /// Runs a synchronous, blocking `body` on a dedicated OS thread instead
    /// of Swift's cooperative thread pool, and bridges the result (or
    /// thrown error) back into `async`. Same reasoning, and the same
    /// measured `Task.detached` failure mode, as
    /// `SecretDocumentViewModel.runOffCooperativePool` — duplicated rather
    /// than shared because that one is private to its own file. See that
    /// type's doc comment for the measurements behind not using
    /// `Task.detached` or `DispatchQueue.global()` here.
    ///
    /// Used only by the default `rewrapRecipients` seam — a test's
    /// substitute has no reason to background itself, which is exactly what
    /// makes the seam cheap to inject from a test (see
    /// `RecipientAccessTests`).
    private static func runOffCooperativePool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    continuation.resume(returning: try body())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }

    /// The default `rewrapRecipients` seam: the real bridge call, off the
    /// main actor. `public` only because Swift requires a `public`
    /// initializer's default argument *values* to reference symbols at
    /// least as visible as the initializer itself — this is not meant to be
    /// called directly. Construct a model without passing
    /// `rewrapRecipients` to get this behavior.
    public static func defaultRewrap(_ contents: String, _ recipients: [String], _ key: String) async throws -> String
    {
        try await runOffCooperativePool {
            try SopsBridge.updateRecipients(contents, to: recipients, agePrivateKey: key)
        }
    }
}
