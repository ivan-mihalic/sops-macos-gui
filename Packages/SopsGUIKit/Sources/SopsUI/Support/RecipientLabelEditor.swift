import Foundation
import Observation
import SopsProjects
import SwiftUI

/// Naming one age public key in a project's recipient registry — creating the
/// name, editing it, or forgetting it.
///
/// ## What a name is, and what it is not
/// `.sops-gui/recipients.json` is a **label directory**. It holds no secrets, it
/// grants nothing, and it decides nothing: `.sops.yaml` and each file's own SOPS
/// metadata remain the sole authority on who can decrypt what. A recipient the
/// registry has never heard of is shown anyway, by its `age1…` public key — the
/// registry can only ever add a human name to a key the file already names.
///
/// This is why forgetting a name is not a destructive act and is deliberately
/// not dressed up as one, and why the wording around it says so in as many
/// places as a user could stop reading. A user who reads "Remove" as "revoke"
/// and moves on has been misled by a tool whose entire job is to tell them who
/// can read their secrets.
///
/// ## Nothing encrypted is touched
/// Every path here writes exactly one file — the registry — through
/// `RecipientRegistry`, and reads none. No encrypted document is opened, no data
/// key is unwrapped, no `.sops.yaml` is rewritten, and the staged access edits
/// the surrounding panel is holding are not disturbed: the panel refreshes its
/// labels through `reloadRegistry()`, which replaces `registryRecords` and
/// touches nothing else.
///
/// ## Concurrency
/// The registry snapshot this editor will write against is taken when the sheet
/// opens (a `stat`, in `init`) and handed back to `RecipientRegistry`'s
/// `expecting:` overload at save time, so a registry rewritten in the meantime —
/// a `git pull`, a second window, a hand edit — is refused rather than
/// clobbered. That guard is best-effort atomic by an accepted decision (a
/// fingerprint check then `renameat`, no lock); no lock is added here, because
/// one would not restrain `git` or the sops CLI and would only pretend to a
/// guarantee this app cannot make.
///
/// The write itself runs off the cooperative pool: it encodes, writes, `fsync`s
/// and renames, and an `fsync` on a slow or networked volume blocks for as long
/// as it blocks.
@MainActor
@Observable
public final class RecipientLabelEditorModel {

    public enum Outcome: Equatable, Sendable {
        case saved
        /// Nothing was written. `errorMessage` says why, in fixed localized
        /// text — never an echo of what the user typed.
        case refused
    }

    /// The public key being named. Shown, never editable: this editor attaches a
    /// name to a recipient the document or the creation rule already lists, and
    /// letting the key itself be typed here would invite the impression that
    /// typing one grants something.
    public let ageRecipient: String

    public var label: String
    public var kind: RecipientKind
    public var note: String

    /// Fixed, localized refusal text. Never carries a value the user typed —
    /// the registry refuses anything private-key-shaped in the label, the note
    /// *and* the recipient, and a refusal that echoed the offending text would
    /// be the leak the refusal exists to prevent.
    public private(set) var errorMessage: String?
    public private(set) var isSaving = false

    private let projectURL: URL
    private let existing: RecipientRecord?
    /// The registry state observed when this sheet opened, carried to the save.
    /// `nil` only when the registry could not be inspected at all, which is
    /// refused rather than turned into an unguarded write — `.absent` is a
    /// perfectly good state and is not this.
    private let baseline: RecipientRegistry.ExpectedState?

    private let saveRecord: @Sendable (RecipientRecord, URL, RecipientRegistry.ExpectedState) throws -> Void
    private let removeRecord: @Sendable (UUID, URL, RecipientRegistry.ExpectedState) throws -> Void

