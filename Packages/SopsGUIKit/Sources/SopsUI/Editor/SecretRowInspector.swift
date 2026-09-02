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
/// column.
///
/// ## The editor is behind the same reveal as everything else
/// This pane does **not** get to show a plaintext secret just because the
/// user opened it. An editor seeded unconditionally from `row.value` would
/// sit outside every protection `SecretEditorView`'s doc comment sets out —
/// not gated on a reveal, not cleared by the reveal timeout, and still on
/// screen after the app resigns active, is hidden, or has its window
/// covered. PROPOSAL.md §4 asks for per-field reveal and masking, and an
/// exception that big is not a per-field reveal at all.
///
/// So the value editor renders only while this row is revealed, against the
/// very same `RevealedRows` the table reads; masked, the pane shows the same
/// fixed-width mask a table cell does and a Reveal button that toggles that
/// shared state. The draft lives only for as long as the reveal does — when
/// `hideEverythingRevealed()` fires for any reason, `isRevealed` goes false
/// and the draft is discarded with it, so there is no copy of the plaintext
/// left behind in view state. Typing and Apply both report activity, which
/// is what restarts the countdown; without that, editing a long value would
/// have the row re-mask underneath the user mid-edit.
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

    /// The `.sops.yaml` rule that governs this file, already resolved to its
    /// `path_regex` by the caller — `AccessInventory.FileAccess` carries only
    /// an index, and the regexes live on the inventory. `nil` when no rule
    /// governs the file, which is a real state and is said rather than shown
    /// as a blank.
    private let ruleLabel: String?

    /// The editor's own reveal state, read against `generation` exactly as
    /// `SecretTableView` reads it. Shared, not a second copy: the eye in the
    /// table and the Reveal button here are the same switch, and the reveal
    /// timeout, resign-active, hide and occlusion all clear this one.
    private let revealed: RevealedRows
    private let generation: Int
    private let onToggleReveal: (SecretRow.ID) -> Void

    /// "The user just touched a revealed value." Restarts the auto-hide
    /// countdown in the enclosing editor — typing has to, or a long edit
    /// re-masks mid-keystroke, which is the failure the old row list's
    /// `onChange` already had to close.
    private let onActivity: () -> Void

    /// Shared with the table — see `SecretEditorView.copyFeedback`.
    private let copyFeedback: CopyFeedback
    /// Where the editor height is remembered; injectable for tests.
    private let defaults: UserDefaults
    /// The value editor's height — the user's, see
    /// `InspectorEditorHeightSetting`.
    @State private var editorHeight: CGFloat

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
        nameFor: @escaping (String) -> String?,
        ruleLabel: String?,
        revealed: RevealedRows,
        generation: Int,
        onToggleReveal: @escaping (SecretRow.ID) -> Void,
        onActivity: @escaping () -> Void,
        copyFeedback: CopyFeedback = CopyFeedback(),
        defaults: UserDefaults = .standard
    ) {
        self.copyFeedback = copyFeedback
        self.defaults = defaults
        self._editorHeight = State(initialValue: InspectorEditorHeightSetting.height(in: defaults))
        self.viewModel = viewModel
        self.selectedRowID = selectedRowID
        self.fileName = fileName
        self.access = access
        self.nameFor = nameFor
        self.ruleLabel = ruleLabel
        self.revealed = revealed
        self.generation = generation
        self.onToggleReveal = onToggleReveal
        self.onActivity = onActivity
    }

    /// Whether the selected row's value may be on screen at all.
    private var isRevealed: Bool {
        guard let selectedRowID else { return false }
        return revealed.contains(selectedRowID, in: generation)
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
        // has a revealed selection seeds the draft too — otherwise Apply
        // would be comparing against an empty string and offering to blank
        // the value.
        .onChange(of: selectedRowID, initial: true) { _, _ in
            reseedDraft()
        }
        // The draft is plaintext, so it lives exactly as long as the reveal
        // does. Every way a reveal ends — the timeout, resign-active, hide,
        // occlusion, the row identities being renumbered — comes through
        // here as `isRevealed` going false, and takes the draft with it.
        // Nothing has to remember to clear it separately.
        .onChange(of: isRevealed) { _, _ in
            reseedDraft()
        }
    }

    private func reseedDraft() {
        draft = isRevealed ? (selectedRow?.value ?? "") : ""
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
            HStack {
                Text(.inspectorValue)
                    .font(.headline)
                Spacer()
                Button {
                    onToggleReveal(row.id)
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(
                    isRevealed
                        ? LocalizedKey.editorHideValue.text
                        : LocalizedKey.editorRevealValue.text)
                // The same copy the row has, one click closer to the value
                // being edited. Copying is touching the value.
                RowCopyButton(value: row.value, target: row.id, copyFeedback: copyFeedback,
                              onCopy: { onActivity() })
            }

            if isRevealed {
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: editorHeight)
                    .border(.separator)
                    .disabled(!row.kind.isEditable || viewModel.isSaving)
                    .accessibilityLabel(LocalizedKey.inspectorValue.text)
                    // Typing is touching a revealed value, so it restarts the
                    // countdown. Without this a long edit re-masks — and
                    // takes its own editor off screen — mid-keystroke.
                    .onChange(of: draft) { _, _ in onActivity() }
            } else {
                // The same fixed-width mask a table cell shows: never the
                // value, and never its length. See
                // `SecretRowViewLogic.maskedValue(for:)`.
                Text(SecretRowViewLogic.maskedValue(for: row.value))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: editorHeight, alignment: .topLeading)
                    .border(.separator)
            }

            // Dragging the editor taller is touching the value too.
            VerticalResizeHandle(height: $editorHeight, range: InspectorEditorHeightSetting.allowedRange) {
                InspectorEditorHeightSetting.setHeight($0, in: defaults)
                onActivity()
            }
        }

        HStack(spacing: 8) {
            Button(LocalizedKey.inspectorApply.text) {
                viewModel.update(rowID: row.id, to: draft)
                onActivity()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!isRevealed || draft == row.value || !row.kind.isEditable || viewModel.isSaving)

            Button(LocalizedKey.inspectorRevert.text) {
                draft = row.value
            }
            .disabled(!isRevealed || draft == row.value)

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
                    Text(Self.formatLabel(access.format))
                        .font(.caption)
                }

                LabeledContent(LocalizedKey.inspectorRule.text) {
                    // The rule's own `path_regex` when one governs the file,
                    // and the file list's own "no creation rule governs this
                    // file" sentence when none does — a blank would read as
                    // "not measured", which is a different claim.
                    Text(ruleLabel ?? LocalizedKey.sidebarFileUngoverned.text)
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

    /// A format's display name. `SopsFileFormat.rawValue` stood here first,
    /// which put an un-localized identifier straight into the UI.
    static func formatLabel(_ format: SopsFileFormat) -> String {
        switch format {
        case .yaml: LocalizedKey.inspectorFormatYAML.text
        case .dotenv: LocalizedKey.inspectorFormatDotEnv.text
        case .json: LocalizedKey.inspectorFormatJSON.text
        case .ini: LocalizedKey.inspectorFormatINI.text
        }
    }

    /// Enough of an age recipient to tell two apart without wrapping the
    /// inspector — the same shape the Access surfaces use for an unnamed key.
    static func shortRecipient(_ recipient: String) -> String {
        guard recipient.count > 20 else { return recipient }
        return recipient.prefix(12) + "…" + recipient.suffix(6)
    }
}
