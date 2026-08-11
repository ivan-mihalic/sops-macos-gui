import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixtures

private struct ConfirmationFixtureError: Error, CustomStringConvertible {
    let description: String
}

private struct ConfirmationAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> ConfirmationAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ConfirmationFixtureError(description: "age-keygen not found in \(candidates)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw ConfirmationFixtureError(description: "age-keygen produced no usable key pair")
        }
        return ConfirmationAgeKeyPair(private: priv, public: pub)
    }
}

private func confirmationScratchDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let confirmationPlainYAML = "database:\n    password: correct-horse-battery-staple\n"

/// A project with one encrypted file, so a gated apply needs exactly one
/// release to finish.
private func makeSingleFileProject(
    owner: ConfirmationAgeKeyPair, label: String = "project-access-confirm"
) throws -> URL {
    let root = try confirmationScratchDirectory(label)
    try """
        creation_rules:
          - path_regex: .*\\.yaml$
            age:
              - \(owner.public)

        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
    try SopsBridge.encryptYAML(confirmationPlainYAML, recipients: [owner.public])
        .write(to: root.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)
    return root
}

// MARK: - D3

/// D3. Of this panel's three mutating actions, "Update .sops.yaml" was the only
/// one whose confirmation named nobody: it described the reformatting a rewrite
/// causes and said files on disk are untouched, but never who the rewritten rule
/// would start — or stop — encrypting new files for. Rewriting a creation rule
/// genuinely does not change access to existing files, which is why it was left;
/// the asymmetry inside one feature is its own defect.
@Suite("ProjectAccessView — the config-update confirmation says who changes")
@MainActor
struct ProjectAccessConfigConfirmationTests {

    @Test("an addition is named, with the label the registry knows it by")
    func additionsAreNamed() async throws {
        let owner = try ConfirmationAgeKeyPair.generate()
        let added = try ConfirmationAgeKeyPair.generate()
        let root = try makeSingleFileProject(owner: owner)
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Build server", kind: .server, ageRecipient: added.public), in: root)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        model.stageAdd(added.public)

        let view = ProjectAccessView(model: model, onClose: {}, onFilesApplied: {})
        let message = view.configUpdateConfirmationMessage
        #expect(message.contains(String(format: LocalizedKey.projectAccessConfigGains.text, "Build server")))
        #expect(!message.contains(added.public), "a labelled recipient is named by its label")
        // The mechanical disclosure it already carried has to survive.
        #expect(message.contains(LocalizedKey.projectAccessUpdateConfigConfirmMessage.text))
    }

    @Test("a removal is named, and the message says it revokes nothing")
    func removalsAreNamed() async throws {
        let owner = try ConfirmationAgeKeyPair.generate()
        let leaving = try ConfirmationAgeKeyPair.generate()
        let root = try confirmationScratchDirectory("project-access-confirm-removal")
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age:
                  - \(owner.public)
                  - \(leaving.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        try SopsBridge.encryptYAML(confirmationPlainYAML, recipients: [owner.public, leaving.public])
            .write(to: root.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        try #require(model.configRecipients.count == 2)
        model.stageRemove(leaving.public)

        let view = ProjectAccessView(model: model, onClose: {}, onFilesApplied: {})
        let message = view.configUpdateConfirmationMessage
        #expect(message.contains(String(format: LocalizedKey.projectAccessConfigLoses.text, leaving.public)))
    }

    // The *wording* of the removal sentence — that it scopes itself to new
    // files and says existing ones keep their access — is asserted in
    // `LocalizationTests` against the catalog JSON, for the reason that file's
    // header gives: plain `swift test` copies the catalog uncompiled, so
    // `LocalizedKey.text` here is the raw key and an English assertion would
    // pass or fail for reasons unrelated to the string.

    @Test("a config update that adds and removes nobody names nobody")
    func noChangeNamesNobody() async throws {
        let owner = try ConfirmationAgeKeyPair.generate()
        let root = try makeSingleFileProject(owner: owner, label: "project-access-confirm-nochange")

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        try #require(!model.isDirty)

        let view = ProjectAccessView(model: model, onClose: {}, onFilesApplied: {})
        let message = view.configUpdateConfirmationMessage
        #expect(message == LocalizedKey.projectAccessUpdateConfigConfirmMessage.text,
                "with nothing staged there is no one to name, and an empty sentence is worse than none")
    }
}

// MARK: - D4

/// D4. `SecretEditorView.canOpenAccessPanel` requires `loadState == .loaded`;
/// `ProjectAccessGate.canOpen` has no load-state term at all. That is correct —
/// the project panel is about a project, and there may be no open document — but
/// nothing recorded it, so the next reader meets two gates that disagree and no
/// way to tell a decision from an omission.
@Suite("The two Access gates differ in exactly one way, on purpose")
@MainActor
struct AccessGateAsymmetryTests {

    @Test("the project gate opens without a loaded document; the per-file gate does not")
    func onlyTheLoadStateTermDiffers() {
        #expect(ProjectAccessGate.canOpen(hasProject: true, documentIsDirty: false, documentIsSaving: false))
        #expect(!SecretEditorView.canOpenAccessPanel(loadState: .idle, isDirty: false, isSaving: false))

        // And on the unsaved-work terms — the ones that exist to stop the same
        // data loss in both panels — they agree exactly.
        #expect(!ProjectAccessGate.canOpen(hasProject: true, documentIsDirty: true, documentIsSaving: false))
        #expect(!SecretEditorView.canOpenAccessPanel(loadState: .loaded, isDirty: true, isSaving: false))
        #expect(!ProjectAccessGate.canOpen(hasProject: true, documentIsDirty: false, documentIsSaving: true))
        #expect(!SecretEditorView.canOpenAccessPanel(loadState: .loaded, isDirty: false, isSaving: true))
    }

    /// The reason can only live in prose, so what is pinned is that the prose is
    /// there. Same instrument, and the same justification, as
    /// `neitherPanelTrimsOnItsOwn` and `AppShellProjectRootSourceTests`: a fact
    /// about a decision is not reachable from a running test any other way.
    @Test("the reason the project gate has no load-state term is written down")
    func theAsymmetryIsRecorded() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SopsUI/Projects/ProjectAccessView.swift"),
            encoding: .utf8)
        let gate = try #require(source.range(of: "enum ProjectAccessGate"))
        let docComment = String(source[source.startIndex..<gate.lowerBound].suffix(3000))
        #expect(docComment.contains("does not require a loaded document"),
                "ProjectAccessGate must state why it has no load-state term, unlike SecretEditorView.canOpenAccessPanel")
    }
}

// MARK: - D5

/// Holds the *rewrap* — never the load — until the test releases it, so both
/// panels can be walked while an apply is genuinely in flight.
private actor RewrapGate {
    private var arrived = false
    private var released = false
    private var release: CheckedContinuation<Void, Never>?

    func enter() async {
        arrived = true
        if released { return }
        await withCheckedContinuation { release = $0 }
    }

    func hasArrived() -> Bool { arrived }

    func releaseNow() {
        released = true
        release?.resume()
        release = nil
    }
}

/// D5. `LocalizationTests` proved the two "applying…" strings exist and resolve;
/// nothing proved either is *on the spinner* while an apply runs. The prior
/// reviewer accepted the ROI argument but distinguished this from the
/// confirmation dialogs, which are untestable for want of a window server —
/// this one is testable, because both models already take a seam that can be
/// held open.
@Suite("The in-flight spinner announces itself, in both panels")
@MainActor
struct ApplyingSpinnerAccessibilityTests {

    private func labels(in nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    @Test("the per-file panel's spinner carries its accessibility label while apply runs")
    func filePanelSpinnerIsLabelled() async throws {
        let owner = try ConfirmationAgeKeyPair.generate()
        let added = try ConfirmationAgeKeyPair.generate()
        let root = try confirmationScratchDirectory("access-spinner")
        let file = root.appendingPathComponent("a.yaml")
        try SopsBridge.encryptYAML(confirmationPlainYAML, recipients: [owner.public])
            .write(to: file, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let gate = RewrapGate()
        let model = RecipientAccessModel(
            fileURL: file, projectURL: nil, keyStore: keyStore,
            rewrapRecipients: { contents, recipients, key in
                await gate.enter()
                return try SopsBridge.updateRecipients(contents, to: recipients, agePrivateKey: key)
            })

        let host = GatingHost(size: CGSize(width: 460, height: 520)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })
        model.stageAdd(added.public)

        let applying = Task { await model.apply() }
        await host.settle(until: { model.isApplying })
        try #require(model.isApplying, "the apply never started — this test would be vacuous")

        let inFlight = labels(in: host.nodes())
        #expect(inFlight.contains(LocalizedKey.accessApplyingLabel.text),
                "a bare ProgressView announces nothing to VoiceOver")
        #expect(!inFlight.contains(LocalizedKey.accessApplyButton.text),
                "the Apply button is replaced by the spinner, so this is really the in-flight state")

        await gate.releaseNow()
        #expect(await applying.value == .applied)
        await host.settle(until: { !model.isApplying })
        #expect(!labels(in: host.nodes()).contains(LocalizedKey.accessApplyingLabel.text),
                "the label must go away with the spinner")
    }

    @Test("the project panel's spinner carries its accessibility label while the run is going")
    func projectPanelSpinnerIsLabelled() async throws {
        let owner = try ConfirmationAgeKeyPair.generate()
        let added = try ConfirmationAgeKeyPair.generate()
        let root = try makeSingleFileProject(owner: owner, label: "project-access-spinner")

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        // Blocking, not suspending: `ProjectRecipientApplier` runs each file's
        // work on its own `Thread`, so a wait here never occupies the main actor
        // or a cooperative-pool thread. The `plan` path does not call this seam
        // at all, so loading the panel is unaffected.
        let held = DispatchSemaphore(value: 0)
        let applier = ProjectRecipientApplier(rewrapRecipients: { contents, recipients, key in
            held.wait()
            return try SopsBridge.updateRecipients(contents, to: recipients, agePrivateKey: key)
        })
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore, applier: applier)

        let host = GatingHost(size: CGSize(width: 560, height: 760)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })
        try #require(model.filesToApply.count == 1, "one file, so one release finishes the run")
        model.stageAdd(added.public)

        model.startApplyingToFiles { _ in }
        await host.settle(until: { model.isApplyingFiles })
        try #require(model.isApplyingFiles, "the run never started — this test would be vacuous")

        #expect(labels(in: host.nodes()).contains(LocalizedKey.projectAccessApplyingLabel.text))

        held.signal()
        await host.settle(until: { !model.isApplyingFiles })
        #expect(!labels(in: host.nodes()).contains(LocalizedKey.projectAccessApplyingLabel.text))
    }
}
