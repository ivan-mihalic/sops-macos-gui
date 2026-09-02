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
    let onToggleReveal: (SecretRow.ID) -> Void

    init(
        rows: [SecretRow],
        selection: Binding<SecretRow.ID?>,
        revealed: RevealedRows,
        generation: Int,
        onToggleReveal: @escaping (SecretRow.ID) -> Void
    ) {
        self.rows = rows
        self._selection = selection
        self.revealed = revealed
        self.generation = generation
        self.onToggleReveal = onToggleReveal
    }

    var body: some View {
        Table(rows, selection: $selection) {
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

            TableColumn(LocalizedKey.editorColumnValue.text) { row in
                valueCell(row)
            }

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
            .width(90)

            TableColumn("") { row in
                actionCell(row)
            }
            .width(60)
        }
        .tableStyle(.inset)
        .scrollOverflowFade()
    }

    @ViewBuilder
    private func valueCell(_ row: SecretRow) -> some View {
        if !row.kind.isEditable {
            // An empty map or list has no value of its own. Saying so beats
            // an empty cell, which reads as "the value is blank".
            Text(SecretRowViewLogic.kindLabel(row.kind).text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        } else if revealed.contains(row.id, in: generation) {
            Text(row.value)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)
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

                Button {
                    // Copy works masked, deliberately — PROPOSAL.md §4 asks
                    // for one-click copy that is not gated on revealing.
                    ClipboardClearing.copy(row.value)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LocalizedKey.actionCopy.text)
            }
        }
    }
}
