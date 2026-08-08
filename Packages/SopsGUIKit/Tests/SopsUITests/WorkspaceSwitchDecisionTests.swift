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
                from: Self.fileA, to: Self.fileB, documentIsDirty: true, saveIsInFlight: false)
                == .askAboutUnsavedChanges)
    }

    @Test("switching files with nothing unsaved just switches")
    func cleanFileSwitchProceeds() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileB, documentIsDirty: false, saveIsInFlight: false)
                == .proceed)
    }

    /// Re-clicking the row that is already open is not leaving it. Prompting
    /// there would teach the user to dismiss the prompt that matters.
    @Test("re-selecting the open file never prompts, even with unsaved changes")
    func reselectingTheOpenFileIsNotASwitch() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileA, documentIsDirty: true, saveIsInFlight: false)
                == .alreadyThere)
    }

    @Test("opening the first file when nothing is open just opens it")
    func openingFromNothingProceeds() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: URL?.none, to: Self.fileA, documentIsDirty: false, saveIsInFlight: false)
                == .proceed)
    }

    /// Closing is leaving too — `FileListView` can write `nil` into the
    /// selection binding, and a dirty document must not evaporate on it.
    @Test("closing a dirty document asks first")
    func closingADirtyDocumentAsks() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: URL?.none, documentIsDirty: true, saveIsInFlight: false)
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
            WorkspaceSwitchDecision.forSwitch(from: a, to: b, documentIsDirty: true, saveIsInFlight: false)
                == .askAboutUnsavedChanges)
    }

    @Test("switching projects with nothing unsaved just switches")
    func cleanProjectSwitchProceeds() {
        let a = StoredProject.ID(), b = StoredProject.ID()
        #expect(
            WorkspaceSwitchDecision.forSwitch(from: a, to: b, documentIsDirty: false, saveIsInFlight: false)
                == .proceed)
    }

    @Test("re-selecting the open project never prompts")
    func reselectingTheOpenProjectIsNotASwitch() {
        let a = StoredProject.ID()
        #expect(
            WorkspaceSwitchDecision.forSwitch(from: a, to: a, documentIsDirty: true, saveIsInFlight: false)
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
    private func loadedDocument(observedBy observer: SaveObserver? = nil) async throws
        -> SecretDocumentViewModel
    {
        let fixture = try #require(sharedFixture, "the shared sops fixture could not be built")
        let model = try await MainActor.run {
            let store = SessionKeyStore()
            try store.importKey(fixture.privateKey)
            let model = SecretDocumentViewModel(
                fileURL: WorkspaceSwitchDecisionTests.fileA,
                keyStore: store, readFile: { _ in fixture.encrypted },
                // No expectation to check, and nothing on disk to check it
                // against: these fixtures never touch the filesystem.
                fingerprintFile: { _ in nil },
                writeFile: { contents, _, _ in
                    observer?.write(contents)
                    return nil
                })
            observer?.model = model
            return model
        }
        await model.load()
        #expect(await model.loadState == .loaded, "the fixture document did not decrypt")
        return model
    }

    private func decision(forSwitchingAwayFrom model: SecretDocumentViewModel) async
        -> WorkspaceSwitchDecision
    {
        // Exactly what `ProjectWorkspaceView.requestFileSwitch(to:)` computes —
        // both inputs read off the same model, not one of them hardcoded here.
        await WorkspaceSwitchDecision.forSwitch(
            from: Self.fileA, to: Self.fileB,
            documentIsDirty: model.isDirty, saveIsInFlight: model.isSaving)
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

    // MARK: - A save in flight

    // The window is 133–380 ms wide, measured, and the file list and sidebar
    // used to stay live across it. Inside it the ordinary unsaved-changes
    // prompt had two answers and both were wrong: "Save and continue" called
    // `save()`, which refuses a re-entrant save, so the user got a save-failed
    // alert while the save was succeeding; "Discard changes" tore the editor
    // down while the `Task` running the save kept the document alive and wrote
    // the discarded changes to disk.

    @Test("a save in flight is its own answer, not the unsaved-changes prompt")
    func saveInFlightWaits() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileB, documentIsDirty: true, saveIsInFlight: true)
                == .waitForSaveInFlight)
    }

    /// `isDirty` clears only when the saved document is adopted, so in practice
    /// a save in flight is always dirty too. Pinned on its own anyway: the
    /// answer must come from the save, not from the two happening to coincide.
    @Test("a save in flight outranks a clean document")
    func saveInFlightOutranksClean() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileB, documentIsDirty: false, saveIsInFlight: true)
                == .waitForSaveInFlight)
    }

    /// Re-clicking the open row is still not leaving it, save or no save.
    /// Making a user wait for a switch that is not a switch would be a new way
    /// of being wrong about the same window.
    @Test("re-selecting the open file during a save is still not a switch")
    func reselectingDuringASaveIsNotASwitch() {
        #expect(
            WorkspaceSwitchDecision.forSwitch(
                from: Self.fileA, to: Self.fileA, documentIsDirty: true, saveIsInFlight: true)
                == .alreadyThere)
    }

    /// The same thing again, but against a **real save actually in flight** —
    /// a real age identity, a real sops encrypt, and the decision computed
    /// from the live model exactly as `ProjectWorkspaceView` computes it. The
    /// three cases above would pass over a `saveIsInFlight` nothing ever sets;
    /// this is the one that says the flag is true when it matters.
    ///
    /// Observed from *inside* the save rather than by racing it from outside.
    /// `writeFile` is called on the main actor from within `save()`, with
    /// `isSaving` set — so this is the mid-save moment itself, not a poll that
    /// hopes to land in it. The first version did poll, and on this fixture
    /// (five keys, an encrypt in single-digit milliseconds) it missed the
    /// window every time: a test that has to be lucky to see the bug is a test
    /// that will one day be unlucky about the fix.
    @Test("a real, in-flight save produces the wait decision from the live model")
    func realInFlightSaveIsSeenByTheDecision() async throws {
        let observer = await SaveObserver()
        let model = try await loadedDocument(observedBy: observer)
        try await MainActor.run {
            let row = try #require(model.rows.first { $0.path == ["db", "password"] })
            model.update(rowID: row.id, to: "rotated-EXAMPLE-value")
            observer.duringWrite = { model in
                WorkspaceSwitchDecision.forSwitch(
                    from: WorkspaceSwitchDecisionTests.fileA,
                    to: WorkspaceSwitchDecisionTests.fileB,
                    documentIsDirty: model.isDirty, saveIsInFlight: model.isSaving)
            }
        }
        #expect(await decision(forSwitchingAwayFrom: model) == .askAboutUnsavedChanges)

        #expect(await model.save() == .saved)

        #expect(await observer.contents != nil, "the fixture save never reached the writer")
        #expect(
            await observer.observedDecision == .waitForSaveInFlight,
            "a switch requested mid-save must neither prompt nor proceed")
        // And once it lands the question is asked again, against a document
        // that has settled — which is the whole point of waiting rather than
        // refusing: the user's click is honoured, just late.
        #expect(await decision(forSwitchingAwayFrom: model) == .proceed)
    }

    /// What the workspace waits on. Polling `isSaving` from a view would be
    /// the obvious alternative and a worse one; this is the seam that makes
    /// the deferred switch a suspension instead of a loop.
    ///
    /// The waiter is started from inside `writeFile`, i.e. from within the
    /// save, so there is no window to miss: it is guaranteed to suspend, and
    /// what is asserted is that it comes back at all and comes back *after*
    /// the save is done.
    @Test("awaitSaveInFlight suspends inside a save and returns once it has finished")
    func awaitSaveInFlightWaitsForTheSave() async throws {
        let observer = await SaveObserver()
        let model = try await loadedDocument(observedBy: observer)
        try await MainActor.run {
            let row = try #require(model.rows.first { $0.path == ["db", "password"] })
            model.update(rowID: row.id, to: "rotated-again-EXAMPLE-value")
            observer.startWaiterDuringWrite = true
        }

        #expect(await model.save() == .saved)

        let waiter = try #require(await observer.waiter, "no waiter was started inside the save")
        let resumedWhileStillSaving = await waiter.value
        #expect(
            resumedWhileStillSaving == false,
            "the wait returned while the save was still in flight")
    }

    /// With no save in flight it must not suspend at all — a workspace that
    /// hung here would never switch files again. This test hanging *is* the
    /// failure; there is nothing more to assert.
    @Test("awaitSaveInFlight returns immediately when nothing is saving")
    func awaitSaveInFlightIsANoOpWhenIdle() async throws {
        let model = try await loadedDocument()
        await model.awaitSaveInFlight()
        #expect(await !model.isSaving)
    }
}

