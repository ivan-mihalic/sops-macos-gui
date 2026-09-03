import SopsEngine
import SwiftUI

/// The open document's rows, as a real `Table`.
///
/// ## Why this replaced the row list
/// Every row used to be an `HStack` holding the key, a `TextField` bound to
/// that row's live text, a type label and two buttons, all competing for one
/// line. The field lost: measured at the window widths this app actually gets
/// used at, the value — the thing the user opened the file to look at — had
/// under a third of the pane, while the key column was as wide as its longest
/// entry whether or not anything needed the room. A `Table` gives the value
/// its own resizable, flexible column and takes editing out of the row
/// entirely; `SecretRowInspector` is where a value is changed now.
///
/// ## What this view is not allowed to publish
/// A masked cell shows `SecretRowViewLogic.maskedValue(for:)` — a fixed
/// number of bullets, never the value and never its length (see that
/// helper's own doc comment for why length is not nothing). The row's
/// accessibility label is the *key*, so an assistive client reading down the
/// table hears which secret each row is without ever being handed one. The
/// value reaches the tree only for a row the user has revealed.
///
/// ## Merge keys get no actions
/// A row whose path contains `"<<"` is an inlined YAML merge key
/// (`SecretEditorView`'s doc comment). It renders annotated and greyed, with
/// no eye and no copy: those affordances would claim the row is a secret of
/// its own standing, and revealing or copying an inlined anchor value is not
/// what the user is asking about when they look at one.
struct SecretTableView: View {

    let rows: [SecretRow]
    @Binding var selection: SecretRow.ID?
    let revealed: RevealedRows
    /// The row-identity generation `revealed` must be read against — see
    /// `RevealedRows`. Passed in rather than derived here, because the
    /// generation belongs to the document and this view holds no document.
    let generation: Int
    /// The one "Copied" confirmation shared with the inspector — one
    /// pasteboard, one button allowed to claim it. See `CopyFeedback`.
    let copyFeedback: CopyFeedback
    /// Column widths and order, owned by the editor and persisted per file
    /// through `EditorLayoutStore`. `.constant` in tests that do not care.
    @Binding var columns: TableColumnCustomization<SecretRow>
    let onToggleReveal: (SecretRow.ID) -> Void

    init(
        rows: [SecretRow],
        selection: Binding<SecretRow.ID?>,
        revealed: RevealedRows,
        generation: Int,
        copyFeedback: CopyFeedback = CopyFeedback(),
        columns: Binding<TableColumnCustomization<SecretRow>> = .constant(TableColumnCustomization()),
        onToggleReveal: @escaping (SecretRow.ID) -> Void
    ) {
        self.rows = rows
        self._selection = selection
        self.revealed = revealed
        self.generation = generation
        self.copyFeedback = copyFeedback
        self._columns = columns
        self.onToggleReveal = onToggleReveal
    }

