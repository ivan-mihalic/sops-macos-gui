import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing
@testable import SopsUI

/// Two ways a file on disk used to get past the reader, both ending in silent
/// destruction of the user's secrets.
@Suite("A file this app cannot read whole is refused, not half-shown")
@MainActor
struct HostileFileRefusalTests {

    private func model(reading contents: String,
                       fingerprint: @escaping @Sendable (URL) -> FileFingerprint? = { _ in nil },
                       url: URL = URL(fileURLWithPath: "/dev/null/hostile.yaml"))
        -> SecretDocumentViewModel {
        SecretDocumentViewModel(
            fileURL: url, keyStore: SessionKeyStore(),
            readFile: { _ in contents }, fingerprintFile: fingerprint)
    }

    /// A raw NUL is valid UTF-8, so it survives the read and then ends the
    /// argument at the C boundary — everything after it is gone. Two complete,
    /// individually valid SOPS documents joined by one NUL opened showing only
    /// the first, and the next save wrote back what was shown, deleting the
    /// second document's secrets permanently. The real `sops` CLI refuses the
    /// same file.
    @Test("a document carrying a NUL byte is refused rather than truncated")
    func nulBearingDocumentIsRefused() async {
        let model = model(reading: "alpha: one\n\u{0}beta: two\n")
        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("a NUL-truncated document was opened as \(model.loadState)")
            return
        }
        #expect(message.contains("NUL"), "the refusal does not say what is wrong: \(message)")
        #expect(model.rows.isEmpty, "rows were built from a document read only up to its first NUL")
    }

    @Test("an ordinary document is unaffected")
    func ordinaryDocumentStillLoads() async {
        let model = model(reading: "not a sops file\n")
        await model.load()
        if case .failed(let message) = model.loadState {
            #expect(!message.contains("NUL"), "an ordinary document was refused as NUL-bearing")
        }
    }

    /// `FileFingerprint.of` answers `nil` for anything that is not a regular
    /// file, and the fingerprint and the read are separate syscalls — so a
    /// symlink flipped between them yields a successful load with no
    /// fingerprint, and the save then resolves the link and overwrites whatever
    /// it points at now, reporting success.
    @Test("a load that produced no fingerprint for a file that is there is refused")
    func absentFingerprintOverExistingFileIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hostile-\(UUID().uuidString)")
        ScratchDirectoryRegistry.shared.register(directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("secrets.yaml")
        try "alpha: one\n".write(to: path, atomically: true, encoding: .utf8)

        let model = model(reading: "alpha: one\n", fingerprint: { _ in nil }, url: path)
        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("a load with no fingerprint over an existing file produced \(model.loadState)")
            return
        }
        #expect(message.contains("changed while it was being opened"),
                "the refusal does not explain what happened: \(message)")
    }

    /// A file that genuinely is not there must still report as unreadable in
    /// the ordinary way, not as a race.
    @Test("a missing file is not reported as a race")
    func missingFileIsNotARace() async {
        let model = model(reading: "alpha: one\n", fingerprint: { _ in nil })
        await model.load()
        if case .failed(let message) = model.loadState {
            #expect(!message.contains("changed while it was being opened"),
                    "a file that does not exist was reported as having changed under us")
        }
    }
}
