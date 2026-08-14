import Foundation
import ScratchCleanup
import Testing
@testable import SopsProjects

/// Ticket #24 claim 2. `ProjectRecipientApplier.RunResult`/`FileResult` used
/// to exist only in memory and via `onFileFinished` — nothing about a
/// project-wide run survived closing the panel. `RunRecordStore` is where it
/// lands: `.sops-gui/local/last-apply.json`, overwritten each run.
///
/// ## Why `local/`, and why it is gitignored, not just placed in `.sops-gui/`
///
/// `.sops-gui/recipients.json` is deliberately versioned team metadata —
/// `RecipientRegistry`'s own doc comment says "a shared directory of
/// labels", and `docs/GUIDE.md` tells users to commit it. A run record is a
/// different kind of fact: it names no access decision, only "what happened
/// on this machine, just now" — and unlike a label, which changes rarely, a
/// record like this changes on every apply. Landing it next to
/// `recipients.json` would mean every teammate's local runs generate git
/// diffs and merge conflicts in a directory the project's actual README
/// tells people to commit. `local/` is a subdirectory this store owns
/// exclusively, and it writes that subdirectory's own `.gitignore` (`*`) the
/// first time it is used — contained entirely inside `.sops-gui/`, which the
/// app already creates and owns, rather than touching the project's own
/// top-level `.gitignore` the way no other feature in this app does either.
@Suite("RunRecordStore")
struct RunRecordStoreTests {

    private func makeProject() throws -> URL {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("run-record-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    private func sampleRecord() -> RunRecord {
        RunRecord(
            startedAt: Date(timeIntervalSince1970: 1_000),
            finishedAt: Date(timeIntervalSince1970: 1_010),
            recipients: ["age1exampleexampleexampleexampleexampleexampleexampleexamplex"],
            results: [
                RunRecord.FileEntry(path: "a.yaml", outcome: .updated),
                RunRecord.FileEntry(path: "b.yaml", outcome: .unchanged),
                RunRecord.FileEntry(path: "c.yaml", outcome: .failed, failureReason: "could not be read"),
            ],
            notAttempted: ["d.yaml"])
    }

    @Test("a saved record round-trips exactly")
    func roundTrips() throws {
        let project = try makeProject()
        let record = sampleRecord()

        try RunRecordStore.save(record, in: project)

        #expect(try RunRecordStore.load(in: project) == record)
    }

    @Test("a project with no prior run reports nothing, not an error")
    func absentRecordIsNilNotAnError() throws {
        let project = try makeProject()
        #expect(try RunRecordStore.load(in: project) == nil)
    }

    @Test("a second save overwrites the first — this is a last-run snapshot, not a growing log")
    func secondSaveOverwritesTheFirst() throws {
        let project = try makeProject()
        try RunRecordStore.save(sampleRecord(), in: project)

        let second = RunRecord(
            startedAt: Date(timeIntervalSince1970: 2_000), finishedAt: Date(timeIntervalSince1970: 2_001),
            recipients: [], results: [], notAttempted: [])
        try RunRecordStore.save(second, in: project)

        #expect(try RunRecordStore.load(in: project) == second)
    }

    @Test("wasCancelled reflects whether any file was left not-attempted")
    func wasCancelledReflectsNotAttempted() {
        #expect(sampleRecord().wasCancelled)
        let completed = RunRecord(
            startedAt: Date(), finishedAt: Date(), recipients: [],
            results: [RunRecord.FileEntry(path: "a.yaml", outcome: .updated)], notAttempted: [])
        #expect(!completed.wasCancelled)
    }

    @Test("saving creates .sops-gui/local/.gitignore excluding everything under it")
    func savingWritesAGitignoreForTheLocalDirectory() throws {
        let project = try makeProject()
        try RunRecordStore.save(sampleRecord(), in: project)

        let gitignore = project.appendingPathComponent(".sops-gui/local/.gitignore")
        let contents = try String(contentsOf: gitignore, encoding: .utf8)
        #expect(contents.trimmingCharacters(in: .whitespacesAndNewlines) == "*")
    }

    @Test("the record lives under .sops-gui/local, never directly in .sops-gui")
    func recordIsNotAtTheSharedRegistryLevel() throws {
        let project = try makeProject()
        try RunRecordStore.save(sampleRecord(), in: project)

        #expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".sops-gui/last-apply.json").path))
        #expect(FileManager.default.fileExists(
            atPath: project.appendingPathComponent(".sops-gui/local/last-apply.json").path))
    }
}