    /// - Parameters:
    ///   - projectURL: whose `.sops-gui/recipients.json` this writes.
    ///   - ageRecipient: the public key being named.
    ///   - existing: the record this key already has, if any. Its `id` is kept
    ///     on save, so editing a name replaces a record rather than adding one.
    ///   - readExpectedState/saveRecord/removeRecord: the same injection seams
    ///     the two Access models use, for the same reason — a test drives a
    ///     refusal without filesystem permission tricks, and can prove that a
    ///     path which must not write does not.
    public init(
        projectURL: URL,
        ageRecipient: String,
        existing: RecipientRecord?,
        readExpectedState: @Sendable (URL) throws -> RecipientRegistry.ExpectedState = {
            try RecipientRegistry.expectedState(in: $0)
        },
        saveRecord: @escaping @Sendable (RecipientRecord, URL, RecipientRegistry.ExpectedState) throws -> Void = {
            try RecipientRegistry.upsert($0, in: $1, expecting: $2)
        },
        removeRecord: @escaping @Sendable (UUID, URL, RecipientRegistry.ExpectedState) throws -> Void = {
            try RecipientRegistry.remove($0, in: $1, expecting: $2)
        }
    ) {
        self.projectURL = projectURL
        self.ageRecipient = ageRecipient
        self.existing = existing
        self.label = existing?.label ?? ""
        self.kind = existing?.kind ?? .person
        self.note = existing?.note ?? ""
        self.saveRecord = saveRecord
        self.removeRecord = removeRecord
        // A `stat` of one small file, so it is taken here rather than
        // asynchronously: an editor that could be saved before its own baseline
        // arrived would have a window in which it wrote unguarded.
        self.baseline = try? readExpectedState(projectURL)
    }

    /// Whether this sheet is editing a name that already exists, rather than
    /// creating one. Decides the title, and whether Forget is offered at all.
    public var isEditingExistingRecord: Bool { existing != nil }

    /// A label is required; everything else is not. Checked here so the button
    /// is dead before the registry is asked, which is the one refusal the
    /// registry would give with nothing useful to show for it.
    public var canSave: Bool {
        !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    /// Writes the name. Touches the registry and nothing else.
    @discardableResult
    public func save() async -> Outcome {
        errorMessage = nil
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            errorMessage = LocalizedKey.recipientEditorErrorEmptyLabel.text
            return .refused
        }
        guard !isSaving else { return .refused }
        guard let baseline else {
            errorMessage = LocalizedKey.recipientEditorErrorCouldNotSave.text
            return .refused
        }

        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = RecipientRecord(
            // The existing record's UUID, so this replaces rather than adds.
            id: existing?.id ?? UUID(),
            label: trimmedLabel, kind: kind, ageRecipient: ageRecipient,
            // Absence, not an empty string: a record whose note is `""` would
            // round-trip through JSON as a note the panel draws as a blank line.
            note: trimmedNote.isEmpty ? nil : trimmedNote)

        return await write { save, project in try save(record, project, baseline) }
    }

    /// Removes the registry record for this key. Removes **no access at all** —
    /// see this type's doc comment, and the wording of every string involved.
    @discardableResult
    public func forget() async -> Outcome {
        errorMessage = nil
        guard let existing else {
            errorMessage = LocalizedKey.recipientEditorErrorRecordNotFound.text
            return .refused
        }
        guard !isSaving else { return .refused }
        guard let baseline else {
            errorMessage = LocalizedKey.recipientEditorErrorCouldNotSave.text
            return .refused
        }

        let remove = removeRecord
        return await write { _, project in try remove(existing.id, project, baseline) }
    }

    /// The one place either mutation reaches the filesystem, off the main actor,
    /// with one translation of the registry's refusals.
    private func write(
        _ body: @escaping @Sendable (
            @Sendable (RecipientRecord, URL, RecipientRegistry.ExpectedState) throws -> Void, URL
        ) throws -> Void
    ) async -> Outcome {
        isSaving = true
        defer { isSaving = false }

        let save = saveRecord
        let project = projectURL
        do {
            try await Self.runOffCooperativePool { try body(save, project) }
        } catch let error as RecipientRegistry.Error {
            errorMessage = Self.explanation(for: error).text
            return .refused
        } catch {
            errorMessage = LocalizedKey.recipientEditorErrorCouldNotSave.text
            return .refused
        }
        return .saved
    }

    /// Every refusal the registry can give, translated to a fixed sentence.
    ///
    /// `duplicateAgeRecipient` and `duplicateID` carry values in their
    /// associated data and neither is used: a public key is not a secret, but a
    /// refusal that quotes its input is a habit that reaches the one field where
    /// it would matter. The registry refuses private-key-shaped text in the
    /// label, the note and the recipient alike, and this is what the user is
    /// shown when it does.
    static func explanation(for error: RecipientRegistry.Error) -> LocalizedKey {
        switch error {
        case .emptyLabel: .recipientEditorErrorEmptyLabel
        case .invalidAgeRecipient: .recipientEditorErrorInvalidRecipient
        case .duplicateAgeRecipient: .recipientEditorErrorDuplicate
        case .duplicateID: .recipientEditorErrorDuplicate
        case .privateIdentityNotAllowed: .recipientEditorErrorPrivateIdentity
        case .recordNotFound: .recipientEditorErrorRecordNotFound
        case .changedOnDisk: .recipientEditorErrorChangedOnDisk
        case .pathEscapesProject: .recipientEditorErrorPathEscapesProject
        case .couldNotSave: .recipientEditorErrorCouldNotSave
        }
    }

