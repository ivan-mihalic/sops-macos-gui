import AppKit
import SopsEngine
import SwiftUI

/// One open document: key/value/type rows, masked by default with a
/// per-field reveal, one-click copy, an unsaved-changes indicator, and Save.
///
/// ## The property this view must not break
/// `viewModel.loadState` drives which of five things is on screen, and they
/// are visually distinct on purpose: `.idle`/`.loading` (a spinner — nothing
/// claimed yet), `.needsKey` (a dedicated "no key configured" state),
/// `.failed(message)` (a dedicated error state, showing the engine's own
/// message), and `.loaded` — which itself splits in two: rows to edit, or,
/// when `rows` is empty, a dedicated "this document has no secrets in it"
/// state. That last split matters as much as the other four: `sops -e` on
/// `{}` is a legitimate, ordinary empty document, and it reads nothing like
/// either an error or a file that failed to open. Conflating any of these
/// five into "show the same blank form" is exactly the failure this
/// milestone exists to close — see `SecretDocumentViewModel`'s own doc
/// comment.
///
/// ## Add/remove rows
/// **Omitted with an explicit, disabled affordance** — not left out
/// silently. `SecretDocumentViewModel` doesn't implement `addRow`/`removeRow`
/// at all (see its doc comment): the bridge's `applyEdits` can only set an
/// existing value, so a view-level splice would look like it worked and
/// vanish on save. A toolbar `+`/`-` pair is shown, disabled, with a
/// `.help()` tooltip and a footer line stating plainly that this isn't
/// supported yet — a control that's visibly present but explains itself is
/// more honest than a control that's simply missing, which a user has no way
/// to distinguish from "not thought of yet." The follow-up is tracked
/// separately (M2 Task 8b).
///
/// ## Merge keys
/// A row whose path contains the literal segment `"<<"` is a YAML merge key
/// sops's own row walk already inlined (`SecretDocumentViewModel`'s doc
/// comment, Task 7 §10/§14). This view renders it **plainly, with an
/// annotation** rather than hiding or refusing it: at the tree level it is
/// an ordinary editable leaf, and refusing to edit something the bridge
/// genuinely supports would remove real capability over a presentation
/// concern. The annotation (`editorMergeKeyBadge`, with a tooltip explaining
/// what editing it actually does) is what keeps the UI honest — a user who
/// edits it should not come away believing they changed the shared anchor.
///
/// ## Copy without requiring reveal
/// "Readonly mode with one-click copy" (PROPOSAL.md §4) is read here as: the
/// masked, read-only-looking dot display is not a barrier to getting the
/// value onto the pasteboard. The copy button next to every editable row
/// works whether or not that row is currently revealed — a user who trusts
/// the value is right does not have to expose it on screen just to copy it
/// elsewhere. `ClipboardClearing` handles the ~30s auto-clear PROPOSAL.md §2
/// requires.
public struct SecretEditorView: View {
    @Bindable private var viewModel: SecretDocumentViewModel
    private let unsavedChanges: UnsavedChangesTracker
    private let fileName: String

    @State private var revealedRowIDs: Set<String> = []
    @State private var saveErrorMessage: String?
    @State private var isSaving = false

    public init(viewModel: SecretDocumentViewModel, fileName: String, unsavedChanges: UnsavedChangesTracker) {
        self.viewModel = viewModel
        self.fileName = fileName
        self.unsavedChanges = unsavedChanges
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            body(for: viewModel.loadState)
        }
        .alert(
            LocalizedKey.editorSaveErrorTitle.text,
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in if !isPresented { saveErrorMessage = nil } })
        ) {
            Button(LocalizedKey.actionDone.text) { saveErrorMessage = nil }
        } message: {
            // The engine's own message — see the type's doc comment on why
            // `.failed`'s text is never routed through `LocalizedKey`.
            Text(saveErrorMessage ?? "")
        }
        // Reveal state is per open file, not persisted across a switch —
        // Task 9's brief is explicit ("Reveal is per row and does not
        // persist across file switches"). Resetting whenever the identity
        // of the loaded document changes (its ciphertext, which changes on
        // every successful load/save of a *different* file) is what
        // enforces that without this view needing to know when a file
        // switch happened.
        .onChange(of: viewModel.loadState) { _, newState in
            if newState != .loaded { revealedRowIDs = [] }
        }
        .onChange(of: viewModel.isDirty, initial: true) { _, isDirty in
            unsavedChanges.update(isDirty: isDirty, save: { await viewModel.save() })
        }
        .onDisappear {
            unsavedChanges.clear()
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(fileName)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if viewModel.isDirty {
                Label(.editorUnsavedIndicator, systemImage: "circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .labelStyle(.titleAndIcon)
                    .imageScale(.small)
            }

            Spacer()

            // Disabled by design — see the type's doc comment ("Add/remove
            // rows").
            Button {
            } label: {
                Image(systemName: "minus")
            }
            .disabled(true)
            .help(LocalizedKey.editorAddRemoveDisabled.text)

            Button {
            } label: {
                Image(systemName: "plus")
            }
            .disabled(true)
            .help(LocalizedKey.editorAddRemoveDisabled.text)

            Button {
                Task { await save() }
            } label: {
                if isSaving {
                    ProgressView().controlSize(.small)
                } else {
                    Text(.editorSaveButton)
                }
            }
            .disabled(!viewModel.isDirty || isSaving || viewModel.loadState != .loaded)
        }
        .padding(10)
    }

    private func save() async {
        isSaving = true
        let outcome = await viewModel.save()
        isSaving = false
        if case .failed(let message) = outcome {
            saveErrorMessage = message
        }
    }

    // MARK: - Body per load state

    @ViewBuilder
    private func body(for state: LoadState) -> some View {
        switch state {
        case .idle, .loading:
            centered {
                ProgressView()
            }
        case .needsKey:
            centered {
                statusView(
                    systemImage: "key.slash",
                    title: .editorNeedsKeyTitle,
                    body: .editorNeedsKeyBody)
            }
        case .failed(let message):
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(.editorLoadFailedTitle)
                        .font(.headline)
                    // Engine-produced diagnostic text, verbatim — see the
                    // type's doc comment for why this is never a
                    // `LocalizedKey`: `SopsBridgeError.description` is
                    // dynamic, sanitised English produced by the engine
                    // (Task 7/8's guarantee: never a document value), not one
                    // of a fixed set of strings this module owns. It is
                    // rendered as plain secondary text, the same treatment
                    // `HealthFindingRow` gives `finding.detail` — fixed
                    // localized chrome (the icon, the title above) around
                    // raw, un-localized diagnostic text below it.
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                }
            }
        case .loaded:
            if viewModel.rows.isEmpty {
                centered {
                    statusView(
                        systemImage: "doc.text",
                        title: .editorEmptyDocumentTitle,
                        body: .editorEmptyDocumentBody)
                }
            } else {
                rowList
            }
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusView(systemImage: String, title: LocalizedKey, body: LocalizedKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(body)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Rows

    private var rowList: some View {
        List(viewModel.rows) { row in
            SecretRowView(
                row: row,
                isRevealed: revealedRowIDs.contains(row.id),
                onToggleReveal: { toggleReveal(row.id) },
                onChange: { newValue in viewModel.update(rowID: row.id, to: newValue) })
        }
        .listStyle(.inset)
        .scrollOverflowFade()
    }

    private func toggleReveal(_ id: String) {
        if revealedRowIDs.contains(id) {
            revealedRowIDs.remove(id)
        } else {
            revealedRowIDs.insert(id)
        }
    }
}