/// A window into the middle of a save.
///
/// `SecretDocumentViewModel.writeFile` is the last thing a save does, on the
/// main actor, with `isSaving` still set — the only place a test can stand
/// inside the 133–380 ms window deterministically instead of trying to catch
/// it from outside. It also keeps the saved bytes out of the filesystem: this
/// suite's `fileA`/`fileB` are `/tmp/project/…` paths that do not exist, and a
/// decision test has no business creating them.
@MainActor
final class SaveObserver {
    /// Set by `loadedDocument` right after construction, because the write
    /// closure has to be handed to the initializer that produces the model it
    /// wants to ask about.
    var model: SecretDocumentViewModel?
    var contents: String?

    /// Evaluated during the write, against the live model.
    var duringWrite: ((SecretDocumentViewModel) -> WorkspaceSwitchDecision)?
    private(set) var observedDecision: WorkspaceSwitchDecision?

    /// Whether to start an `awaitSaveInFlight()` waiter from inside the write.
    /// Its value is `isSaving` *as the waiter saw it on resuming* — `false` is
    /// the passing answer.
    var startWaiterDuringWrite = false
    private(set) var waiter: Task<Bool, Never>?

    func write(_ contents: String) {
        self.contents = contents
        if let model, let duringWrite {
            observedDecision = duringWrite(model)
        }
        if startWaiterDuringWrite, let model {
            waiter = Task { @MainActor in
                await model.awaitSaveInFlight()
                return model.isSaving
            }
        }
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
