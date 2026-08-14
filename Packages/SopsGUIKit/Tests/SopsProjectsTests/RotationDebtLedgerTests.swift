import Foundation
import ScratchCleanup
import SopsHealth
import Testing
@testable import SopsProjects

@Suite("RotationDebtLedger")
struct RotationDebtLedgerTests {
    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("rotation-debt-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    @Test("an empty project has no rotation debt")
    func emptyByDefault() throws {
        let project = try makeProject()
        #expect(try RotationDebtLedger.load(in: project) == [])
    }

    @Test("recording a debt persists it, and a restart (fresh load) still finds it")
    func recordPersists() throws {
        let project = try makeProject()

        try RotationDebtLedger.record(path: "secrets.yaml", reason: .recipientRemoved, in: project)

        let entries = try RotationDebtLedger.load(in: project)
        #expect(entries.count == 1)
        #expect(entries[0].path == "secrets.yaml")
        #expect(entries[0].reason == .recipientRemoved)
    }

    @Test("recording the same path and reason twice does not duplicate the entry")
    func recordIsIdempotent() throws {
        let project = try makeProject()

        try RotationDebtLedger.record(path: "secrets.yaml", reason: .recipientRemoved, in: project)
        try RotationDebtLedger.record(path: "secrets.yaml", reason: .recipientRemoved, in: project)

        #expect(try RotationDebtLedger.load(in: project).count == 1)
    }

    @Test("the same file can owe a rotation for two different reasons at once")
    func distinctReasonsCoexist() throws {
        let project = try makeProject()

        try RotationDebtLedger.record(path: ".env", reason: .recipientRemoved, in: project)
        try RotationDebtLedger.record(path: ".env", reason: .plaintextCommitted, in: project)

        let entries = try RotationDebtLedger.load(in: project)
        #expect(Set(entries.map(\.reason)) == [.recipientRemoved, .plaintextCommitted])
    }

    @Test("removing a plaintext file from the git index does not clear a recorded debt")
    func acknowledgingIsTheOnlyWayToClear() throws {
        let project = try makeProject()
        try RotationDebtLedger.record(path: ".env", reason: .plaintextCommitted, in: project)

        // Nothing about the *file* changes here — this ledger call is the
        // whole point: recording is a fact this app witnessed once, and
        // nothing downstream of it (deleting the file, un-tracking it)
        // reaches back to erase what was already recorded.
        #expect(try RotationDebtLedger.load(in: project).count == 1)
    }

    @Test("acknowledging removes exactly that entry")
    func acknowledgeRemovesEntry() throws {
        let project = try makeProject()
        try RotationDebtLedger.record(path: "a.yaml", reason: .recipientRemoved, in: project)
        try RotationDebtLedger.record(path: "b.yaml", reason: .recipientRemoved, in: project)
        let toClear = try RotationDebtLedger.load(in: project).first { $0.path == "a.yaml" }!

        try RotationDebtLedger.acknowledge(toClear.id, in: project)

        let remaining = try RotationDebtLedger.load(in: project)
        #expect(remaining.map(\.path) == ["b.yaml"])
    }

    @Test("acknowledging an unknown id is refused")
    func acknowledgeUnknownIDRefused() throws {
        let project = try makeProject()
        #expect(throws: RotationDebtLedger.Error.entryNotFound(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)) {
            try RotationDebtLedger.acknowledge(UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, in: project)
        }
    }

    @Test("save cleans up its staging file")
    func cleansStagingFiles() throws {
        let project = try makeProject()
        try RotationDebtLedger.record(path: "a.yaml", reason: .recipientRemoved, in: project)

        let directory = project.appendingPathComponent(".sops-gui", isDirectory: true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
            .isEmpty)
    }

    @Test("a .sops-gui symlink escape is refused without writing through it")
    func refusesLedgerDirectorySymlink() throws {
        let project = try makeProject()
        let outside = try makeProject()
        let ledgerDirectory = project.appendingPathComponent(".sops-gui")
        try FileManager.default.createSymbolicLink(at: ledgerDirectory, withDestinationURL: outside)

        #expect(throws: RotationDebtLedger.Error.pathEscapesProject) {
            try RotationDebtLedger.record(path: "a.yaml", reason: .recipientRemoved, in: project)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("rotation-debt.json").path))
    }

    @Test("a save refuses to overwrite a ledger changed after it was observed")
    func refusesSecondWriter() throws {
        let project = try makeProject()
        try RotationDebtLedger.record(path: "a.yaml", reason: .recipientRemoved, in: project)
        let file = RotationDebtLedger.fileURL(in: project)
        let observed = try RotationDebtLedger.expectedState(in: project)

        // `expecting: nil` — this write *is* the second writer the assertion
        // below is about, so it deliberately takes no expectation of its own.
        try AtomicFileWriter.write(
            try JSONEncoder().encode([RotationDebtEntry(path: "external.yaml", reason: .plaintextCommitted)]),
            to: file, expecting: nil)

        #expect(throws: RotationDebtLedger.Error.changedOnDisk) {
            try RotationDebtLedger.save(
                [RotationDebtEntry(path: "b.yaml", reason: .recipientRemoved)], in: project, expecting: observed)
        }
    }
}
