import Foundation
import ScratchCleanup
import Testing
@testable import SopsProjects

/// What happens to a `recipients.json` that is on disk but cannot be decoded.
///
/// The question these tests exist to settle: `expectedState(in:)` fingerprints
/// the file's *bytes* (`fingerprint(of:in:)` is a `stat` — device, inode, size,
/// mtime) and never decodes them. A corrupt-but-unchanged registry therefore
/// reports `.existing(fingerprint)`, which is exactly the state a guarded save
/// treats as "nothing moved under me, go ahead". Meanwhile every read site in
/// the UI spells the load `(try? RecipientRegistry.load(in:)) ?? []`, so a
/// caller that cannot decode the file sees an empty directory rather than an
/// error.
///
/// Put together, those two facts describe a way to lose every nickname in the
/// registry without any error surfacing: read as empty, save as guarded, and
/// the guard passes because the bytes genuinely did not change. Whether the
/// app can actually be walked down that path is what is measured here, rather
/// than argued from the two halves.
@Suite("RecipientRegistry — corrupt file on disk")
struct RecipientRegistryCorruptionTests {
    private static let publicKey = "age1l3re6nlra8gmrpxr7j35hnhkyw48sdwawp9gsrsfxkw9jdm3ydxs2fnlh6"

    /// Not truncated JSON but *valid* JSON of the wrong shape — a real
    /// half-written file could be either, and this variant proves the refusal
    /// is about decoding to `[RecipientRecord]`, not about parsing at all.
    private static let corruptBytes = Data(#"{"records": "this is not an array"}"#.utf8)

    private func makeProjectWithCorruptRegistry() throws -> (project: URL, file: URL) {
        let project = FileManager.default.temporaryDirectory
            .appendingPathComponent("registry-corruption-\(UUID().uuidString)", isDirectory: true)
        ScratchDirectoryRegistry.shared.register(project)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let directory = project.appendingPathComponent(".sops-gui", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("recipients.json")
        try Self.corruptBytes.write(to: file)
        return (project, file)
    }

    private func newRecord() -> RecipientRecord {
        RecipientRecord(label: "Laptop", kind: .device, ageRecipient: Self.publicKey)
    }

    @Test("a corrupt registry reads as an empty one, which is what every UI call site sees")
    func loadDegradesToEmpty() throws {
        let (project, _) = try makeProjectWithCorruptRegistry()

        #expect(throws: (any Error).self) { try RecipientRegistry.load(in: project) }

        // The exact spelling used at all six read sites in SopsUI.
        let asTheUISeesIt = (try? RecipientRegistry.load(in: project)) ?? []
        #expect(asTheUISeesIt.isEmpty)
    }

    @Test("the fingerprint a guarded save trusts is taken without decoding the file")
    func expectedStateDoesNotDecode() throws {
        let (project, _) = try makeProjectWithCorruptRegistry()

        // If this threw, the corrupt file could never be blessed as a baseline
        // and the whole concern would be moot. It does not throw: `.existing`
        // is reported for bytes nobody could read.
        let state = try RecipientRegistry.expectedState(in: project)
        guard case .existing = state else {
            Issue.record("expected .existing for a file that is present but undecodable, got \(state)")
            return
        }
    }

    /// The path the app actually takes: `RecipientLabelEditor` reads a baseline
    /// with `expectedState(in:)` (`RecipientLabelEditor.swift:96`) and saves
    /// through `upsert(_:in:expecting:)` (`:99`).
    @Test("the app's own write path refuses to overwrite a corrupt registry")
    func appWritePathRefuses() throws {
        let (project, file) = try makeProjectWithCorruptRegistry()
        let before = try Data(contentsOf: file)

        let baseline = try RecipientRegistry.expectedState(in: project)
        #expect(throws: (any Error).self) {
            try RecipientRegistry.upsert(newRecord(), in: project, expecting: baseline)
        }

        #expect(try Data(contentsOf: file) == before, "the unreadable registry must still be on disk")
    }

    /// Same question for the other half of the editor's seam
    /// (`RecipientLabelEditor.swift:102` → `remove(_:in:expecting:)`).
    @Test("removing a name from a corrupt registry refuses rather than flattening it")
    func removeRefuses() throws {
        let (project, file) = try makeProjectWithCorruptRegistry()
        let before = try Data(contentsOf: file)

        let baseline = try RecipientRegistry.expectedState(in: project)
        #expect(throws: (any Error).self) {
            try RecipientRegistry.remove(UUID(), in: project, expecting: baseline)
        }

        #expect(try Data(contentsOf: file) == before, "the unreadable registry must still be on disk")
    }

    /// `save(_:in:)` takes its own baseline from `expectedState(in:)` and never
    /// consults what is in the file. Nothing in `SopsUI` calls it today — the
    /// only caller in the package is `SnapshotTool/Fixtures.swift:851` — so
    /// this is a latent edge rather than a reachable defect. It is pinned here
    /// so that a future caller wiring itself to this overload after a
    /// `(try? load) ?? []` read is a decision someone made against a stated
    /// behaviour, not one they discovered afterwards.
    @Test("the unguarded save overload replaces a corrupt registry without complaint")
    func unguardedSaveOverwrites() throws {
        let (project, file) = try makeProjectWithCorruptRegistry()

        try RecipientRegistry.save([newRecord()], in: project)

        let after = try Data(contentsOf: file)
        #expect(after != Self.corruptBytes)
        let survivors = try RecipientRegistry.load(in: project)
        #expect(survivors.count == 1, "the corrupt contents are gone, replaced by what the caller had")
    }
}