    var body: some View {
        Table(rows, selection: $selection, columnCustomization: $columns) {
            TableColumn(LocalizedKey.editorColumnKey.text) { row in
                HStack(spacing: 4) {
                    Text(SecretRowViewLogic.displayPath(row.path))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(SecretRowViewLogic.isMergeKeyRow(row) ? .secondary : .primary)
                        // The key, never the value — this is the one string a
                        // screen reader is meant to get from a masked row.
                        // Applied to the `Text` rather than to the enclosing
                        // `HStack`: an `accessibilityLabel` on a container
                        // replaces its children's own labels, which silently
                        // swallowed the merge-key badge's.
                        .accessibilityLabel(SecretRowViewLogic.displayPath(row.path))

                    if SecretRowViewLogic.isMergeKeyRow(row) {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(LocalizedKey.editorMergeKeyExplanation.text)
                            .accessibilityLabel(LocalizedKey.editorMergeKeyBadge.text)
                    }
                }
            }
            // Capped, not just given an ideal. Without a `max` the key
            // column absorbs the slack a wide window hands the table — it
            // took 370 pt of 790 in the SOPS-39 snapshot — and the value is
            // back to the under-a-third share this whole task exists to
            // undo. A key that needs more than 220 pt truncates in the
            // middle; the inspector shows it in full.
            .width(min: 140, ideal: 200, max: 220)
            .customizationID("key")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(LocalizedKey.editorColumnValue.text) { row in
                valueCell(row)
            }
            .customizationID("value")
            .disabledCustomizationBehavior(.visibility)

            TableColumn(LocalizedKey.editorColumnType.text) { row in
                HStack(spacing: 4) {
                    Text(SecretRowViewLogic.kindLabel(row.kind).text)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if row.isPendingAdd {
                        // Not a padlock either way — see `SecretEditorView`'s
                        // doc comment for why a row that is not in the file
                        // yet claims neither.
                        Text(.editorNewRowBadge)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(LocalizedKey.editorNewRowExplanation.text)
                    } else {
                        Image(systemName: row.isEncrypted ? "lock.fill" : "lock.open")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                row.isEncrypted
                                    ? LocalizedKey.editorValueEncrypted.text
                                    : LocalizedKey.editorValueNotEncrypted.text)
                    }
                }
            }
            // Ranges, not fixed widths: a column with a single `.width(n)`
            // cannot be dragged, and the whole point of persisting the
            // layout (SOPS-40) is that the user can.
            .width(min: 70, ideal: 90, max: 160)
            .customizationID("type")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("") { row in
                actionCell(row)
            }
            .width(min: 60, ideal: 60, max: 90)
            .customizationID("actions")
            .disabledCustomizationBehavior([.visibility, .reorder])
        }
        .tableStyle(.inset)
        .scrollOverflowFade()
    }

    /// The value column. A row whose value can be copied *is* the copy
    /// control — click the cell, the value is on the pasteboard (SOPS-44).
    ///
    /// This is the affordance every password manager has, and it is the one
    /// this app was missing: the value is masked, so the only way to get it
    /// out used to be the narrow glyph at the far right of the row, or
    /// revealing the secret on screen first. Copying has never required
    /// revealing here (`RowCopyButton`), and now it does not require aiming
    /// either.
    ///
    /// The confirmation replaces the cell rather than sitting beside it: at
    /// this width there is no room for both, and "Copied" where the value
    /// was is unambiguous about *which* value went to the pasteboard. It is
    /// the same shared `CopyFeedback` the row's own button and the inspector
    /// use, so one copy lights up one row, everywhere it is shown.
    ///
    /// A revealed value gives up `textSelection` to become clickable — the
    /// two cannot both own a click. Selecting text is still available where
    /// a value is genuinely being read rather than moved: the inspector's
    /// editor.
    @ViewBuilder
    private func valueCell(_ row: SecretRow) -> some View {
        if !row.kind.isEditable {
            // An empty map or list has no value of its own. Saying so beats
            // an empty cell, which reads as "the value is blank".
            Text(SecretRowViewLogic.kindLabel(row.kind).text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        } else if SecretRowViewLogic.isMergeKeyRow(row) {
            // No copy on a merge key, for the same reason it gets no eye and
            // no copy button — see this type's doc comment.
            maskedOrRevealedValue(row)
        } else if copyFeedback.label(for: row.id) == .actionCopied {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                Text(.actionCopied)
            }
            .font(.system(.body, design: .monospaced))
            .foregroundStyle(.green)
        } else {
            Button {
                ClipboardClearing.copy(row.value)
                copyFeedback.confirmCopy(of: row.id)
            } label: {
                maskedOrRevealedValue(row)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // `.help`, never `.accessibilityLabel`: a label on this button
            // would *replace* the cell's own text in the accessibility tree,
            // and that text is the mask — the one thing a masked row is
            // required to announce (`AccessibilityTreeTests`, which caught
            // exactly this). The action reaches an assistive client as the
            // help string instead, and which secret it is about comes from
            // the row's key column.
            .help(LocalizedKey.editorCopyValueHelp.text)
        }
    }

    @ViewBuilder
    private func maskedOrRevealedValue(_ row: SecretRow) -> some View {
        if revealed.contains(row.id, in: generation) {
            Text(row.value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
        } else {
            Text(SecretRowViewLogic.maskedValue(for: row.value))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func actionCell(_ row: SecretRow) -> some View {
        if row.kind.isEditable && !SecretRowViewLogic.isMergeKeyRow(row) {
            let isRevealed = revealed.contains(row.id, in: generation)
            HStack(spacing: 2) {
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

                RowCopyButton(value: row.value, target: row.id, copyFeedback: copyFeedback)
            }
        }
    }
}

/// The copy button a secret row and the inspector share: copies through
/// `ClipboardClearing` (so the pasteboard clears itself), and says "Copied"
/// for a moment through the shared `CopyFeedback` — a checkmark in place of
/// the glyph, and the same word in the tooltip and the accessibility label.
///
/// Copy works masked, deliberately — PROPOSAL.md §4 asks for one-click copy
/// that is not gated on revealing.
struct RowCopyButton: View {
    let value: String
    let target: String
    let copyFeedback: CopyFeedback
    var onCopy: () -> Void = {}

    var body: some View {
        let label = copyFeedback.label(for: target)
        let copied = label == .actionCopied
        Button {
            ClipboardClearing.copy(value)
            copyFeedback.confirmCopy(of: target)
            onCopy()
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
                .foregroundStyle(copied ? AnyShapeStyle(.green) : AnyShapeStyle(.primary))
        }
        .buttonStyle(.borderless)
        .help(label.text)
        .accessibilityLabel(label.text)
    }
}
