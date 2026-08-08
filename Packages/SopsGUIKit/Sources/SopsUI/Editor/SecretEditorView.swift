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
/// Live, and backed by real bridge operations — Task 8b replaced the disabled
/// affordance Task 9 shipped. `-` removes the selected row; `+` opens a sheet
/// asking for the new key's name, type and value.
///
/// Two choices worth stating:
///
/// - **The `+` adds into the selected row's own container**, or into a
///   selected empty map/list, or into the document's root when nothing is
///   selected. `SecretDocumentViewModel.addDestination(forSelectedRowID:)`
///   decides that, not this view, because whether a container is a map or a
///   list cannot be told from a path (`"0"` is a legitimate map key) and
///   getting it wrong is a correctness problem, not a cosmetic one.
/// - **A row added in this session shows a "new" badge instead of a
///   padlock.** `SecretRow.isEncrypted` is honestly `false` for a row that is
///   not in the file yet, but rendering that as an open padlock would tell
///   the user the value is unprotected when the file's own rules will very
///   likely encrypt it the moment they save. Saying "new" claims neither.
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
    @State private var selectedRowID: String?
    @State private var addRequest: AddRowRequest?

    /// The `+` sheet's subject, captured when the button is pressed so the
    /// destination cannot drift under the sheet if the selection changes.
    private struct AddRowRequest: Identifiable {
        let id = UUID()
        let destination: SecretDocumentViewModel.AddDestination
    }

    /// - Parameter initiallySelectedRowID: which row starts selected. The
    ///   app leaves this `nil`; it exists because the toolbar's `-` is
    ///   enabled only with a selection, and the headless snapshot tool
    ///   cannot click a row to produce one (CLAUDE.md, "What it still cannot
    ///   see") — so without it there is no way to review the enabled state
    ///   of a control at all.
    public init(
        viewModel: SecretDocumentViewModel,
        fileName: String,
        unsavedChanges: UnsavedChangesTracker,
        initiallySelectedRowID: String? = nil
    ) {
        self.viewModel = viewModel
        self.fileName = fileName
        self.unsavedChanges = unsavedChanges
        self._selectedRowID = State(initialValue: initiallySelectedRowID)
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
        .sheet(item: $addRequest) { request in
            EditorAddRowSheet(
                destination: request.destination,
                isNameTaken: { viewModel.isNameTaken($0, in: request.destination) },
                onCancel: { addRequest = nil },
                onAdd: { key, kind, value in
                    let outcome = viewModel.addRow(
                        in: request.destination, key: key, kind: kind, value: value)
                    if case .added(let id) = outcome {
                        selectedRowID = id
                        // A value the user just typed is not a secret they
                        // need protecting from themselves, and hiding it the
                        // instant the sheet closes reads as the app having
                        // lost it.
                        revealedRowIDs.insert(id)
                    }
                    addRequest = nil
                })
        }
        // Reveal state is per open file, not persisted across a switch —
        // Task 9's brief is explicit ("Reveal is per row and does not
        // persist across file switches"). Resetting whenever the identity
        // of the loaded document changes (its ciphertext, which changes on
        // every successful load/save of a *different* file) is what
        // enforces that without this view needing to know when a file
        // switch happened.
        .onChange(of: viewModel.loadState) { _, newState in
            if newState != .loaded {
                revealedRowIDs = []
                selectedRowID = nil
            }
        }
        // A row that is gone — removed, or renumbered away by a save that
        // changed the document's shape — must not stay "selected", or the
        // next `-` would act on nothing and the next `+` would aim at a
        // container that is no longer there.
        .onChange(of: viewModel.rows) { _, newRows in
            if let selectedRowID, !newRows.contains(where: { $0.id == selectedRowID }) {
                self.selectedRowID = nil
            }
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

            Button {
                if let selectedRowID { viewModel.removeRow(id: selectedRowID) }
            } label: {
                Image(systemName: "minus")
            }
            .disabled(!canRemoveSelection)
            .help(canRemoveSelection
                ? LocalizedKey.editorRemoveRow.text
                : LocalizedKey.editorRemoveRowDisabled.text)
            .accessibilityLabel(LocalizedKey.editorRemoveRow.text)

            Button {
                addRequest = AddRowRequest(
                    destination: viewModel.addDestination(forSelectedRowID: selectedRowID))
            } label: {
                Image(systemName: "plus")
            }
            .disabled(viewModel.loadState != .loaded)
            .help(LocalizedKey.editorAddRow.text)
            .accessibilityLabel(LocalizedKey.editorAddRow.text)

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

    private var canRemoveSelection: Bool {
        guard viewModel.loadState == .loaded, let selectedRowID else { return false }
        return viewModel.rows.contains { $0.id == selectedRowID }
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
        List(viewModel.rows, selection: $selectedRowID) { row in
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

                    if row.isPendingAdd {
                        // Deliberately not a padlock either way. This row is
                        // not in the file, so `isEncrypted` is honestly
                        // false — but an open padlock would say "this value
                        // is exposed", which the file's own rules will most
                        // likely contradict the moment it is saved. See the
                        // enclosing view's doc comment.
                        Text(.editorNewRowBadge)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(LocalizedKey.editorNewRowExplanation.text)
                    } else {
                        Image(systemName: row.isEncrypted ? "lock.fill" : "lock.open")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                row.isEncrypted
                                    ? LocalizedKey.editorValueEncrypted.text
                                    : LocalizedKey.editorValueNotEncrypted.text)
                    }
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

/// The `+` sheet: what to call the new key, what type it is, and its value.
///
/// Public rather than private only so the headless snapshot catalog — which
/// lives in its own target — can render it. That tool cannot drive a real
/// interaction to open a sheet (CLAUDE.md, "What it still cannot see"), and
/// an unreviewed sheet is exactly the kind of surface that ships wrong.
/// Nothing in the app constructs it except `SecretEditorView` itself.
///
/// The value goes in a plain `TextField`, not the `SecureField` the row list
/// uses. The row list masks a value the *file* is showing you; this is a
/// value the user is composing right now, and typing a secret into a field
/// that shows dots with no way to check it is how a wrong secret gets saved.
/// It is masked like any other row the moment the sheet closes.
public struct EditorAddRowSheet: View {
    let destination: SecretDocumentViewModel.AddDestination
    let isNameTaken: (String) -> Bool
    let onCancel: () -> Void
    let onAdd: (String, SecretRow.Kind, String) -> Void

    @State private var key = ""
    @State private var kind: SecretRow.Kind = .string
    @State private var value = ""

    /// Written out rather than synthesized. A `private struct`'s memberwise
    /// initializer is itself private, and this machine's three Swift
    /// compilers disagree about whether that is reachable from the enclosing
    /// type — the open-source toolchain rejects it where Xcode's accepts it,
    /// which is the same defect CLAUDE.md records for `HealthFindingRow`.
    public init(
        destination: SecretDocumentViewModel.AddDestination,
        isNameTaken: @escaping (String) -> Bool,
        onCancel: @escaping () -> Void,
        onAdd: @escaping (String, SecretRow.Kind, String) -> Void
    ) {
        self.destination = destination
        self.isNameTaken = isNameTaken
        self.onCancel = onCancel
        self.onAdd = onAdd
    }

    /// The kinds that have a value to type into. `emptyMap`/`emptyList` are
    /// rows the editor can show but not create: an empty container is not a
    /// value, and adding one would be a shape the user could not then put
    /// anything into without a second, differently-shaped operation.
    private static let offeredKinds: [SecretRow.Kind] = [
        .string, .int, .float, .bool, .null, .timestamp,
    ]

    private var isDuplicate: Bool { !destination.isList && !key.isEmpty && isNameTaken(key) }

    private var canAdd: Bool {
        if destination.isList { return true }
        return !key.trimmingCharacters(in: .whitespaces).isEmpty && !isDuplicate
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(.editorAddSheetTitle).font(.headline)

            HStack(spacing: 6) {
                Text(.editorAddDestination)
                    .foregroundStyle(.secondary)
                Text(destinationLabel)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.callout)

            Form {
                if destination.isList {
                    Text(.editorAddListNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    TextField(LocalizedKey.editorAddKeyField.text, text: $key)
                    if isDuplicate {
                        Text(.editorAddDuplicateKey)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Picker(LocalizedKey.editorAddTypeField.text, selection: $kind) {
                    ForEach(Self.offeredKinds, id: \.self) { offered in
                        Text(SecretRowViewLogic.kindLabel(offered).text).tag(offered)
                    }
                }

                if kind != .null {
                    TextField(LocalizedKey.editorAddValueField.text, text: $value)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(LocalizedKey.actionCancel.text, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(LocalizedKey.actionAdd.text) {
                    onAdd(key.trimmingCharacters(in: .whitespaces), kind, kind == .null ? "" : value)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .padding(16)
        .frame(width: 420)
        .onChange(of: kind) { _, newKind in
            value = Self.defaultValue(for: newKind)
        }
    }

    private var destinationLabel: String {
        destination.parent.isEmpty
            ? LocalizedKey.editorAddDestinationRoot.text
            : destination.parent.joined(separator: ".")
    }

    /// A starting value that actually parses as the chosen type, so the Add
    /// button does not hand the bridge something it will refuse.
    private static func defaultValue(for kind: SecretRow.Kind) -> String {
        switch kind {
        case .int, .float: return "0"
        case .bool: return "false"
        case .timestamp: return ISO8601DateFormatter().string(from: Date())
        default: return ""
        }
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
