import Foundation
import Darwin

/// The role a named age public key has for the people maintaining a project.
/// This is descriptive only: SOPS metadata and `.sops.yaml` remain the access
/// authority.
public enum RecipientKind: String, Codable, CaseIterable, Sendable {
    case device
    case server
    case person
}

/// A public-only entry in a project's shared recipient directory.
///
/// `ageRecipient` is deliberately a native age *public* recipient. Private
/// identities have a different shape (`AGE-SECRET-KEY-1…`) and are rejected
/// by `RecipientRegistry` before a record can be persisted.
public struct RecipientRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var label: String
    public var kind: RecipientKind
    public var ageRecipient: String
    public var note: String?

    public init(
        id: UUID = UUID(), label: String, kind: RecipientKind, ageRecipient: String, note: String? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.ageRecipient = ageRecipient
        self.note = note
    }
}

/// Reads and writes a project's versioned, public-only recipient directory.
///
/// The registry lives at `.sops-gui/recipients.json` below the supplied
/// project directory. It is not an access-control source: labels here only
/// help people recognize the actual age recipients stored in SOPS metadata.
public enum RecipientRegistry {
    /// A concrete state observed at the registry path. Unlike an optional
    /// fingerprint, this cannot silently turn a guarded save into an
    /// unconditional one when the registry did not yet exist.
    public enum ExpectedState: Equatable, Sendable {
        case absent
        case existing(FileFingerprint)
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyLabel
        case invalidAgeRecipient
        /// A record already exists whose `ageRecipient` matches the one being
        /// saved. No associated value — see `RecipientLabelEditorModel
        /// .explanation(for:)`'s doc comment: nothing in this codebase reads
        /// one, a public key is not itself a secret, but a refusal that
        /// quotes its input is a habit this type does not want to form,
        /// least of all here.
        case duplicateAgeRecipient
        /// A record already exists with the same `id`. No associated value,
        /// for the identical reason `duplicateAgeRecipient` has none.
        case duplicateID
        case privateIdentityNotAllowed
        case recordNotFound(UUID)
        case changedOnDisk
        case pathEscapesProject
        case couldNotSave
    }

    /// Returns an empty directory for a project that has not created one yet.
    public static func load(in project: URL) throws -> [RecipientRecord] {
        try loadSnapshot(in: project).records
    }

    /// `load(in:)`, but for the six call sites in `SopsUI` that used to spell
    /// it `(try? RecipientRegistry.load(in:)) ?? []` — every one of them a
    /// pure label lookup with nowhere it was worth threading a thrown error
    /// through. That idiom is honest about an *absent* registry (`.absent` is
    /// a real, legitimate empty state — a project that has never named a
    /// recipient), but it cannot tell absence apart from a `recipients.json`
    /// that exists and cannot be decoded, and a corrupt-but-present file
    /// degrades to the exact same silent `[]` either way.
    ///
    /// This distinguishes them. A file that fails to *decode* — the shape
    /// `RecipientRegistryCorruptionTests` exercises — is moved aside the
    /// same way `ProjectStore.quarantine(_:reason:)` moves a corrupt
    /// `projects.json`, so the record is preserved for hand recovery and the
    /// *next* write to this project's registry starts from a clean slate
    /// rather than being one `save()` away from an unguarded overwrite of
    /// bytes nobody could read. `quarantineNotice` is `nil` on every
    /// ordinary path — absent, present and readable, or present and
    /// undecodable but not on this specific move (see `quarantine(in:)`'s own
    /// doc comment for that one narrower case) — and non-`nil` exactly when
    /// something happened that the six call sites did not used to have any
    /// way to tell their user about.
    ///
    /// Any *other* error `load(in:)` can throw — `Error.changedOnDisk` (a
    /// second writer's fingerprint race, not corruption) or a transient
    /// `Error.couldNotSave` from the read itself — degrades to `[]` with no
    /// notice and no quarantine, matching every one of the six call sites'
    /// prior behaviour for those cases exactly: neither is evidence the file
    /// itself is bad.
    public static func loadOrQuarantine(in project: URL) -> (records: [RecipientRecord], quarantineNotice: String?) {
        do {
            return (try load(in: project), nil)
        } catch is DecodingError {
            return quarantine(in: project)
        } catch {
            return ([], nil)
        }
    }