    /// Runs blocking `body` on a dedicated OS thread rather than a
    /// cooperative-pool one. Same technique and same reasoning as
    /// `RecipientAccessModel.runOffCooperativePool`; duplicated rather than
    /// shared because that one is private to its own file.
    private static func runOffCooperativePool(
        _ body: @escaping @Sendable () throws -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread {
                do {
                    try body()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}

/// One row's request to open the label editor, for `.sheet(item:)`.
///
/// Its own identity rather than the recipient's public key: the sheet is a
/// presentation, and two consecutive edits of the same recipient are two
/// presentations. Both Access panels use this one type so the flow cannot drift
/// between them.
@MainActor
struct RecipientLabelEditRequest: Identifiable {
    let id = UUID()
    let model: RecipientLabelEditorModel
}

/// The sheet behind a recipient row's naming control.
///
/// Public for the same reason both Access panels are: a test renders it through
/// `GatingHost` and reads the result off the accessibility tree. It has no
/// `SnapshotTool/Catalog.swift` entry — not because it would race a scan, as the
/// two panels would, but because it is only ever reached from inside one of
/// them, and the renderer draws a view once, from the top.
public struct RecipientLabelEditorView: View {
    @Bindable private var model: RecipientLabelEditorModel
    private let onClose: () -> Void
    private let onChanged: () -> Void

    @State private var confirmingForget = false

    public init(
        model: RecipientLabelEditorModel,
        onClose: @escaping () -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.model = model
        self.onClose = onClose
        self.onChanged = onChanged
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.isEditingExistingRecord ? .recipientEditorTitleEdit : .recipientEditorTitleNew)
                .font(.headline)

            Text(.recipientEditorRegistryExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(.recipientEditorKeyCaption).font(.caption.weight(.semibold))
                // A public key is not translatable and is shown as itself.
                Text(verbatim: model.ageRecipient)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }

            TextField(LocalizedKey.recipientEditorLabelField.text, text: $model.label)
            Picker(LocalizedKey.recipientEditorKindField.text, selection: $model.kind) {
                ForEach(RecipientKind.allCases, id: \.self) { kind in
                    Text(RecipientRowContent.label(for: kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            TextField(LocalizedKey.recipientEditorNoteField.text, text: $model.note)

            if let errorMessage = model.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if model.isEditingExistingRecord {
                    // No destructive role, and no red: this changes a nickname
                    // and nothing else. Dressing it up as dangerous would be as
                    // misleading as calling it "Remove" — in the other
                    // direction.
                    Button(LocalizedKey.recipientForgetLabel.text) { confirmingForget = true }
                        .accessibilityLabel(LocalizedKey.recipientForgetLabelAccessibility.text)
                        .disabled(model.isSaving)
                }
                Spacer()
                Button(LocalizedKey.actionCancel.text) { onClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSaving)
                if model.isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(LocalizedKey.recipientEditorSavingLabel.text)
                } else {
                    Button(LocalizedKey.recipientEditorSave.text) {
                        Task {
                            if await model.save() == .saved {
                                onChanged()
                                onClose()
                            }
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSave)
                }
            }
        }
        .padding(16)
        .frame(width: 440)
        .confirmationDialog(
            LocalizedKey.recipientForgetConfirmTitle.text,
            isPresented: $confirmingForget
        ) {
            Button(LocalizedKey.recipientForgetConfirmButton.text) {
                Task {
                    if await model.forget() == .saved {
                        onChanged()
                        onClose()
                    }
                }
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {}
        } message: {
            Text(forgetConfirmationMessage)
        }
    }

    /// Internal rather than private so a test can read the exact sentence the
    /// dialog carries — a `.confirmationDialog`'s own body is not reachable from
    /// a unit test, the documented limitation the other two panels' confirmation
    /// messages are pinned around.
    var forgetConfirmationMessage: String {
        String(format: LocalizedKey.recipientForgetConfirmMessage.text, model.label)
    }
}
