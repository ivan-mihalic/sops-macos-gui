import Foundation
import ScratchCleanup
import Testing
@testable import SopsProjects

@Suite("RecipientRegistry")
struct RecipientRegistryTests {
    private static let firstPublicKey = "age1l3re6nlra8gmrpxr7j35hnhkyw48sdwawp9gsrsfxkw9jdm3ydxs2fnlh6"
    private static let secondPublicKey = "age1kecsr00wpjmwykpp9xytszmzwum228uxrassad5dse9c06wdsqfqmjafpp"

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("recipient-registry-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    @Test("saved records round-trip through the project registry JSON")
    func roundTripsJSON() throws {
        let project = try makeProject()
        let record = RecipientRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            label: "Production server",
            kind: .server,
            ageRecipient: Self.firstPublicKey,
            note: "SSH host"
        )

        try RecipientRegistry.save([record], in: project)

        #expect(try RecipientRegistry.load(in: project) == [record])
    }

    @Test("a second record cannot reuse an existing public key")
    func rejectsDuplicatePublicKey() throws {
        let project = try makeProject()
        let first = RecipientRecord(label: "Laptop", kind: .device, ageRecipient: Self.firstPublicKey)
        let duplicate = RecipientRecord(label: "Backup", kind: .server, ageRecipient: Self.firstPublicKey)
        try RecipientRegistry.upsert(first, in: project)

        #expect(throws: RecipientRegistry.Error.duplicateAgeRecipient(Self.firstPublicKey)) {
            try RecipientRegistry.upsert(duplicate, in: project)
        }
        #expect(try RecipientRegistry.load(in: project) == [first])
    }

    @Test("a malformed age recipient is refused before it reaches disk")
    func rejectsInvalidAgeRecipient() throws {
        let project = try makeProject()
        let invalid = RecipientRecord(label: "Bad", kind: .person, ageRecipient: "age1not-a-public-key")

        #expect(throws: RecipientRegistry.Error.invalidAgeRecipient) {
            try RecipientRegistry.upsert(invalid, in: project)
        }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent(".sops-gui/recipients.json").path))
    }

    @Test("a checksum-invalid age-shaped recipient is refused before it reaches disk")
    func rejectsChecksumInvalidAgeRecipient() throws {
        let project = try makeProject()
        // Same length and alphabet as `firstPublicKey`; only its Bech32
        // checksum is corrupted, so a prefix/shape-only validation accepts it.
        let badChecksum = "age1l3re6nlra8gmrpxr7j35hnhkyw48sdwawp9gsrsfxkw9jdm3ydxs2fnlhq"
        let invalid = RecipientRecord(label: "Bad checksum", kind: .person, ageRecipient: badChecksum)

        #expect(throws: RecipientRegistry.Error.invalidAgeRecipient) {
            try RecipientRegistry.upsert(invalid, in: project)
        }
        #expect(!FileManager.default.fileExists(atPath: RecipientRegistry.fileURL(in: project).path))
    }

    @Test("save atomically replaces an existing complete registry without staging files left behind")
    func savesAtomically() throws {
        let project = try makeProject()
        let first = RecipientRecord(label: "Laptop", kind: .device, ageRecipient: Self.firstPublicKey)
        let second = RecipientRecord(label: "Deploy", kind: .server, ageRecipient: Self.secondPublicKey)
        try RecipientRegistry.save([first], in: project)

        try RecipientRegistry.save([second], in: project)

        #expect(try RecipientRegistry.load(in: project) == [second])
        let directory = project.appendingPathComponent(".sops-gui", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
            .isEmpty)
    }

    @Test("a save refuses to overwrite a registry changed after it was observed")
    func refusesSecondWriter() throws {
        let project = try makeProject()
        let original = RecipientRecord(label: "Laptop", kind: .device, ageRecipient: Self.firstPublicKey)
        let ours = RecipientRecord(label: "Deploy", kind: .server, ageRecipient: Self.secondPublicKey)
        let external = RecipientRecord(
            label: "External", kind: .person,
            ageRecipient: "age1hwzmx5590r4h6j0as6alh684v6agr6navclqnpz8lne0pndt4ehqeu86pn")
        try RecipientRegistry.save([original], in: project)
        let file = RecipientRegistry.fileURL(in: project)
        let observed = FileFingerprint.of(file)

        try AtomicFileWriter.write(try JSONEncoder().encode([external]), to: file)

        #expect(throws: AtomicFileWriter.Error.destinationChangedOnDisk(path: file.path)) {
            try RecipientRegistry.upsert(ours, in: project, expecting: observed)
        }
        #expect(try RecipientRegistry.load(in: project) == [external])
    }

    @Test("a blank label and a private identity never enter the registry JSON")
    func rejectsPrivateShapeAndBlankLabel() throws {
        let project = try makeProject()
        let blank = RecipientRecord(label: "  ", kind: .person, ageRecipient: Self.firstPublicKey)
        let privateIdentity = RecipientRecord(
            label: "Private", kind: .device, ageRecipient: "AGE-SECRET-KEY-1EXAMPLE")

        #expect(throws: RecipientRegistry.Error.emptyLabel) {
            try RecipientRegistry.upsert(blank, in: project)
        }
        #expect(throws: RecipientRegistry.Error.invalidAgeRecipient) {
            try RecipientRegistry.upsert(privateIdentity, in: project)
        }
    }
}
