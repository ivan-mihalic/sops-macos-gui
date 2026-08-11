import Foundation

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
    public enum Error: Swift.Error, Equatable, Sendable {
        case emptyLabel
        case invalidAgeRecipient
        case duplicateAgeRecipient(String)
        case recordNotFound(UUID)
    }

    /// Returns an empty directory for a project that has not created one yet.
    public static func load(in project: URL) throws -> [RecipientRecord] {
        try loadSnapshot(in: project).records
    }

    /// Reads a registry together with the fingerprint of the exact bytes read.
    ///
    /// The before/after comparison closes the otherwise invisible race where a
    /// second writer replaces the file after decoding but before an upsert
    /// takes its write expectation: that later fingerprint would bless bytes
    /// this caller never read.
    private static func loadSnapshot(in project: URL) throws -> (
        records: [RecipientRecord], fingerprint: FileFingerprint?
    ) {
        let url = fileURL(in: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        let before = FileFingerprint.of(url)
        let records = try JSONDecoder().decode([RecipientRecord].self, from: Data(contentsOf: url))
        guard before == FileFingerprint.of(url) else {
            throw AtomicFileWriter.Error.destinationChangedOnDisk(path: url.path)
        }
        try validate(records)
        return (records, before)
    }

    /// Validates and atomically replaces the project's recipient directory.
    public static func save(
        _ records: [RecipientRecord], in project: URL, expecting: FileFingerprint? = nil
    ) throws {
        try validate(records)

        let directory = directoryURL(in: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        _ = try AtomicFileWriter.write(data, to: fileURL(in: project), expecting: expecting)
    }

    /// Inserts a new record or replaces the record bearing the same UUID.
    @discardableResult
    public static func upsert(
        _ record: RecipientRecord, in project: URL, expecting: FileFingerprint? = nil
    ) throws -> [RecipientRecord] {
        let snapshot = try loadSnapshot(in: project)
        var records = snapshot.records
        let observed = expecting ?? snapshot.fingerprint
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records, in: project, expecting: observed)
        return records
    }

    /// Removes a record by ID and persists the resulting directory.
    @discardableResult
    public static func remove(
        _ id: UUID, in project: URL, expecting: FileFingerprint? = nil
    ) throws -> [RecipientRecord] {
        let snapshot = try loadSnapshot(in: project)
        var records = snapshot.records
        let observed = expecting ?? snapshot.fingerprint
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw Error.recordNotFound(id)
        }
        records.remove(at: index)
        try save(records, in: project, expecting: observed)
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
        for record in records {
            guard !record.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw Error.emptyLabel
            }
            guard looksLikeNativeAgeRecipient(record.ageRecipient) else {
                throw Error.invalidAgeRecipient
            }
            guard recipientIDs.insert(record.ageRecipient).inserted else {
                throw Error.duplicateAgeRecipient(record.ageRecipient)
            }
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
