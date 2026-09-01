import Foundation
import SopsEngine
import SopsProjects
import Testing
@testable import SopsUI

/// A save that failed must leave the document dirty.
///
/// Mutation-verified as unguarded: adding `isDirty = false` to `save()`'s
/// failure branch left all 658 tests green. The consequence is not a cosmetic
/// dot — `UnsavedChangesTracker` reads `isDirty`, and `QuitRequest` reads the
/// tracker, so a clean-looking failed save means ⌘Q closes the app without
/// asking and the edits are gone. Everything `QuitRequest` exists for depends
/// on this one flag being honest about a failure.
@Suite("A failed save leaves the changes pending")
@MainActor
struct SaveFailureKeepsChangesTests {

    private struct WriteRefused: Swift.Error {}

    private func loadedModel(writeFile: @escaping @Sendable (String, URL, FileFingerprint?) throws -> FileFingerprint?)
        throws -> SecretDocumentViewModel {
        let key = try AgeKeyPairForTests.generate()
        let encrypted = try SopsBridge.encrypt(
            "db:\n    password: fixture-value-alpha\n    port: 5432\n", format: .yaml, recipients: [key.public])
        let store = SessionKeyStore()
        try store.importKey(key.private)
        return SecretDocumentViewModel(
            fileURL: URL(fileURLWithPath: "/dev/null/save-failure.yaml"),
            format: .yaml,
            keyStore: store,
            readFile: { _ in encrypted },
            writeFile: writeFile)
    }

    @Test("a write that fails leaves the document dirty")
    func failedWriteKeepsTheDocumentDirty() async throws {
        let model = try loadedModel(writeFile: { _, _, _ in throw WriteRefused() })
        await model.load()
        let firstRow = try #require(model.rows.first).id
        model.update(rowID: firstRow, to: "rotated-EXAMPLE")
        try #require(model.isDirty, "precondition: the edit made the document dirty")

        let outcome = await model.save()

        guard case .failed = outcome else {
            Issue.record("expected the save to fail; got \(outcome)")
            return
        }
        #expect(model.isDirty,
                "a failed save reported the document as clean, so ⌘Q would close without asking and lose the edit")
    }

    /// The **other** failure branch, and the one a mutation showed unguarded:
    /// the bridge refusing the change set, as opposed to the write throwing.
    /// Two branches, two `return .failed(...)`, and only one of them was
    /// reachable from any test.
    @Test("a change set the bridge refuses leaves the document dirty")
    func refusedChangeSetKeepsTheDocumentDirty() async throws {
        let model = try loadedModel(writeFile: { _, _, _ in
            Issue.record("the write should never be reached — the bridge refuses first")
            return nil
        })
        await model.load()
        let intRow = try #require(model.rows.first { $0.path == ["db", "port"] })
        try #require(intRow.kind == .int, "precondition: the row is typed as a number")
        model.update(rowID: intRow.id, to: "not-a-number")
        try #require(model.isDirty)

        let outcome = await model.save()

        guard case .failed = outcome else {
            Issue.record("expected the bridge to refuse; got \(outcome)")
            return
        }
        #expect(model.isDirty,
                "a refused save reported the document as clean, so ⌘Q would close without asking")
    }

    /// The other half, so the fix cannot be "always dirty".
    @Test("a write that succeeds leaves the document clean")
    func successfulWriteClearsTheFlag() async throws {
        let model = try loadedModel(writeFile: { _, _, _ in nil })
        await model.load()
        let firstRow = try #require(model.rows.first).id
        model.update(rowID: firstRow, to: "rotated-EXAMPLE")

        let outcome = await model.save()

        #expect(outcome == .saved, "precondition: the save succeeded")
        #expect(!model.isDirty, "a successful save left the document dirty")
    }
}

/// A throwaway age identity. Duplicated rather than shared because the helper
/// that already does this lives in a `private` type in another file.
struct AgeKeyPairForTests {
    let `private`: String
    let `public`: String

    static func generate() throws -> AgeKeyPairForTests {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("AGE-SECRET-KEY-") { priv = String(line) }
            if line.hasPrefix("# public key: ") { pub = String(line.dropFirst("# public key: ".count)) }
        }
        struct Failure: Swift.Error {}
        guard !priv.isEmpty, !pub.isEmpty else { throw Failure() }
        return AgeKeyPairForTests(private: priv, public: pub)
    }
}
