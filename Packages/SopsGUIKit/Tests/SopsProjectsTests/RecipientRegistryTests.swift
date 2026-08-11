import Foundation
import ScratchCleanup
import Testing
@testable import SopsProjects

@Suite("RecipientRegistry")
struct RecipientRegistryTests {
    private static let firstPublicKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
    private static let secondPublicKey = "age1f7ekyrshavjztvv5zfuvstkjqjhcry9cwk8lprwaxp49cz0cvsdssdfax0"

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
