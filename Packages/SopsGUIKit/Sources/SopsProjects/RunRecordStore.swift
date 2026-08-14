import Foundation

/// A durable trace of one project-wide `ProjectRecipientApplier.apply(...)`
/// run — ticket #24 claim 2.
///
/// Before this existed, `ProjectRecipientApplier.RunResult`/`FileResult`
/// lived only in memory (`ProjectAccessModel.fileResults`) and via
/// `onFileFinished`. Once the Project Access panel closed, there was no way
/// to answer "which files did that last run actually touch, and which did
/// it not get to" — a run cancelled between files (see
/// `ProjectRecipientApplier.apply`'s own doc comment on cancellation)
/// left the project in a mixed state with nothing recording which files
/// were which.
///
/// Contains no secret: recipients are age *public* keys (already visible in
/// every re-wrapped file's own SOPS metadata and, usually, in `.sops.yaml`),
/// and file paths are project-relative names the user already sees in the
/// file list. See `RunRecordStore`'s own doc comment for what *is* a
/// deliberate decision here — not what belongs in the record, but where the
/// record itself is allowed to live.
public struct RunRecord: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        case updated
        case unchanged
        case failed
    }

    public struct FileEntry: Codable, Equatable, Sendable {
        /// Project-relative path — never absolute, so this record does not
        /// carry the user's home directory layout into a file that might
        /// still end up read by someone else despite being gitignored by
        /// default (see `RunRecordStore`).
        public let path: String
        public let outcome: Outcome
        /// Set only for `.failed`. The same value-free text
        /// `ProjectRecipientApplier.FileOutcome.failed` already carries —
        /// never a document value, a key, or an identity.
        public let failureReason: String?

        public init(path: String, outcome: Outcome, failureReason: String? = nil) {
            self.path = path
            self.outcome = outcome
            self.failureReason = failureReason
        }
    }

    public let startedAt: Date
    public let finishedAt: Date
    /// The recipient set this run applied — age public keys.
    public let recipients: [String]
    /// One entry per file actually attempted, in the order given.
    public let results: [FileEntry]
    /// Project-relative paths never attempted because the run was cancelled
    /// between files. Empty for a run that completed.
    public let notAttempted: [String]

    public init(
        startedAt: Date, finishedAt: Date, recipients: [String],
        results: [FileEntry], notAttempted: [String]
    ) {
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.recipients = recipients
        self.results = results
        self.notAttempted = notAttempted
    }

    /// Whether this run left files untouched — the fact
    /// `ProjectAccessModel` reads to decide whether to tell the user their
    /// last run did not finish.
    public var wasCancelled: Bool { !notAttempted.isEmpty }
}

/// Persists the most recent `RunRecord` for a project — a single overwritten
/// snapshot, not an accumulating log. `.sops-gui/local/last-apply.json`.
///
/// ## Why `local/`, not directly in `.sops-gui/`
///
/// `.sops-gui/recipients.json` (`RecipientRegistry`) is deliberately
/// versioned, shared team metadata — its own doc comment calls it that, and
/// `docs/GUIDE.md` tells users to commit it. A run record is a different
/// kind of fact entirely: it names no access decision, only "what happened
/// on this machine, just now", and it changes on every apply rather than
/// rarely. Writing it next to `recipients.json` would mean every teammate's
/// local runs generate git diffs and merge conflicts inside a directory the
/// project's own guide tells people to commit — noise with no value to
/// anyone but the person who ran it.
///
/// `local/` is a subdirectory this store owns exclusively, and the first
/// save writes `local/.gitignore` containing `*` — excluding everything
/// under it, including any future file this or another feature adds there.
/// That gitignore write is contained entirely inside `.sops-gui/`, which the
/// app already creates and owns (`RecipientRegistry` does the same for the
/// directory itself); it never touches the project's own top-level
/// `.gitignore`, which no feature in this app writes.
///
/// ## Why a single snapshot, not a log
///
/// The only thing anything in this app needs to answer is "did the last run
/// finish, and if not, what was left" — ticket #24's acceptance criterion is
/// "after the panel closes, it is discoverable which files kept the
/// original recipient set", not a full history. An accumulating log would
/// grow without bound and raise the same git-churn concern `local/` was
/// created to avoid, just deferred rather than avoided. A future feature
/// that genuinely needs history (an audit trail, a "recent runs" screen)
/// is a different, larger decision than this ticket makes.
public enum RunRecordStore {
    private static let fileName = "last-apply.json"

    /// Overwrites this project's last-run record.
    public static func save(_ record: RunRecord, in project: URL) throws {
        let directory = localDirectoryURL(in: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ensureGitignore(in: directory)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        // `expecting: nil` — unconditional — on purpose: this is a
        // last-writer-wins snapshot of "what just happened", not a document
        // with concurrent editors to protect against clobbering. The
        // guarded, expecting-checked write `RecipientRegistry` and
        // `AtomicFileWriter`'s own callers use exists for state a second
        // writer could meaningfully disagree with; nothing disagrees with
        // "here is what the run I just finished did".
        try AtomicFileWriter.write(data, to: fileURL(in: project), expecting: nil)
    }

    /// Reads this project's last-run record, or `nil` when there has never
    /// been one — never an error for the ordinary case of a project nobody
    /// has run an apply against yet.
    public static func load(in project: URL) throws -> RunRecord? {
        let url = fileURL(in: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(RunRecord.self, from: Data(contentsOf: url))
    }

    public static func fileURL(in project: URL) -> URL {
        localDirectoryURL(in: project).appendingPathComponent(fileName)
    }

    private static func localDirectoryURL(in project: URL) -> URL {
        project.appendingPathComponent(".sops-gui", isDirectory: true)
            .appendingPathComponent("local", isDirectory: true)
    }

    /// Writes `local/.gitignore` if it is not already there. Not guarded
    /// against a concurrent writer the way `RecipientRegistry`'s publish
    /// path is — worst case of a race here is the same one-line file
    /// written twice, not a lost edit, so the cost of that hardening is not
    /// worth paying here.
    private static func ensureGitignore(in directory: URL) throws {
        let url = directory.appendingPathComponent(".gitignore")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try "*\n".write(to: url, atomically: true, encoding: .utf8)
    }
}
