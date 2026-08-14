import Foundation
import Darwin
import SopsHealth

/// Reads and writes a project's persistent record of rotations it still
/// owes.
///
/// ## The problem this closes
/// Three places in this app learn, transiently, that a secret's values
/// ought to be rotated: the per-file and per-project Access panels, the
/// moment they actually remove a recipient from an applied file, and the
/// health check's gitignore finding, the moment it finds a tracked,
/// unignored plaintext file. Before this type existed none of the three
/// remembered past the instant the *other*, unrelated condition that had
/// been standing in for the memory cleared — re-wrapping the file made the
/// stale-recipient mismatch disappear, and deleting the plaintext file from
/// the index made the tracked-file finding disappear, in both cases while
/// the actual debt (someone already saw the old values) was still owed.
/// This is the durable record that survives both.
///
/// ## What this is not: detection
/// This app cannot see whether a value was ever actually rotated —
/// rotating means changing the secret at whatever system issued it, which
/// PROPOSAL.md places out of this app's scope (it does not generate
/// secrets). Every entry here is recorded automatically, at the moment
/// this app itself witnesses one of the two reasons above. There is no
/// symmetrical automatic *removal* — only `acknowledge(_:in:)`, which is
/// exactly what its name says: taking the user's word that the rotation
/// happened, never confirming it. A caller presenting this to a user must
/// keep that distinction in the wording — "mark as rotated", never
/// "verified rotated".
///
/// ## Where it lives, and why that is safe to commit
/// `.sops-gui/rotation-debt.json`, next to `RecipientRegistry`'s
/// `recipients.json` — same directory, same reasoning. A rotation owed is a
/// team fact, not a personal one: if `.sops-gui/` is committed and shared
/// (the user's own choice, exactly as for the recipient registry) every
/// teammate sees the same outstanding debt instead of each having to
/// rediscover it independently by reading the same stale-recipient mismatch
/// or gitignore history themselves. An entry never carries a value, a key,
/// or an absolute path — only a project-relative path, a reason drawn from
/// a fixed enum, and a timestamp, none of which is secret: the path already
/// names a file that exists on disk, and the reason is implied by facts
/// already visible to anyone who can read the project (`.sops.yaml`, git
/// history).
///
/// ## Persistence
/// The identical fd-based, symlink-safe technique `RecipientRegistry` uses
/// — open the containing directory with `O_NOFOLLOW`, fingerprint-compare,
/// stage into a temp name, `renameat`/`linkat` — duplicated here rather
/// than shared. Not an oversight: refactoring the two to share this code
/// would mean changing an already-tested, already-reviewed symlink-safe
/// writer to serve a second caller, for a tidiness gain, in the one place
/// in this app where a mistake reopens a TOCTOU race. `RecipientRegistry`'s
/// own doc comment for `registryDirectoryDescriptor` explains why every
/// operation goes through an open descriptor rather than a path; nothing
/// about that reasoning is specific to recipients, so it is repeated here
/// verbatim rather than generalised.
public enum RotationDebtLedger {
    /// A concrete state observed at the ledger path — see
    /// `RecipientRegistry.ExpectedState` for why this is not a plain
    /// optional fingerprint.
    public enum ExpectedState: Equatable, Sendable {
        case absent
        case existing(FileFingerprint)
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyPath
        case entryNotFound(UUID)
        case changedOnDisk
        case pathEscapesProject
        case couldNotSave
    }

    public static func load(in project: URL) throws -> [RotationDebtEntry] {
        try loadSnapshot(in: project).entries
    }

    public static func expectedState(in project: URL) throws -> ExpectedState {
        guard let directory = try ledgerDirectoryDescriptor(in: project, create: false) else { return .absent }
        defer { close(directory) }
        guard let fingerprint = try fingerprint(of: ledgerFileName, in: directory) else { return .absent }
        return .existing(fingerprint)
    }