/// A single key/value/type row.
///
/// Kept as its own `View` (rather than inline in `SecretEditorView.rowList`)
/// so each row's `@State` for its own live-typed text is scoped correctly
/// per row identity, and so `SecretRowViewLogic`'s pure helpers below stay
/// unit-testable independent of the enclosing `List`.
private struct SecretRowView: View {
    let row: SecretRow
    let isRevealed: Bool
    let onToggleReveal: () -> Void
    let onChange: (String) -> Void

    @State private var text: String

    init(row: SecretRow, isRevealed: Bool, onToggleReveal: @escaping () -> Void, onChange: @escaping (String) -> Void) {
        self.row = row
        self.isRevealed = isRevealed
        self.onToggleReveal = onToggleReveal
        self.onChange = onChange
        self._text = State(initialValue: row.value)
    }

    private var isMergeKeyRow: Bool { SecretRowViewLogic.isMergeKeyRow(row) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(SecretRowViewLogic.displayPath(row.path))
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if isMergeKeyRow {
                        Image(systemName: "arrow.triangle.merge")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help(LocalizedKey.editorMergeKeyExplanation.text)
                            .accessibilityLabel(LocalizedKey.editorMergeKeyBadge.text)
                    }
                }

                HStack(spacing: 6) {
                    Text(SecretRowViewLogic.kindLabel(row.kind).text)
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    Image(systemName: row.isEncrypted ? "lock.fill" : "lock.open")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            row.isEncrypted
                                ? LocalizedKey.editorValueEncrypted.text
                                : LocalizedKey.editorValueNotEncrypted.text)
                }
            }

            Spacer(minLength: 12)

            if row.kind.isEditable {
                Group {
                    if isRevealed {
                        TextField("", text: $text)
                    } else {
                        SecureField("", text: $text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 160, idealWidth: 220)
                .onChange(of: text) { _, newValue in onChange(newValue) }
                .onChange(of: row.value) { _, newValue in
                    // The baseline changed out from under this row — a
                    // reload, or another row's edit triggering a
                    // re-render with a fresh `SecretRow` value for this
                    // one too. Only actually relevant when this row's own
                    // value changed (`update(rowID:to:)` only touches the
                    // edited row), but re-syncing unconditionally on the
                    // rare case is simpler than tracking why, and never
                    // wrong: `text` and `row.value` are supposed to agree
                    // whenever no local edit is in flight.
                    if newValue != text { text = newValue }
                }

                Button(action: onToggleReveal) {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isRevealed ? LocalizedKey.editorHideValue.text : LocalizedKey.editorRevealValue.text)

                Button {
                    ClipboardClearing.copy(row.value)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(LocalizedKey.actionCopy.text)
            } else {
                Text(SecretRowViewLogic.kindLabel(row.kind).text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Pure, `View`-free helpers `SecretRowView` renders from — split out so
/// they're directly unit-testable (a `View`'s `body` is not) rather than
/// only verifiable by looking at a screenshot.
enum SecretRowViewLogic {

    /// Whether `row` came from a YAML merge key (`<<: *anchor`) — see
    /// `SecretEditorView`'s doc comment ("Merge keys") for what that implies
    /// about what editing it actually does.
    static func isMergeKeyRow(_ row: SecretRow) -> Bool {
        row.path.contains("<<")
    }

    static func displayPath(_ path: [String]) -> String {
        path.joined(separator: ".")
    }

    static func kindLabel(_ kind: SecretRow.Kind) -> LocalizedKey {
        switch kind {
        case .string: .editorKindString
        case .int: .editorKindInt
        case .float: .editorKindFloat
        case .bool: .editorKindBool
        case .null: .editorKindNull
        case .timestamp: .editorKindTimestamp
        case .emptyMap: .editorKindEmptyMap
        case .emptyList: .editorKindEmptyList
        }
    }
}