    /// Moves an undecodable `recipients.json` aside — `recipients-corrupt-
    /// <timestamp>-<uuid>.json`, alongside it in `.sops-gui/` — so the file
    /// this call just failed to read cannot later be clobbered by an
    /// unguarded save building its baseline from `(try? load) ?? []`'s empty
    /// result.
    ///
    /// Goes through the same directory-descriptor path every other mutation
    /// in this type does (`registryDirectoryDescriptor`, opened `O_NOFOLLOW`)
    /// rather than a `FileManager` move keyed by URL, for the identical
    /// reason the rest of this type does: once the directory is open by
    /// descriptor, a symlink swapped in afterward cannot redirect the rename.
    ///
    /// The one case this cannot make safe on its own is the rename itself
    /// failing — a read-only `.sops-gui` directory, most likely. `quarantineNotice`
    /// still names the problem either way; only the wording differs, exactly
    /// as `ProjectStore.quarantine(_:reason:)`'s `unsafeToWrite` split does.
    private static func quarantine(in project: URL) -> (records: [RecipientRecord], quarantineNotice: String?) {
        let displayPath = fileURL(in: project).path
        guard let directory = try? registryDirectoryDescriptor(in: project, create: false)
        else {
            // No `.sops-gui` directory to open by descriptor — the file this
            // call was told about must have vanished between `load`'s read
            // and here. Nothing to quarantine; say so rather than claim a
            // move that did not happen.
            return ([], "Your recipient names at \(displayPath) could not be read, and this app could not open the directory that held them to move it aside. Names are unavailable until that is resolved by hand.")
        }
        defer { close(directory) }

        let quarantineName = "recipients-corrupt-\(quarantineTimestampFormatter.string(from: Date()))-\(UUID().uuidString).json"
        guard renameat(directory, recipientFileName, directory, quarantineName) == 0 else {
            return ([], "Your recipient names at \(displayPath) could not be read, and this app could not move it aside to protect it either. Names are unavailable until the file at that path is moved, renamed, or deleted by hand.")
        }
        _ = fsync(directory)

        let quarantinePath = directoryURL(in: project).appendingPathComponent(quarantineName).path
        return ([], "Your recipient names at \(displayPath) could not be read, so the file has been moved aside to \(quarantinePath) in case it can be recovered by hand. Starting fresh from here — nothing was deleted, but every name will need to be re-added.")
    }

    /// `yyyyMMdd'T'HHmmss'Z'-<uuid>`, the same shape
    /// `ProjectStore.quarantinedURL(for:)` uses and for the identical
    /// reason: the timestamp alone is not unique at second resolution (two
    /// corruption events landing in the same second collide), the `UUID` is
    /// what actually guarantees it, and the timestamp is kept anyway because
    /// it costs nothing and makes the backups sort chronologically.
    private static let quarantineTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// The state a caller must carry from its read/preview to a later save.
    /// It distinguishes a registry that was absent from an API caller that
    /// simply chose not to check for concurrent writes.
    public static func expectedState(in project: URL) throws -> ExpectedState {
        guard let directory = try registryDirectoryDescriptor(in: project, create: false) else { return .absent }
        defer { close(directory) }
        guard let fingerprint = try fingerprint(of: recipientFileName, in: directory) else { return .absent }
        return .existing(fingerprint)
    }

    /// Reads a registry together with the fingerprint of the exact bytes read.
    ///
    /// The before/after comparison closes the otherwise invisible race where a
    /// second writer replaces the file after decoding but before an upsert
    /// takes its write expectation: that later fingerprint would bless bytes
    /// this caller never read.
    private static func loadSnapshot(in project: URL) throws -> (
        records: [RecipientRecord], state: ExpectedState
    ) {
        guard let directory = try registryDirectoryDescriptor(in: project, create: false) else { return ([], .absent) }
        defer { close(directory) }
        guard let before = try fingerprint(of: recipientFileName, in: directory) else { return ([], .absent) }
        let records = try JSONDecoder().decode([RecipientRecord].self, from: read(recipientFileName, in: directory))
        guard try fingerprint(of: recipientFileName, in: directory) == before else {
            throw Error.changedOnDisk
        }
        try validate(records)
        return (records, .existing(before))
    }