    private static func loadSnapshot(in project: URL) throws -> (
        entries: [RotationDebtEntry], state: ExpectedState
    ) {
        guard let directory = try ledgerDirectoryDescriptor(in: project, create: false) else { return ([], .absent) }
        defer { close(directory) }
        guard let before = try fingerprint(of: ledgerFileName, in: directory) else { return ([], .absent) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = try decoder.decode([RotationDebtEntry].self, from: read(ledgerFileName, in: directory))
        guard try fingerprint(of: ledgerFileName, in: directory) == before else {
            throw Error.changedOnDisk
        }
        try validate(entries)
        return (entries, .existing(before))
    }

    /// Records that `path` (project-relative) owes a rotation for `reason`,
    /// unless an entry for the exact same path and reason is already
    /// outstanding — recording is idempotent, not additive, so calling it
    /// again (a second recipient removed from the same file, a health
    /// check run twice over the same tracked file) never piles up more than
    /// one row for the one fact "this file owes a rotation for this
    /// reason". A file can carry both reasons at once; those are two facts,
    /// not a duplicate of one.
    @discardableResult
    public static func record(
        path: String, reason: RotationDebtReason, in project: URL
    ) throws -> [RotationDebtEntry] {
        let snapshot = try loadSnapshot(in: project)
        guard !snapshot.entries.contains(where: { $0.path == path && $0.reason == reason }) else {
            return snapshot.entries
        }
        var entries = snapshot.entries
        entries.append(RotationDebtEntry(path: path, reason: reason))
        try save(entries, in: project, expecting: snapshot.state)
        return entries
    }

    /// Removes the entry a user says is settled. Never verifies anything —
    /// see the type-level doc comment's "What this is not: detection".
    @discardableResult
    public static func acknowledge(_ id: UUID, in project: URL) throws -> [RotationDebtEntry] {
        let snapshot = try loadSnapshot(in: project)
        guard let index = snapshot.entries.firstIndex(where: { $0.id == id }) else {
            throw Error.entryNotFound(id)
        }
        var entries = snapshot.entries
        entries.remove(at: index)
        try save(entries, in: project, expecting: snapshot.state)
        return entries
    }

    public static func fileURL(in project: URL) -> URL {
        directoryURL(in: project).appendingPathComponent(ledgerFileName)
    }

    private static func directoryURL(in project: URL) -> URL {
        project.appendingPathComponent(".sops-gui", isDirectory: true)
    }

    private static func validate(_ entries: [RotationDebtEntry]) throws {
        for entry in entries {
            guard !entry.path.isEmpty else { throw Error.emptyPath }
        }
    }

    /// Validates and atomically replaces the project's rotation-debt
    /// ledger, refusing unless the ledger is exactly the state `expecting`
    /// describes — the same guarded-write contract `RecipientRegistry.save`
    /// exposes, and public for the same reason: a caller that already holds
    /// a snapshot (this type's own `record`/`acknowledge`, or a test proving
    /// the guard) writes against what it actually observed rather than
    /// racing a second `expectedState(in:)` read.
    public static func save(_ entries: [RotationDebtEntry], in project: URL, expecting: ExpectedState) throws {
        try validate(entries)
        guard let directory = try ledgerDirectoryDescriptor(in: project, create: true) else {
            throw Error.couldNotSave
        }
        defer { close(directory) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try publish(data, in: directory, expecting: expecting)
    }

    private static let ledgerFileName = "rotation-debt.json"

    /// Identical shape to `RecipientRegistry.registryDirectoryDescriptor` —
    /// see that function's doc comment for why every operation below goes
    /// through an open descriptor rather than a path a symlink could have
    /// redirected between check and use.
    private static func ledgerDirectoryDescriptor(in project: URL, create: Bool) throws -> Int32? {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard rootDescriptor >= 0 else {
            throw Error.pathEscapesProject
        }
        defer { close(rootDescriptor) }

        var directory = openat(rootDescriptor, ".sops-gui", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        if directory < 0, errno == ENOENT, create {
            guard mkdirat(rootDescriptor, ".sops-gui", mode_t(0o700)) == 0 || errno == EEXIST else {
                throw Error.couldNotSave
            }
            directory = openat(rootDescriptor, ".sops-gui", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        }
        if directory < 0 {
            if errno == ENOENT { return nil }
            throw Error.pathEscapesProject
        }
        return directory
    }

    private static func fingerprint(of name: String, in directory: Int32) throws -> FileFingerprint? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Error.couldNotSave
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Error.pathEscapesProject }
        return FileFingerprint(
            deviceID: UInt64(bitPattern: Int64(info.st_dev)), inode: UInt64(info.st_ino), size: Int64(info.st_size),
            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private static func read(_ name: String, in directory: Int32) throws -> Data {
        let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw Error.changedOnDisk }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            return try handle.readToEnd() ?? Data()
        } catch {
            throw Error.couldNotSave
        }
    }

    private static func publish(_ data: Data, in directory: Int32, expecting: ExpectedState) throws {
        let finalMode: mode_t
        switch expecting {
        case .absent:
            finalMode = 0o600
        case .existing(let expected):
            guard try fingerprint(of: ledgerFileName, in: directory) == expected,
                  let mode = try permissions(of: ledgerFileName, in: directory) else {
                throw Error.changedOnDisk
            }
            finalMode = mode
        }
        let staged = ".rotation-debt.\(UUID().uuidString).tmp"
        var descriptor = openat(directory, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw Error.couldNotSave }
        defer {
            if descriptor >= 0 { close(descriptor) }
            _ = unlinkat(directory, staged, 0)
        }

        do {
            try writeAll(data, to: descriptor)
            guard fchmod(descriptor, finalMode) == 0 else { throw Error.couldNotSave }
            try flush(descriptor)
        } catch {
            throw error
        }
        guard close(descriptor) == 0 else { throw Error.couldNotSave }
        descriptor = -1

        switch expecting {
        case .existing(let expected):
            guard try fingerprint(of: ledgerFileName, in: directory) == expected else {
                throw Error.changedOnDisk
            }
            guard renameat(directory, staged, directory, ledgerFileName) == 0 else {
                throw Error.couldNotSave
            }
        case .absent:
            guard try fingerprint(of: ledgerFileName, in: directory) == nil else {
                throw Error.changedOnDisk
            }
            guard linkat(directory, staged, directory, ledgerFileName, 0) == 0 else {
                if errno == EEXIST { throw Error.changedOnDisk }
                throw Error.couldNotSave
            }
        }
        _ = fsync(directory)
    }

    private static func permissions(of name: String, in directory: Int32) throws -> mode_t? {
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw Error.couldNotSave
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else { throw Error.pathEscapesProject }
        return info.st_mode & 0o7777
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw Error.couldNotSave
                }
            }
        }
    }

    private static func flush(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw Error.couldNotSave }
    }
}

/// The real `RotationDebtSource` `ProjectHealthCheck` is wired to outside
/// tests — every other conformance in the app is `NoRotationDebt`. Reads
/// degrade to "no debt" on any ledger failure rather than surfacing an
/// error a health check has no channel to show (the same "degrade rather
/// than throw" contract `RecipientAccessModel`'s own `loadRegistry` default
/// already uses for this exact ledger's sibling, `RecipientRegistry`);
/// writes are `try?` for the reason `RotationDebtSource.record`'s own
/// protocol doc comment states.
public struct RotationDebtLedgerSource: RotationDebtSource {
    public init() {}

    public func rotationDebt(in project: URL) -> [RotationDebtEntry] {
        (try? RotationDebtLedger.load(in: project)) ?? []
    }

    public func record(path: String, reason: RotationDebtReason, in project: URL) {
        try? RotationDebtLedger.record(path: path, reason: reason, in: project)
    }
}
