import Foundation
import SopsEngine
import SopsProjects
import Testing
@testable import SopsUI

/// "Edit a value, switch files without saving — is the prompt actually
/// shown?"
///
/// Task 12 could only answer that by reading `ProjectWorkspaceView`, a
/// `private struct` whose prompt is a `.confirmationDialog`: unreachable from
/// a unit test and invisible to `Scripts/snapshots.sh`. `WorkspaceSwitchDecision`
/// exists so the answer is a value a test can ask for. What that view still
/// owns is only the acting-on: `.proceed` → activate, `.askAboutUnsavedChanges`
/// → set `pendingSwitch`, which is what presents the dialog.
///
/// The second half of the file drives a **real, decrypted document** through
/// each of the three ways it can become dirty, and feeds its own `isDirty`
/// into the decision. Task 8b added rows and removals after the prompt was
/// written; a dirty check that only noticed edited values would send a user
/// who added a key straight past the warning, and nothing before this looked.
///
/// ## Two concessions to the rest of the suite, both measured
/// Not `@MainActor` at the suite level, for the reason
/// `AccessibilityTreeTests`' doc comment sets out: the fixture work here is a
/// real `age-keygen` subprocess plus a real `sops` encrypt, and holding the
/// main actor across those starves `ClipboardClearingTests`' 50ms clear timer,
/// which runs concurrently.
///
/// And `.serialized`, over a **single shared ciphertext** (`sharedFixture`)
/// rather than a fresh key and encrypt per test. The first version did it per
/// test — five `age-keygen` subprocesses and five in-process encrypts, all
/// started at once — and that alone was enough to push
/// `ClipboardClearingTests.pasteboardClearsAfterInterval` from 0 failures in 4
/// baseline runs of bare `swift test` to 2 in 4. The document is read-only
/// input; every test still builds its **own** `SecretDocumentViewModel` over
/// it, so nothing is shared that any test can mutate.
@Suite("the unsaved-changes decision", .serialized)
struct WorkspaceSwitchDecisionTests {

    // MARK: - Switching files

    private static let fileA = URL(fileURLWithPath: "/tmp/project/a.secrets.yaml")
    private static let fileB = URL(fileURLWithPath: "/tmp/project/b.secrets.yaml")

