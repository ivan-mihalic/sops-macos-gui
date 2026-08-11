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
        let url = fileURL(in: project)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let records = try JSONDecoder().decode([RecipientRecord].self, from: Data(contentsOf: url))
        try validate(records)
        return records
    }

    /// Validates and atomically replaces the project's recipient directory.
    public static func save(_ records: [RecipientRecord], in project: URL) throws {
        try validate(records)

        let directory = directoryURL(in: project)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(records)
        _ = try AtomicFileWriter.write(data, to: fileURL(in: project))
    }

    /// Inserts a new record or replaces the record bearing the same UUID.
    @discardableResult
    public static func upsert(_ record: RecipientRecord, in project: URL) throws -> [RecipientRecord] {
        var records = try load(in: project)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try save(records, in: project)
        return records
    }

    /// Removes a record by ID and persists the resulting directory.
    @discardableResult
    public static func remove(_ id: UUID, in project: URL) throws -> [RecipientRecord] {
        var records = try load(in: project)
        guard let index = records.firstIndex(where: { $0.id == id }) else {
            throw Error.recordNotFound(id)
        }
        records.remove(at: index)
        try save(records, in: project)
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

    /// Native X25519 age recipients have the fixed `age1` prefix and a
    /// lower-case Bech32 payload of fixed length. This accepts no private
    /// identity, plugin recipient, or arbitrary `age1…` prefix. Full Bech32
    /// checksum validation belongs to the SOPS bridge that consumes the key;
    /// this directory only guards its public-only stored shape.
    private static func looksLikeNativeAgeRecipient(_ value: String) -> Bool {
        guard value.count == 62, value.hasPrefix("age1") else { return false }
        let alphabet = Set("023456789acdefghjklmnpqrstuvwxyz")
        return value.dropFirst(4).allSatisfy(alphabet.contains)
    }
}