    /// Validates and atomically replaces the project's recipient directory.
    public static func save(_ records: [RecipientRecord], in project: URL) throws {
        try save(records, in: project, expecting: expectedState(in: project))
    }

    /// Saves only if the registry is exactly the explicit state observed by
    /// the caller. `.absent` is an atomic create-if-absent, never `nil`.
    public static func save(_ records: [RecipientRecord], in project: URL, expecting: ExpectedState) throws {
        try validate(records)
        guard let directory = try registryDirectoryDescriptor(in: project, create: true) else {
            throw Error.couldNotSave
        }
        defer { close(directory) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        try publish(data, in: directory, expecting: expecting)
    }

    /// Inserts a new record or replaces the record bearing the same UUID.
    @discardableResult
    public static func upsert(_ record: RecipientRecord, in project: URL) throws -> [RecipientRecord] {
        let snapshot = try loadSnapshot(in: project)
        var records = snapshot.records
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records, in: project, expecting: snapshot.state)
        return records
    }

    @discardableResult
    public static func upsert(
        _ record: RecipientRecord, in project: URL, expecting: ExpectedState
    ) throws -> [RecipientRecord] {
        var records = try load(in: project)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records, in: project, expecting: expecting)
        return records
    }

    /// Removes a record by ID and persists the resulting directory.
    @discardableResult
    public static func remove(_ id: UUID, in project: URL) throws -> [RecipientRecord] {
        let snapshot = try loadSnapshot(in: project)
        var records = snapshot.records
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw Error.recordNotFound(id)
        }
        records.remove(at: index)
        try save(records, in: project, expecting: snapshot.state)
        return records
    }

    @discardableResult
    public static func remove(
        _ id: UUID, in project: URL, expecting: ExpectedState
    ) throws -> [RecipientRecord] {
        var records = try load(in: project)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw Error.recordNotFound(id)
        }
        records.remove(at: index)
        try save(records, in: project, expecting: expecting)
        return records
    }

    public static func fileURL(in project: URL) -> URL {
        directoryURL(in: project).appendingPathComponent("recipients.json")
    }

    private static func directoryURL(in project: URL) -> URL {
        project.appendingPathComponent(".sops-gui", isDirectory: true)
    }

    /// Why `candidate` may not be used as an age recipient, or `nil` when
    /// nothing refuses it — exactly the two checks `validate(_:)` applies to
    /// `RecipientRecord.ageRecipient`, lifted out so a caller that is not
    /// about to persist a record can ask the same question.
    ///
    /// Returns `.privateIdentityNotAllowed` for anything containing the
    /// private-identity shape and `.invalidAgeRecipient` for anything that is
    /// not a native `age1…` key; never any other case. It is a pure function
    /// of `candidate` — no filesystem, no registry — which is what lets
    /// `RecipientPicker.canAdd(_:existing:)` gate its own free-text field on
    /// the identical rule this type enforces at the persistence boundary,
    /// rather than growing a second, quietly divergent copy of it. That
    /// divergence was a real finding, not a tidiness argument: the picker
    /// checked only "empty" and "duplicate", so a pasted
    /// `AGE-SECRET-KEY-1…` identity could be added, and
    /// `SopsConfigGenerator.propose` then interpolated it into `.sops.yaml`
    /// text and staged that text inside the project directory before sops's
    /// own parser rejected it — a private key written to the user's working
    /// tree, in a file no `.gitignore` covers.
    ///
    /// Refuses the private-identity shape *before* the `age1…` shape check,
    /// so a pasted identity is always told what is actually wrong with it
    /// rather than being called malformed.
    public static func refusal(forAgeRecipient candidate: String) -> Error? {
        if containsPrivateIdentityShape(candidate) { return .privateIdentityNotAllowed }
        guard looksLikeNativeAgeRecipient(candidate) else { return .invalidAgeRecipient }
        return nil
    }

    private static func validate(_ records: [RecipientRecord]) throws {
        var recipientIDs = Set<String>()
        var recordIDs = Set<UUID>()
        for record in records {
            guard !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.emptyLabel
            }
            guard !containsPrivateIdentityShape(record.label),
                  !containsPrivateIdentityShape(record.note ?? "") else {
                throw Error.privateIdentityNotAllowed
            }
            // `ageRecipient`'s own two checks, in the identical order they
            // used to be written inline here — see `refusal(forAgeRecipient:)`
            // for why they now live in a function this type is no longer the
            // only caller of.
            if let refusal = refusal(forAgeRecipient: record.ageRecipient) {
                throw refusal
            }
            guard recordIDs.insert(record.id).inserted else { throw Error.duplicateID }
            guard recipientIDs.insert(record.ageRecipient).inserted else {
                throw Error.duplicateAgeRecipient
            }
        }
    }

    private static func containsPrivateIdentityShape(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("AGE-SECRET-KEY-1")
    }

    private static let recipientFileName = "recipients.json"

    /// Opens each trust boundary by descriptor. Once `directory` is open with
    /// `O_NOFOLLOW`, every registry operation below is relative to that
    /// descriptor; a later symlink swap cannot redirect staging or publish.
    private static func registryDirectoryDescriptor(in project: URL, create: Bool) throws -> Int32? {
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
            guard try fingerprint(of: recipientFileName, in: directory) == expected,
                  let mode = try permissions(of: recipientFileName, in: directory) else {
                throw Error.changedOnDisk
            }
            finalMode = mode
        }
        let staged = ".recipients.\(UUID().uuidString).tmp"
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
            guard try fingerprint(of: recipientFileName, in: directory) == expected else {
                throw Error.changedOnDisk
            }
            guard renameat(directory, staged, directory, recipientFileName) == 0 else {
                throw Error.couldNotSave
            }
        case .absent:
            guard try fingerprint(of: recipientFileName, in: directory) == nil else {
                throw Error.changedOnDisk
            }
            guard linkat(directory, staged, directory, recipientFileName, 0) == 0 else {
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

    /// Native X25519 age recipients are Bech32 with the fixed `age` HRP, a
    /// valid Bech32 checksum, and an exactly 32-byte decoded public key.
    private static func looksLikeNativeAgeRecipient(_ value: String) -> Bool {
        guard value.count == 62, value.hasPrefix("age1") else { return false }
        let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        let values = value.dropFirst(4).compactMap { alphabet.firstIndex(of: $0) }
        guard values.count == 58, bech32Polymod(bech32HRPExpand("age") + values) == 1 else {
            return false
        }
        return convertBits(Array(values.dropLast(6)), from: 5, to: 8, pad: false)?.count == 32
    }

    private static func bech32HRPExpand(_ hrp: String) -> [Int] {
        hrp.utf8.map { Int($0 >> 5) } + [0] + hrp.utf8.map { Int($0 & 31) }
    }

    private static func bech32Polymod(_ values: [Int]) -> UInt32 {
        let generators: [UInt32] = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3]
        return values.reduce(UInt32(1)) { checksum, value in
            let top = checksum >> 25
            var next = (checksum & 0x1ffffff) << 5 ^ UInt32(value)
            for (index, generator) in generators.enumerated() where ((top >> index) & 1) == 1 {
                next ^= generator
            }
            return next
        }
    }

    private static func convertBits(_ values: [Int], from: Int, to: Int, pad: Bool) -> [UInt8]? {
        var accumulator = 0
        var bits = 0
        let maxOutput = (1 << to) - 1
        let maxAccumulator = (1 << (from + to - 1)) - 1
        var output: [UInt8] = []

        for value in values {
            guard value >= 0, value >> from == 0 else { return nil }
            accumulator = ((accumulator << from) | value) & maxAccumulator
            bits += from
            while bits >= to {
                bits -= to
                output.append(UInt8((accumulator >> bits) & maxOutput))
            }
        }
        if pad, bits > 0 {
            output.append(UInt8((accumulator << (to - bits)) & maxOutput))
        } else if bits >= from || ((accumulator << (to - bits)) & maxOutput) != 0 {
            return nil
        }
        return output
    }
}
