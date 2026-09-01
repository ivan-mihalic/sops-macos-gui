import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixtures

private struct LabelFixtureError: Error, CustomStringConvertible {
    let description: String
}

private struct LabelAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> LabelAgeKeyPair {
        let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .map { ($0 as NSString).appendingPathComponent("age-keygen") }
        guard let tool = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw LabelFixtureError(description: "age-keygen not found in \(candidates)")
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
            throw LabelFixtureError(description: "age-keygen produced no usable key pair")
        }
        return LabelAgeKeyPair(private: priv, public: pub)
    }
}

private func labelScratchDirectory(_ label: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let labelPlainYAML = "database:\n    password: correct-horse-battery-staple\n"

private func makeLabelProject(owner: LabelAgeKeyPair, label: String = "recipient-label") throws -> URL {
    let root = try labelScratchDirectory(label)
    try """
        creation_rules:
          - path_regex: .*\\.yaml$
            age:
              - \(owner.public)

        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
    try SopsBridge.encrypt(labelPlainYAML, format: .yaml, recipients: [owner.public])
        .write(to: root.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)
    return root
}

// MARK: - The model

@Suite("RecipientLabelEditorModel — naming a key, and only that")
@MainActor
struct RecipientLabelEditorModelTests {

    @Test("naming a recipient the registry has never heard of writes one record")
    func namesANewRecipient() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner)

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: nil)
        #expect(!model.isEditingExistingRecord)
        #expect(!model.canSave, "an empty name is refused before the registry ever sees it")

        model.label = "Alice's laptop"
        model.kind = .device
        model.note = "the 2021 MacBook"
        #expect(model.canSave)
        #expect(await model.save() == .saved)

        let records = try RecipientRegistry.load(in: root)
        #expect(records.count == 1)
        #expect(records.first?.label == "Alice's laptop")
        #expect(records.first?.kind == .device)
        #expect(records.first?.ageRecipient == owner.public)
        #expect(records.first?.note == "the 2021 MacBook")
    }

    @Test("editing an existing label replaces that record rather than adding one")
    func editsInPlace() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-edit")
        let existing = RecipientRecord(label: "Old name", kind: .server, ageRecipient: owner.public)
        try RecipientRegistry.upsert(existing, in: root)

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: existing)
        #expect(model.isEditingExistingRecord)
        #expect(model.label == "Old name")
        #expect(model.kind == .server)

        model.label = "New name"
        #expect(await model.save() == .saved)

        let records = try RecipientRegistry.load(in: root)
        #expect(records.count == 1)
        #expect(records.first?.id == existing.id, "the record keeps its identity")
        #expect(records.first?.label == "New name")
    }

    /// An empty note is absence, not an empty string: a record whose note is
    /// `""` round-trips through JSON as a note the panel would draw as a blank
    /// line.
    @Test("a note left blank is stored as no note at all")
    func blankNoteIsNil() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-note")

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: nil)
        model.label = "Alice"
        model.note = "   "
        #expect(await model.save() == .saved)

        #expect(try RecipientRegistry.load(in: root).first?.note == nil)
    }

    /// The registry is the authority on what it will accept. The editor does not
    /// re-implement its validation; it surfaces the refusal.
    @Test("a private identity pasted into the note is refused, and never echoed")
    func privateIdentityIsRefusedWithoutEchoing() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let leaked = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-private")

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: nil)
        model.label = "Alice"
        model.note = "backup of \(leaked.private)"

        #expect(await model.save() == .refused)
        let message = try #require(model.errorMessage)
        #expect(message == LocalizedKey.recipientEditorErrorPrivateIdentity.text)
        #expect(!message.contains(leaked.private), "a refusal must never echo what it refused")
        #expect(!message.contains("AGE-SECRET-KEY"))
        #expect(try RecipientRegistry.load(in: root).isEmpty)
    }

    @Test("a second record for a key the registry already names is refused")
    func duplicateRecipientIsRefused() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-duplicate")
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Already here", kind: .person, ageRecipient: owner.public), in: root)

        // A *new* record (fresh UUID) for a key that already has one.
        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: nil)
        model.label = "Second name"

        #expect(await model.save() == .refused)
        #expect(model.errorMessage == LocalizedKey.recipientEditorErrorDuplicate.text)
        #expect(try RecipientRegistry.load(in: root).map(\.label) == ["Already here"])
    }

    /// The registry's own second-writer guard, reached through the `expecting:`
    /// overload. A save that would clobber an edit made since the sheet opened is
    /// refused rather than silently winning.
    @Test("a registry rewritten since the sheet opened is refused, not clobbered")
    func aConcurrentEditIsRefused() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let other = try LabelAgeKeyPair.generate()
        let third = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-concurrent")
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Owner", kind: .person, ageRecipient: owner.public), in: root)

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: other.public, existing: nil)
        model.label = "Someone else"

        // Somebody else writes the registry between this sheet's read and its
        // save — `git pull`, the sops CLI, a second window. A different key, so
        // the refusal is the fingerprint guard rather than the duplicate-key
        // validation, which would refuse this for the wrong reason and pass the
        // test without proving anything about clobbering.
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Written by someone else", kind: .server, ageRecipient: third.public),
            in: root)

        #expect(await model.save() == .refused)
        #expect(model.errorMessage == LocalizedKey.recipientEditorErrorChangedOnDisk.text)
        let after = try RecipientRegistry.load(in: root)
        #expect(after.map(\.label).sorted() == ["Owner", "Written by someone else"],
                "the other writer's record survived and ours was not written over it")
    }

    @Test("forgetting a label removes the record and nothing else")
    func forgettingRemovesOnlyTheRecord() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-forget")
        let existing = RecipientRecord(label: "Alice", kind: .person, ageRecipient: owner.public)
        try RecipientRegistry.upsert(existing, in: root)
        let fileBefore = try String(
            contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)
        let configBefore = try String(
            contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: existing)
        #expect(await model.forget() == .saved)

        #expect(try RecipientRegistry.load(in: root).isEmpty)
        // The whole point of the wording: access did not change.
        #expect(try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8) == fileBefore)
        #expect(
            try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
                == configBefore)
        #expect(try SopsBridge.recipients(in: fileBefore, format: .yaml) == [owner.public],
                "the recipient still decrypts the file exactly as before")
    }

    /// Naming is a registry act. It must not read, re-wrap or rewrite anything
    /// encrypted — pinned by counting, not inferred from the bytes afterwards.
    @Test("saving a name never touches an encrypted file or the config")
    func savingTouchesNothingEncrypted() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-untouched")
        let fileBefore = try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)
        let configBefore = try String(
            contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)

        let model = RecipientLabelEditorModel(
            projectURL: root, ageRecipient: owner.public, existing: nil)
        model.label = "Alice"
        #expect(await model.save() == .saved)

        #expect(try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8) == fileBefore)
        #expect(
            try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
                == configBefore)
    }
}

// MARK: - The wording, which is the security question

/// Forgetting a label removes a nickname. It removes nobody's access — the
/// recipient goes on decrypting exactly what they could decrypt before.
///
/// The *wording* of those strings is asserted in `LocalizationTests`, against
/// the catalog JSON rather than resolved text: under plain `swift test` the
/// catalog is copied uncompiled and every `LocalizedKey.text` resolves to its
/// own raw key, so an English-content assertion here would pass or fail for
/// reasons that have nothing to do with the string. What is left here is the one
/// claim that is about code rather than English.
@Suite("Forgetting a label is unmistakably not a revocation")
struct ForgetLabelWordingTests {

    /// Not dressed up as dangerous either. Nothing about forgetting a nickname
    /// warrants a destructive role, and a red button that changes nothing is its
    /// own kind of lie about what the app does.
    @Test("no destructive styling for an operation that changes nothing but a nickname")
    func forgettingIsNotStyledDestructive() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/SopsUI/Support/RecipientLabelEditor.swift"),
            encoding: .utf8)
        #expect(!source.contains("role: .destructive"),
                "forgetting a label is not destructive and must not be styled as if it were")
    }
}

// MARK: - Through the rendered panels

@Suite("Both Access panels offer to name a recipient, from the row")
@MainActor
struct RecipientLabelEditorWiringTests {

    private func labels(in nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    @Test("an unnamed recipient's row offers to name it; a named one offers to edit")
    func theRowOffersTheRightControl() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-wiring")

        let unnamed = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let unnamedHost = GatingHost(size: CGSize(width: 560, height: 760)) {
            AnyView(ProjectAccessView(model: unnamed, onClose: {}, onFilesApplied: {}))
        }
        defer { unnamedHost.finish() }
        await unnamedHost.settle(until: { unnamed.loadState == .loaded })
        let unnamedLabels = labels(in: unnamedHost.nodes())
        #expect(unnamedLabels.contains(LocalizedKey.recipientNameThis.text))
        #expect(!unnamedLabels.contains(LocalizedKey.recipientEditLabel.text))

        try RecipientRegistry.upsert(
            RecipientRecord(label: "Alice", kind: .person, ageRecipient: owner.public), in: root)
        let named = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let namedHost = GatingHost(size: CGSize(width: 560, height: 760)) {
            AnyView(ProjectAccessView(model: named, onClose: {}, onFilesApplied: {}))
        }
        defer { namedHost.finish() }
        await namedHost.settle(until: { named.loadState == .loaded })
        let namedLabels = labels(in: namedHost.nodes())
        #expect(namedLabels.contains(LocalizedKey.recipientEditLabel.text))
        #expect(!namedLabels.contains(LocalizedKey.recipientNameThis.text))
    }

    /// A field a user can type into and never see again is a field that quietly
    /// stops being kept up to date. The editor collects a note, so the rows draw
    /// one.
    @Test("a recipient's note is drawn on its row")
    func theRowDrawsTheNote() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-note-row")
        try RecipientRegistry.upsert(
            RecipientRecord(
                label: "Alice", kind: .person, ageRecipient: owner.public,
                note: "rotates every quarter"),
            in: root)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 560, height: 760)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        #expect(labels(in: host.nodes()).contains("rotates every quarter"))
    }

    @Test("the per-file panel offers the same control")
    func theFilePanelOffersIt() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-file-wiring")

        let model = RecipientAccessModel(
            fileURL: root.appendingPathComponent("a.yaml"), projectURL: root,
            keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 460, height: 520)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        #expect(labels(in: host.nodes()).contains(LocalizedKey.recipientNameThis.text))
    }

    /// A file opened outside any project has no registry to write to, so the
    /// control must not be offered at all rather than offered and then failing.
    @Test("a file with no project offers no naming control")
    func noProjectNoControl() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let encrypted = try SopsBridge.encrypt(labelPlainYAML, format: .yaml, recipients: [owner.public])

        let model = RecipientAccessModel(
            fileURL: URL(fileURLWithPath: "/dev/null/no-project.yaml"), projectURL: nil,
            keyStore: SessionKeyStore(), readFile: { _ in encrypted })
        let host = GatingHost(size: CGSize(width: 460, height: 520)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        #expect(!labels(in: host.nodes()).contains(LocalizedKey.recipientNameThis.text))
    }

    /// Naming is a registry act: the staged access edits the user has not applied
    /// yet must survive it untouched, and no encrypted file may be read or
    /// written on the way.
    @Test("reloading the registry keeps staged access edits exactly as they were")
    func reloadingTheRegistryLeavesStagingAlone() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let added = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-staging")

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        model.stageAdd(added.public)
        model.stageRemove(owner.public)
        let stagedBefore = model.stagedRecipients
        try #require(model.isDirty)

        try RecipientRegistry.upsert(
            RecipientRecord(label: "Build server", kind: .server, ageRecipient: added.public), in: root)
        model.reloadRegistry()

        #expect(model.stagedRecipients == stagedBefore)
        #expect(model.isDirty)
        #expect(model.registryRecords.map(\.label) == ["Build server"])
        #expect(model.entries.first(where: { $0.ageRecipient == added.public })?.label == "Build server")
    }

    @Test("the per-file panel's registry reload leaves its staging alone too")
    func theFilePanelReloadLeavesStagingAlone() async throws {
        let owner = try LabelAgeKeyPair.generate()
        let added = try LabelAgeKeyPair.generate()
        let root = try makeLabelProject(owner: owner, label: "recipient-label-file-staging")

        let model = RecipientAccessModel(
            fileURL: root.appendingPathComponent("a.yaml"), projectURL: root,
            keyStore: SessionKeyStore())
        await model.load()
        model.stageAdd(added.public)
        let stagedBefore = model.stagedRecipients
        let fileBefore = try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)

        try RecipientRegistry.upsert(
            RecipientRecord(label: "Alice", kind: .person, ageRecipient: owner.public), in: root)
        model.reloadRegistry()

        #expect(model.stagedRecipients == stagedBefore)
        #expect(model.isDirty)
        #expect(model.registryRecords.map(\.label) == ["Alice"])
        #expect(try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8) == fileBefore)
    }
}