    /// The property the milestone is about: an unsaved edit is never
    /// abandoned silently.
    @Test("switching files with unsaved changes asks first")
    func dirtyFileSwitchAsks() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileB, documentIsDirty: true)
                == .askAboutUnsavedChanges)
    }

    @Test("switching files with nothing unsaved just switches")
    func cleanFileSwitchProceeds() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileB, documentIsDirty: false)
                == .proceed)
    }

    /// Re-clicking the row that is already open is not leaving it. Prompting
    /// there would teach the user to dismiss the prompt that matters.
    @Test("re-selecting the open file never prompts, even with unsaved changes")
    func reselectingTheOpenFileIsNotASwitch() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileA, documentIsDirty: true)
                == .alreadyThere)
    }

    @Test("opening the first file when nothing is open just opens it")
    func openingFromNothingProceeds() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: URL?.none, to: Self.fileA, documentIsDirty: false)
                == .proceed)
    }

    /// Closing is leaving too — `FileListView` can write `nil` into the
    /// selection binding, and a dirty document must not evaporate on it.
    @Test("closing a dirty document asks first")
    func closingADirtyDocumentAsks() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: URL?.none, documentIsDirty: true)
                == .askAboutUnsavedChanges)
    }

    // MARK: - Switching projects

    // Same three answers, reached through the other target type — a project
    // switch tears the open document down exactly as a file switch does, and
    // `ProjectWorkspaceView`'s doc comment says so.

    @Test("switching projects with unsaved changes asks first")
    func dirtyProjectSwitchAsks() {
        let a = StoredProject.ID(), b = StoredProject.ID()
        #expect(
            WorkspaceSwitchDecision.forSwitch(from: a, to: b, documentIsDirty: true)
                == .askAboutUnsavedChanges)
    }

    @Test("switching projects with nothing unsaved just switches")
    func cleanProjectSwitchProceeds() {
        let a = StoredProject.ID(), b = StoredProject.ID()
        #expect(
            WorkspaceSwitchDecision.forSwitch(from: a, to: b, documentIsDirty: false)
                == .proceed)
    }

    @Test("re-selecting the open project never prompts")
    func reselectingTheOpenProjectIsNotASwitch() {
        let a = StoredProject.ID()
        #expect(
            WorkspaceSwitchDecision.forSwitch(from: a, to: a, documentIsDirty: true)
                == .alreadyThere)
    }

    // MARK: - What the workspace actually feeds it

    /// The document behind these: three top-level keys and a two-entry list,
    /// so there is something to edit, something to remove, and somewhere to
    /// add.
    // `fileprivate`, not `private`: `sharedFixture` at the bottom of this
    // file encrypts it, and a file-scope global is outside this type.
    fileprivate static let plaintext = """
        db:
            host: db.internal.example
            password: correct-horse-battery-staple-EXAMPLE
        feature_flags:
            - beta_checkout
            - dark_mode
        """

    /// A loaded `SecretDocumentViewModel` over real sops ciphertext and a
    /// real age identity — one identity and one encrypt for the whole suite,
    /// per its doc comment. Neither ever touches the main actor.
    private func loadedDocument() async throws -> SecretDocumentViewModel {
        let fixture = try #require(sharedFixture, "the shared sops fixture could not be built")
        let model = try await MainActor.run {
            let store = SessionKeyStore()
            try store.importKey(fixture.privateKey)
            return SecretDocumentViewModel(
                fileURL: WorkspaceSwitchDecisionTests.fileA,
                keyStore: store, readFile: { _ in fixture.encrypted })
        }
        await model.load()
        #expect(await model.loadState == .loaded, "the fixture document did not decrypt")
        return model
    }

    private func decision(forSwitchingAwayFrom model: SecretDocumentViewModel) async
        -> WorkspaceSwitchDecision
    {
        // Exactly what `ProjectWorkspaceView.requestFileSwitch(to:)` computes.
        await WorkspaceSwitchDecision.forSwitch(
            from: Self.fileA, to: Self.fileB, documentIsDirty: model.isDirty)
    }

    @Test("a freshly loaded document lets a file switch through")
    func untouchedDocumentProceeds() async throws {
        let model = try await loadedDocument()
        #expect(await decision(forSwitchingAwayFrom: model) == .proceed)
    }

    @Test("an edited value is enough to get the prompt")
    func editedValueAsks() async throws {
        let model = try await loadedDocument()
        try await MainActor.run {
            let row = try #require(model.rows.first { $0.path == ["db", "password"] })
            model.update(rowID: row.id, to: "rotated-EXAMPLE-value")
        }
        #expect(await model.isDirty)
        #expect(await decision(forSwitchingAwayFrom: model) == .askAboutUnsavedChanges)
    }

    /// Task 8b. A user who added a key and switched away must still be
    /// warned — the addition exists only in memory until a save, so losing it
    /// silently loses work exactly as an edited value would.
    @Test("a row added but not saved is enough to get the prompt")
    func addedRowAsks() async throws {
        let model = try await loadedDocument()
        try await MainActor.run {
            let host = try #require(model.rows.first { $0.path == ["db", "host"] })
            let destination = model.addDestination(forSelectedRowID: host.id)
            let outcome = model.addRow(
                in: destination, key: "replica_host", kind: .string,
                value: "db-replica.internal.example")
            #expect(outcome != .refused(.duplicateKey), "the fixture add was refused: \(outcome)")
        }
        #expect(await model.isDirty, "adding a row left the document reading as clean")
        #expect(await decision(forSwitchingAwayFrom: model) == .askAboutUnsavedChanges)
    }

    /// The other half of Task 8b, and the one that costs the most if it is
    /// missed: a removal the user switches away from is a key that quietly
    /// comes back.
    @Test("a row removed but not saved is enough to get the prompt")
    func removedRowAsks() async throws {
        let model = try await loadedDocument()
        try await MainActor.run {
            let flag = try #require(model.rows.first { $0.path == ["feature_flags", "1"] })
            model.removeRow(id: flag.id)
        }
        #expect(await model.isDirty, "removing a row left the document reading as clean")
        #expect(await decision(forSwitchingAwayFrom: model) == .askAboutUnsavedChanges)
    }

    /// The exactness the other direction, so the prompt does not become noise:
    /// adding a row and taking it straight back out again leaves nothing
    /// pending, and a switch after that must not ask.
    @Test("an addition that was undone does not prompt")
    func undoneAdditionProceeds() async throws {
        let model = try await loadedDocument()
        try await MainActor.run {
            let destination = model.addDestination(forSelectedRowID: nil)
            let outcome = model.addRow(
                in: destination, key: "temporary", kind: .string, value: "x")
            guard case .added(let id) = outcome else {
                Issue.record("the fixture add was refused: \(outcome)")
                return
            }
            model.removeRow(id: id)
        }
        #expect(await !model.isDirty)
        #expect(await decision(forSwitchingAwayFrom: model) == .proceed)
    }
}

/// One real age identity and one real sops encrypt of
/// `WorkspaceSwitchDecisionTests.plaintext`, built once for the whole file.
///
/// A `let` at file scope, so Swift's own lazy, once-only global
/// initialization does the work the first time a test asks for it — off the
/// main actor, on whichever thread got there first. `nil` if the fixture
/// could not be built at all, which each test turns into a stated failure
/// rather than a silent skip.
///
/// Immutable and `Sendable`: two strings. Nothing a test does can change what
/// the next one sees.
private struct EncryptedFixture: Sendable {
    let encrypted: String
    let privateKey: String
}

private let sharedFixture: EncryptedFixture? = {
    guard let key = try? SwitchAgeKey.generate(),
          let encrypted = try? SopsBridge.encryptYAML(
            WorkspaceSwitchDecisionTests.plaintext, recipients: [key.public])
    else { return nil }
    return EncryptedFixture(encrypted: encrypted, privateKey: key.private)
}()

/// A throwaway age identity from the real `age-keygen`. Mirrors the same
/// helper in `AccessibilityTreeTests` — duplicated rather than shared because
/// both are file-private by design, and a shared test helper across suites is
/// how one suite's fixture change silently breaks another's.
private struct SwitchAgeKey {
    let `private`: String
    let `public`: String

    static func generate() throws -> SwitchAgeKey {
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
        struct Failure: Error {}
        guard !priv.isEmpty, !pub.isEmpty else { throw Failure() }
        return SwitchAgeKey(private: priv, public: pub)
    }
}
