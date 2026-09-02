import SopsEngine
import SopsProjects
import SwiftUI

/// The trailing inspector: where a value is actually edited now that
/// `SecretTableView`'s cells are read-only.
///
/// ## Why editing moved here
/// A `TextField` inside a table row has to share the row with the key, the
/// type and two buttons, and a secret is exactly the kind of value that does
/// not fit on a shared line — see `SecretTableView`'s doc comment. Here the
/// value gets a multi-line `TextEditor` and the full width of the inspector
/// column, and it shows the value in plain text on purpose: this pane is
/// opened deliberately, on a row the user selected, to change the thing it
/// displays. Masking a field the user is typing a replacement into is the
/// same mistake the old masked row already refused to make.
///
/// ## What it does not do
/// `Apply` calls `SecretDocumentViewModel.update(rowID:to:)` and nothing
/// else. Saving stays document-level, in the editor's toolbar, because a
/// sops write re-encrypts the whole file — a per-row "save" would be a
/// promise the format cannot keep. `Remove` is a synonym for the toolbar's
/// `−` and goes through `removeRow(id:)` behind a confirmation.
///
/// ## Access is per file
/// With nothing selected, the inspector describes the *file*: its path, its
/// format, the `.sops.yaml` rule that governs it, and who the file is wrapped
/// for. That last list is a per-file fact, and the note under it says so —
/// the per-row padlocks in the table otherwise invite the reading that each
/// key has its own recipients, which sops has no way to express.
/// Public rather than internal only so the headless snapshot catalog — which
/// lives in its own target — can render it, exactly as `EditorAddRowSheet`
/// is. `.inspector`'s own column does not populate under that technique (the
/// same gap CLAUDE.md records for `NavigationSplitView`'s `sidebar:` slot),
/// so rendering this view standalone is the only way to review it at all.
/// Nothing in the app constructs it except `SecretEditorView`.
public struct SecretRowInspector: View {

    private let viewModel: SecretDocumentViewModel
    private let selectedRowID: SecretRow.ID?
    private let fileName: String
    /// What the project scan knows about this file — `nil` before the first
    /// scan completes, or when this editor was constructed without a project
    /// behind it (tests, the snapshot catalog). Absent means the file section
    /// shows what it can and says nothing it cannot.
    private let access: AccessInventory.FileAccess?
    /// The registry's label for a recipient, `nil` when it has none.
    private let nameFor: (String) -> String?

    /// The value being edited, seeded from the selected row and reseeded
    /// whenever the selection moves. Held here rather than pushed into the
    /// model on every keystroke: the old row list marked the document dirty
    /// per character, so a stray keypress on the wrong row was an unsaved
    /// change with no way back short of reloading. `Apply` is the commit and
    /// `Revert` is the way back.
    @State private var draft: String = ""
    @State private var confirmingRemoval = false

    public init(
        viewModel: SecretDocumentViewModel,
        selectedRowID: SecretRow.ID?,
        fileName: String,
        access: AccessInventory.FileAccess?,
        nameFor: @escaping (String) -> String?
    ) {
        self.viewModel = viewModel
        self.selectedRowID = selectedRowID
        self.fileName = fileName
        self.access = access
        self.nameFor = nameFor
    }

    private var selectedRow: SecretRow? {
        guard let selectedRowID else { return nil }
        return viewModel.rows.first { $0.id == selectedRowID }
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let row = selectedRow {
                    rowSection(row)
                } else {
                    fileSection
                    Text(.inspectorNoSelection)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // `initial: true` so the first render of an inspector that already
        // has a selection seeds the draft too — otherwise Apply would be
        // comparing against an empty string and offering to blank the value.
        .onChange(of: selectedRowID, initial: true) { _, _ in
            draft = selectedRow?.value ?? ""
        }
    }

    // MARK: - The selected row

    @ViewBuilder
    private func rowSection(_ row: SecretRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(SecretRowViewLogic.displayPath(row.path))
                .font(.system(.title3, design: .monospaced))
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Text(SecretRowViewLogic.kindLabel(row.kind).text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: row.isEncrypted ? "lock.fill" : "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(
                        row.isEncrypted
                            ? LocalizedKey.editorValueEncrypted.text
                            : LocalizedKey.editorValueNotEncrypted.text)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            Text(.inspectorValue)
                .font(.headline)

            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
                .border(.separator)
                .disabled(!row.kind.isEditable || viewModel.isSaving)
                .accessibilityLabel(LocalizedKey.inspectorValue.text)
        }

        HStack(spacing: 8) {
            Button(LocalizedKey.inspectorApply.text) {
                viewModel.update(rowID: row.id, to: draft)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft == row.value || !row.kind.isEditable || viewModel.isSaving)

            Button(LocalizedKey.inspectorRevert.text) {
                draft = row.value
            }
            .disabled(draft == row.value)

            Spacer()

            Button(LocalizedKey.inspectorRemove.text, role: .destructive) {
                confirmingRemoval = true
            }
            .disabled(viewModel.isSaving)
        }
        .confirmationDialog(
            LocalizedKey.inspectorRemove.text, isPresented: $confirmingRemoval
        ) {
            Button(LocalizedKey.inspectorRemove.text, role: .destructive) {
                viewModel.removeRow(id: row.id)
            }
            Button(LocalizedKey.actionCancel.text, role: .cancel) {}
        } message: {
            Text(SecretRowViewLogic.displayPath(row.path))
        }
    }

    // MARK: - The file

    @ViewBuilder
    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(.inspectorTitleFile)
                .font(.headline)

            LabeledContent(fileName) {
                Text(access?.relativePath ?? fileName)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            if let access {
                LabeledContent(LocalizedKey.inspectorFormat.text) {
                    Text(access.format.rawValue)
                        .font(.caption)
                }

                LabeledContent(LocalizedKey.inspectorRule.text) {
                    Text(ruleLabel(access))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(2)
                }
            }
        }

        if let access, !access.encryptedFor.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(.inspectorReadableBy)
                    .font(.headline)

                ForEach(access.encryptedFor, id: \.self) { recipient in
                    Text(nameFor(recipient) ?? Self.shortRecipient(recipient))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }

                Text(.inspectorReadableByNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            Text(.inspectorReadableByNote)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The governing rule's own `path_regex`, or the rule's index when the
    /// regexes are not to hand. `nil` `ruleIndex` means no rule governs the
    /// file, which is a real state (`AccessInventory.FileAccess`) and is said
    /// rather than rendered as a blank.
    private func ruleLabel(_ access: AccessInventory.FileAccess) -> String {
        guard let index = access.ruleIndex else { return "—" }
        return "#\(index)"
    }

    /// Enough of an age recipient to tell two apart without wrapping the
    /// inspector — the same shape the Access surfaces use for an unnamed key.
    static func shortRecipient(_ recipient: String) -> String {
        guard recipient.count > 20 else { return recipient }
        return recipient.prefix(12) + "…" + recipient.suffix(6)
    }
}
