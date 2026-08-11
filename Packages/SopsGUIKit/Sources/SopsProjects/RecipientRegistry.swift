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
        case duplicateAgeRecipient(String)
        case duplicateID(UUID)
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

    /// The state a caller must carry from its read/preview to a later save.
    /// It distinguishes a registry that was absent from an API caller that
    /// simply chose not to check for concurrent writes.
    public static func expectedState(in project: URL) throws -> ExpectedState {
        let locations = try resolveLocations(in: project, createDirectory: false)
        guard FileManager.default.fileExists(atPath: locations.destination.path) else { return .absent }
        guard let fingerprint = FileFingerprint.of(locations.destination) else {
            throw Error.changedOnDisk
        }
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
        let locations = try resolveLocations(in: project, createDirectory: false)
        guard FileManager.default.fileExists(atPath: locations.destination.path) else { return ([], .absent) }
        guard let before = FileFingerprint.of(locations.destination) else { throw Error.changedOnDisk }
        let records = try JSONDecoder().decode([RecipientRecord].self, from: Data(contentsOf: locations.destination))
        guard FileFingerprint.of(locations.destination) == before else {
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
        let locations = try resolveLocations(in: project, createDirectory: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        switch expecting {
        case .existing(let fingerprint):
            do {
                _ = try AtomicFileWriter.write(data, to: locations.destination, expecting: fingerprint)
            } catch is AtomicFileWriter.Error {
                throw Error.changedOnDisk
            }
        case .absent:
            try create(data, at: locations.destination, in: locations.directory)
        }
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

    private static func validate(_ records: [RecipientRecord]) throws {
        var recipientIDs = Set<String>()
        var recordIDs = Set<UUID>()
        for record in records {
            guard !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.emptyLabel
            }
            guard !containsPrivateIdentityShape(record.label),
                  !containsPrivateIdentityShape(record.note ?? ""),
                  !containsPrivateIdentityShape(record.ageRecipient) else {
                throw Error.privateIdentityNotAllowed
            }
            guard looksLikeNativeAgeRecipient(record.ageRecipient) else {
                throw Error.invalidAgeRecipient
            }
            guard recordIDs.insert(record.id).inserted else { throw Error.duplicateID(record.id) }
            guard recipientIDs.insert(record.ageRecipient).inserted else {
                throw Error.duplicateAgeRecipient(record.ageRecipient)
            }
        }
    }

    private static func containsPrivateIdentityShape(_ value: String) -> Bool {
        value.localizedCaseInsensitiveContains("AGE-SECRET-KEY-1")
    }

    private static func resolveLocations(in project: URL, createDirectory: Bool) throws -> (
        root: URL, directory: URL, destination: URL
    ) {
        let root = project.standardizedFileURL.resolvingSymlinksInPath()
        var rootIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &rootIsDirectory), rootIsDirectory.boolValue else {
            throw Error.pathEscapesProject
        }
        let directory = root.appendingPathComponent(".sops-gui", isDirectory: true)
        if FileManager.default.fileExists(atPath: directory.path) {
            guard isInside(resolvedForContainment(directory), root: root) else {
                throw Error.pathEscapesProject
            }
        } else if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        }
        let destination = directory.appendingPathComponent("recipients.json")
        guard isInside(resolvedForContainment(destination), root: root) else { throw Error.pathEscapesProject }
        return (root, directory, destination)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath + "/")
    }

    /// `resolvingSymlinksInPath` leaves a dangling final symlink unchanged.
    /// That is normally convenient, but here it would make a link to a
    /// not-yet-created file outside the project look contained, so inspect the
    /// final link target ourselves before resolving the rest of its path.
    private static func resolvedForContainment(_ url: URL) -> URL {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else {
            return url.resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: target, relativeTo: url.deletingLastPathComponent())
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    /// `link` publishes the completed staged file only when no destination
    /// exists. Unlike pre-creating an empty destination, this is atomic for
    /// readers and rejects a concurrent first creator with `EEXIST`.
    private static func create(_ data: Data, at destination: URL, in directory: URL) throws {
        let staged = directory.appendingPathComponent(".recipients.\(UUID().uuidString).create")
        defer { try? FileManager.default.removeItem(at: staged) }
        do {
            _ = try AtomicFileWriter.write(data, to: staged)
        } catch {
            throw Error.couldNotSave
        }
        guard link(staged.path, destination.path) == 0 else {
            if errno == EEXIST { throw Error.changedOnDisk }
            throw Error.couldNotSave
        }
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
