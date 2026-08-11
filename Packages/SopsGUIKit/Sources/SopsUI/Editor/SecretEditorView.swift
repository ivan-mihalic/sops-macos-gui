import AppKit
import Combine
import SopsEngine
import SopsProjects
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
///
/// ## How long a reveal lasts
/// A revealed value is plaintext on a screen, and a copied value is plaintext
/// on a pasteboard. The second has had a deliberate ~30 s life since Task 9
/// (`ClipboardClearing`); the first used to have none at all — it survived
/// until the user clicked the eye again, and it survived the app losing focus,
/// being hidden, and being covered by another window. Three rules now bound
/// it, and all three are in `body`:
///
/// - **A reveal belongs to one row-identity generation** and is void in any
///   other. See `RevealedRows` for what that closes, which is a good deal
///   worse than a value staying visible too long.
/// - **The app stopping being the front app hides everything** —
///   `didResignActive`, `didHide`, and a window going non-visible
///   (`didChangeOcclusionState`). These are AppKit notifications rather than
///   SwiftUI's `scenePhase`, because they are what actually fires for a
///   `Cmd-Tab`, a `Cmd-H` and a window being covered, and because they can be
///   driven from a test (`RevealedRowTests`) where a scene phase cannot.
/// - **`revealTimeout` after the last reveal or edit, everything hides.**
///   Restarted by typing, so it cannot mask a field mid-edit — the masked
///   field is `.disabled`, so being masked mid-edit would take the keyboard
///   away from the user.
public struct SecretEditorView: View {

    /// How long a revealed value stays on screen without the user touching
    /// it. The same "~30 s" PROPOSAL.md §2 sets for the pasteboard, applied to
    /// the other place a plaintext secret sits — deliberately not read from
    /// `ClipboardClearing.defaultInterval`, because these are two different
    /// exposures that happen to agree today, and coupling them would mean
    /// changing one silently changes the other.
    public static let revealTimeout: Duration = .seconds(30)

    @Bindable private var viewModel: SecretDocumentViewModel
    private let unsavedChanges: UnsavedChangesTracker
    private let revealTimeout: Duration

    private let fileName: String

    /// What `RecipientAccessView` needs to act on the same file this editor
    /// has open. `nil` disables the toolbar's Access button rather than
    /// failing — a fixture or test host that never supplies these (most of
    /// the snapshot catalog, the older editor tests) still renders exactly
    /// as it did before this feature existed, instead of every existing call
    /// site needing an update for a feature it does not exercise.
    private let recipientAccess: RecipientAccessContext?

    @State private var revealed = RevealedRows()
    @State private var selection = RowSelection()
    @State private var saveErrorMessage: String?
    @State private var addRequest: AddRowRequest?
    @State private var accessRequest: AccessRequest?
    /// The pending auto-hide. Held so each reveal or edit can restart it
    /// rather than stacking a second timer on top of the first.
    @State private var autoHide: Task<Void, Never>?

    /// The `+` sheet's subject, captured when the button is pressed so the
    /// destination cannot drift under the sheet if the selection changes.
    private struct AddRowRequest: Identifiable {
        let id = UUID()
        let destination: SecretDocumentViewModel.AddDestination
    }

    /// What `SecretEditorView` needs from its caller to offer the Access
    /// button — the file `RecipientAccessModel` reads/writes and the session
    /// key it re-wraps with, alongside an optional project for registry
    /// labels. Passed explicitly rather than read off `viewModel`, matching
    /// how `fileName` already arrives as its own parameter instead of this
    /// view reaching into the document model's internals.
    public struct RecipientAccessContext {
        let fileURL: URL
        let keyStore: SessionKeyStore
        let projectURL: URL?

        public init(fileURL: URL, keyStore: SessionKeyStore, projectURL: URL? = nil) {
            self.fileURL = fileURL
            self.keyStore = keyStore
            self.projectURL = projectURL
        }
    }

    /// The Access sheet's subject: a fresh model built from `recipientAccess`
    /// at the moment the button is pressed, so it always starts from
    /// whatever the file's metadata says right now rather than a copy that
    /// could have drifted since the editor opened.
    private struct AccessRequest: Identifiable {
        let id = UUID()
        let model: RecipientAccessModel
    }

    /// - Parameters:
    ///   - initiallySelectedRowID: which row starts selected. The app leaves
    ///     this `nil`; it exists because the toolbar's `-` is enabled only
    ///     with a selection, and the headless snapshot tool cannot click a row
    ///     to produce one (CLAUDE.md, "What it still cannot see") — so without
    ///     it there is no way to review the enabled state of a control at all.
    ///   - initiallyRevealedRowIDs: which rows start revealed, for exactly the
    ///     same reason and with the same caveat. The app leaves it empty; the
    ///     snapshot catalog uses it for `editor-revealed-row`, and
    ///     `RevealedRowTests` uses it to get a real, laid-out editor into the
    ///     revealed state that no test could otherwise reach — reveal is a
    ///     click, and there is nothing to click in a headless host.
    ///   - revealTimeout: how long a reveal lasts untouched. Injectable only
    ///     so a test does not have to wait 30 real seconds to prove the timer
    ///     exists; nothing in the app passes it.
    ///   - recipientAccess: the file/key/project the toolbar's Access button
    ///     needs. `nil` — the default — hides that button; see
    ///     `RecipientAccessContext`'s doc comment for why this is optional
    ///     rather than a required parameter every existing call site would
    ///     need to grow.
    public init(
        viewModel: SecretDocumentViewModel,
        fileName: String,
        unsavedChanges: UnsavedChangesTracker,
        initiallySelectedRowID: String? = nil,
        initiallyRevealedRowIDs: Set<String> = [],
        revealTimeout: Duration = SecretEditorView.revealTimeout,
        recipientAccess: RecipientAccessContext? = nil
    ) {
        self.viewModel = viewModel
        self.fileName = fileName
        self.unsavedChanges = unsavedChanges
        self.revealTimeout = revealTimeout
        self.recipientAccess = recipientAccess
        // Both recorded against the generation the document is in *now*, so
        // they are subject to exactly the same invalidation as a selection the
        // user made or a row they revealed by clicking. A seam that started
        // life outside the rule would be a seam that could not review it.
        let generation = viewModel.rowIdentityGeneration
        self._selection = State(
            initialValue: RowSelection(initiallySelectedRowID, in: generation))
        self._revealed = State(
            initialValue: RevealedRows(revealing: initiallyRevealedRowIDs, in: generation))
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
                refusal: { viewModel.refusalForAdding($0, in: request.destination) },
                onCancel: { addRequest = nil },
                onAdd: { key, kind, value in
                    let outcome = viewModel.addRow(
                        in: request.destination, key: key, kind: kind, value: value)
                    if case .added(let id) = outcome {
                        // Recorded against the generation `addRow` has just
                        // moved the document into, so this is a claim about
                        // the row that now exists rather than one the next
                        // invalidation has to be trusted to catch.
                        //
                        // A value the user just typed is not a secret they
                        // need protecting from themselves, and hiding it the
                        // instant the sheet closes reads as the app having
                        // lost it. It is still only revealed until the app
                        // loses focus, the shape changes again, or the
                        // auto-hide fires — the hole here was never that the
                        // new row was shown, it was that it was shown for the
                        // rest of the session.
                        let generation = viewModel.rowIdentityGeneration
                        selection.select(id, in: generation)
                        revealed.reveal(id, in: generation)
                    }
                    addRequest = nil
                })
        }
        .sheet(item: $accessRequest) { request in
            RecipientAccessView(
                model: request.model,
                onClose: { accessRequest = nil },
                onApplied: {
                    // The file's bytes changed under the document view
                    // model's own fingerprint — a rewrap that never touches
                    // row values still moves the file's identity, and the
                    // next `Save` would otherwise refuse it as changed on
                    // disk. Reloading resyncs it, exactly as
                    // `SecretDocumentViewModel.save()` reloads itself after
                    // its own write. See `RecipientAccessModel`'s doc
                    // comment ("Reading needs no key; applying does") for why
                    // this is a separate reader/writer of the same file
                    // rather than reaching into the document model's own
                    // private state.
                    Task { await viewModel.load() }
                })
        }
        // Reveal state is per open file, not persisted across a switch —
        // Task 9's brief is explicit ("Reveal is per row and does not
        // persist across file switches"). Leaving `.loaded` is already an
        // invalidation of the row identity (`resetToEmpty` bumps the
        // generation), so this is belt and braces rather than the mechanism;
        // what it adds is stopping the auto-hide timer for a document that is
        // no longer on screen.
        .onChange(of: viewModel.loadState) { _, newState in
            if newState != .loaded {
                hideEverythingRevealed()
                selection.clear()
            }
        }
        // Nothing prunes `selection` or `revealed` against `rows` any more,
        // and that is the fix rather than an omission. Pruning can only drop
        // ids that vanished, and the ones that hurt are the ids that *survive*
        // a renumbering while coming to name a different value. Both pieces of
        // state carry the generation they were recorded under instead, so a
        // change that can re-aim an id voids them without anything having to
        // notice — see `RevealedRows`.
        //
        // Every change to what is revealed restarts the countdown, including
        // the first render of an editor that starts with something revealed
        // (`initial: true`). Driving it from the state rather than from each
        // call site is what stops a future third way of revealing a row from
        // quietly arriving without a deadline attached — which is exactly how
        // the `+` sheet's reveal came to be permanent.
        .onChange(of: revealed, initial: true) { _, _ in
            restartAutoHide()
        }
        .onChange(of: unsavedState, initial: true) { _, state in
            unsavedChanges.update(
                isDirty: state.isDirty, isSaving: state.isSaving,
                save: { await viewModel.save() },
                awaitSaveInFlight: { await viewModel.awaitSaveInFlight() })
        }
        // Losing the front-app position, being hidden, or having the window
        // covered all mean the plaintext on screen is no longer in front of
        // the person who asked for it — or is in front of somebody else. The
        // three AppKit notifications are what actually fire for those; see the
        // type's doc comment for why not `scenePhase`.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didResignActiveNotification)) { _ in
            hideEverythingRevealed()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didHideNotification)) { _ in
            hideEverythingRevealed()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: NSWindow.didChangeOcclusionStateNotification)) { notification in
            // Fires in both directions; only the "no longer visible" edge is
            // a reason to hide anything. Not filtered to *this* view's own
            // window, deliberately: this view cannot name its window without
            // reaching for an `NSViewRepresentable`, and the cost of the
            // over-reaction (Settings being covered masks the editor behind
            // it) is a click, while the cost of under-reacting is a secret
            // left on a screen the user is not at.
            guard let window = notification.object as? NSWindow,
                  !window.occlusionState.contains(.visible) else { return }
            hideEverythingRevealed()
        }
        .onDisappear {
            hideEverythingRevealed()
            selection.clear()
            unsavedChanges.clear()
        }
    }

    /// The pair the tracker needs, as one `Equatable` value — `onChange`
    /// watches one thing, and two separate `onChange`s racing to call
    /// `update` with one another's stale half is precisely the kind of
    /// view-local duplicate of model state this view avoids elsewhere.
    private struct UnsavedState: Equatable {
        let isDirty: Bool
        let isSaving: Bool
    }

    private var unsavedState: UnsavedState {
        UnsavedState(isDirty: viewModel.isDirty, isSaving: viewModel.isSaving)
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

            if let recipientAccess {
                Button {
                    let model = RecipientAccessModel(
                        fileURL: recipientAccess.fileURL,
                        projectURL: recipientAccess.projectURL,
                        keyStore: recipientAccess.keyStore)
                    accessRequest = AccessRequest(model: model)
                } label: {
                    Label(.accessToolbarButton, systemImage: "person.2.badge.key")
                }
                .disabled(viewModel.loadState != .loaded || isSaving)
                .help(LocalizedKey.accessToolbarButton.text)
            }

            Button {
                if let selectedRowID { viewModel.removeRow(id: selectedRowID) }
            } label: {
                // A square hit area, not the glyph's own bounds. Measured on
                // the running app: `AXButton "Remove the selected key" 37x11`
                // — eleven points tall, because a `minus` glyph is a short
                // horizontal bar and the button shrank to it. The `plus` next
                // to it came out 37x20 for the same reason, so the two
                // controls were different sizes as well as too small.
                Image(systemName: "minus")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .disabled(!canRemoveSelection || isSaving)
            .help(canRemoveSelection
                ? LocalizedKey.editorRemoveRow.text
                : LocalizedKey.editorRemoveRowDisabled.text)
            .accessibilityLabel(LocalizedKey.editorRemoveRow.text)

            Button {
                addRequest = AddRowRequest(
                    destination: viewModel.addDestination(forSelectedRowID: selectedRowID))
            } label: {
                Image(systemName: "plus")
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .disabled(viewModel.loadState != .loaded || isSaving)
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

    /// The current row-identity generation — every read and write of
    /// `selection`/`revealed` is scoped to it. See
    /// `SecretDocumentViewModel.rowIdentityGeneration`.
    private var rowGeneration: Int { viewModel.rowIdentityGeneration }

    /// `nil` whenever the selection was made against a document whose rows may
    /// since have been renumbered — so the `-` button goes back to disabled
    /// rather than deleting a row other than the one the user is looking at.
    private var selectedRowID: String? { selection.id(in: rowGeneration) }

    private var canRemoveSelection: Bool {
        guard viewModel.loadState == .loaded, let selectedRowID else { return false }
        return viewModel.rows.contains { $0.id == selectedRowID }
    }

    /// Read from the model rather than tracked here. A view-local copy is how
    /// the two come to disagree, and what has to be true while a save is in
    /// flight — that nothing can be edited — is a property of the document,
    /// not of this view.
    private var isSaving: Bool { viewModel.isSaving }

    private func save() async {
        let outcome = await viewModel.save()
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
        List(viewModel.rows, selection: selectionBinding) { row in
            SecretRowView(
                row: row,
                isRevealed: revealed.contains(row.id, in: rowGeneration),
                onToggleReveal: { toggleReveal(row.id) },
                onChange: { newValue in
                    viewModel.update(rowID: row.id, to: newValue)
                    // Typing counts as touching the reveal: the masked field
                    // is disabled, so auto-hiding a row mid-edit would take
                    // the keyboard out from under the user.
                    restartAutoHide()
                })
        }
        // A save snapshots the pending changes and then spends a few hundred
        // milliseconds encrypting. An edit made in that window has no
        // baseline it can be expressed against afterwards, so the model
        // refuses it — and a field that silently ignores what is typed into
        // it is worse than one that is plainly unavailable.
        .disabled(isSaving)
        .listStyle(.inset)
        .scrollOverflowFade()
    }

    /// `List`'s selection binding, translated through the generation so a
    /// selection can never outlive the row identities it was made against.
    private var selectionBinding: Binding<String?> {
        Binding(
            get: { selection.id(in: rowGeneration) },
            set: { selection.select($0, in: rowGeneration) })
    }

    private func toggleReveal(_ id: String) {
        revealed.toggle(id, in: rowGeneration)
    }

    private func hideEverythingRevealed() {
        autoHide?.cancel()
        autoHide = nil
        revealed.hideAll()
    }

    /// Starts the auto-hide countdown over, or stops it when nothing is
    /// revealed. Called from every reveal and every edit, so the deadline is
    /// always measured from the last time the user touched a revealed value
    /// rather than from the first reveal of the session.
    private func restartAutoHide() {
        autoHide?.cancel()
        guard !revealed.isEmpty else {
            autoHide = nil
            return
        }
        let timeout = revealTimeout
        autoHide = Task { @MainActor in
            // `Task.sleep` throws on cancellation, which is the ordinary way
            // this task ends — a later reveal restarted the clock.
            guard (try? await Task.sleep(for: timeout)) != nil else { return }
            revealed.hideAll()
            autoHide = nil
        }
    }
}

/// Which rows the user has revealed — and, inseparably, the row-identity
/// generation they were revealed under.
///
/// ## Why the generation is part of the value and not a cleanup step
/// Reveal is keyed by `SecretRow.id`, which is derived purely from the row's
/// path, so `ports.1` means "whatever is second in that list *right now*".
/// Removing `ports.0` renumbers the rest, and the id the user revealed comes
/// to name the value after it. That is not a stale entry waiting to be tidied
/// up; it is a live one pointing at a secret nobody asked to see, and it was
/// three clicks away: reveal `ports.1`, select `ports.0`, press `−`, Save —
/// and the third list entry is on screen in plaintext, never revealed.
///
/// The obvious repair, pruning on every row change, does not close it. A prune
/// can only drop ids that have *disappeared*, and the dangerous ones are
/// exactly the ids that survive; one save can even remove a list element and
/// append another, leaving the id list identical over shifted values. A prune
/// is also a step someone has to remember to run, in an `onChange` whose
/// ordering against the reveal it is meant to invalidate is SwiftUI's to
/// decide and not something a test can pin.
///
/// So the generation is stored with the reveal, and every read is answered
/// against the generation the caller asks about. A reveal recorded under
/// generation 4 is simply not a reveal in generation 5 — nothing cleaned it
/// up, it was never a claim about generation 5 in the first place. There is no
/// step to forget and no ordering to get wrong.
///
/// A plain `struct`, so the whole rule is unit-testable without a window —
/// `RevealedRowsTests` drives it directly, and `RevealedRowTests` drives the
/// same rule through a real laid-out editor.
struct RevealedRows: Equatable {

    /// `nil` means "nothing is revealed, under any generation".
    private var generation: Int?
    private var ids: Set<String> = []

    init() {}

    /// The starting state for `SecretEditorView`'s `initiallyRevealedRowIDs`
    /// seam. Empty stays generation-less so an editor constructed with nothing
    /// revealed is `== RevealedRows()` whatever generation it was built in.
    init(revealing ids: Set<String>, in generation: Int) {
        guard !ids.isEmpty else { return }
        self.generation = generation
        self.ids = ids
    }

    var isEmpty: Bool { ids.isEmpty }

    func contains(_ id: String, in generation: Int) -> Bool {
        self.generation == generation && ids.contains(id)
    }

    mutating func toggle(_ id: String, in generation: Int) {
        if contains(id, in: generation) {
            hide(id, in: generation)
        } else {
            reveal(id, in: generation)
        }
    }

    mutating func reveal(_ id: String, in generation: Int) {
        adopt(generation)
        ids.insert(id)
    }

    mutating func hide(_ id: String, in generation: Int) {
        adopt(generation)
        ids.remove(id)
        if ids.isEmpty { self.generation = nil }
    }

    mutating func hideAll() {
        generation = nil
        ids = []
    }

    /// The first reveal in a new generation starts from nothing: whatever was
    /// revealed under the old one was about rows that may not be these rows.
    private mutating func adopt(_ generation: Int) {
        guard self.generation != generation else { return }
        self.generation = generation
        ids = []
    }
}

/// The selected row id, scoped to a row-identity generation exactly as
/// `RevealedRows` is, and for the same reason one step along: a selection made
/// before a renumbering names a different row afterwards, so the next `−`
/// deletes something other than what the user can see is selected. Both
/// pieces of state alias the same way because both are path-derived ids held
/// across a change to the document, so both are fixed the same way rather than
/// one of them being fixed and the other left as the next report.
struct RowSelection: Equatable {

    private var generation: Int?
    private var selected: String?

    init() {}

    init(_ id: String?, in generation: Int) {
        guard let id else { return }
        self.generation = generation
        self.selected = id
    }

    func id(in generation: Int) -> String? {
        self.generation == generation ? selected : nil
    }

    mutating func select(_ id: String?, in generation: Int) {
        self.generation = id == nil ? nil : generation
        self.selected = id
    }

    mutating func clear() {
        generation = nil
        selected = nil
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
                        // Deliberately **not** a `SecureField` bound to
                        // `$text`. A `SecureField` draws — and publishes to
                        // the accessibility tree — one bullet per character
                        // of the value behind it, which hands out the exact
                        // length of every secret in the file to anything
                        // reading either channel. See
                        // `SecretRowViewLogic.maskWidth`.
                        //
                        // The cost of a fixed-width mask is that a masked row
                        // is no longer typed into: the field shows a constant
                        // that is not the value, so accepting keystrokes into
                        // it would be editing something the user cannot see.
                        // Reveal (the eye, right here) is one click, and
                        // typing a replacement secret over one you were never
                        // shown was never a good idea — this makes it
                        // impossible rather than merely unwise. Copy still
                        // works masked, which is the affordance PROPOSAL.md §4
                        // actually asks not to be gated on revealing.
                        TextField("", text: .constant(SecretRowViewLogic.maskedValue(for: text)))
                            .disabled(true)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                // `minWidth` 100, not 160. The value field and the two
                // trailing buttons were competing for the same space, and the
                // field won: rendered at 380 pt the copy button vanished from
                // some rows and not others — whichever rows had a shorter key
                // kept theirs — and at 320 pt it was sliced in half by the
                // pane edge. The field is the thing that can afford to be
                // narrower; a control the user cannot click is not a layout
                // trade-off, it is a missing feature.
                .frame(minWidth: 100, idealWidth: 220)
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

                // Reserved width, so the two controls are laid out before the
                // field gets what is left instead of after. This is also what
                // makes them line up down the column: sized to content, each
                // row's pair sat wherever that row's value field happened to
                // end, which was visibly ragged.
                HStack(spacing: 4) {
                    Button(action: onToggleReveal) {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isRevealed ? LocalizedKey.editorHideValue.text : LocalizedKey.editorRevealValue.text)

                    Button {
                        ClipboardClearing.copy(row.value)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(LocalizedKey.actionCopy.text)
                }
                .fixedSize()
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
    let refusal: (String) -> SecretDocumentViewModel.AddRowRefusal?
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
        refusal: @escaping (String) -> SecretDocumentViewModel.AddRowRefusal?,
        onCancel: @escaping () -> Void,
        onAdd: @escaping (String, SecretRow.Kind, String) -> Void
    ) {
        self.destination = destination
        self.refusal = refusal
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

    /// The model's own answer, so the sheet and the save can never disagree
    /// about whether a name is allowed. `nil` while the field is still empty:
    /// "you have not typed anything yet" is not an error worth shouting.
    private var currentRefusal: SecretDocumentViewModel.AddRowRefusal? {
        guard !destination.isList, !key.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return refusal(key)
    }

    private var canAdd: Bool {
        if destination.isList { return true }
        return !key.trimmingCharacters(in: .whitespaces).isEmpty && refusal(key) == nil
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
                    if let currentRefusal, let explanation = Self.explanation(for: currentRefusal) {
                        Text(explanation)
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

    /// Only the reasons a *name* can be refused get a message here; the
    /// others cannot be reached from this sheet (it is not even presented
    /// without a loaded document, and the `+` is disabled during a save).
    static func explanation(for refusal: SecretDocumentViewModel.AddRowRefusal) -> LocalizedKey? {
        switch refusal {
        case .duplicateKey: .editorAddDuplicateKey
        case .reservedKey: .editorAddReservedKey
        case .emptyKey, .notLoaded, .unsupportedKind, .saveInProgress: nil
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

    /// How many bullets a masked value shows — the same number for every
    /// value, whatever its real length.
    ///
    /// A `SecureField` bound to the real value draws one bullet per
    /// character, and that count is not only on screen: it is the field's
    /// accessibility *value* too, so VoiceOver — or anything else attached to
    /// the accessibility tree — can read the exact length of every secret in
    /// the file without ever revealing one. Length is not nothing. It
    /// separates a four-digit PIN from a 64-character token, it identifies a
    /// credential by its format, and it collapses a brute-force search space
    /// by orders of magnitude. `AccessibilityTreeTests` established that no
    /// plaintext reaches the tree; this is the part of the value that was
    /// still getting through.
    ///
    /// Eight is chosen only so the field reads as a value rather than as a
    /// filled bar. Nothing depends on the number itself — only on it being
    /// the same for every row.
    static let maskWidth = 8

    /// What a row shows in place of `value` while it is not revealed.
    ///
    /// Empty stays empty, deliberately. sops does not encrypt an empty string
    /// at all (`SecretDocumentViewModel`'s "`isEncrypted` on empty strings and
    /// nulls"), so there is no secret behind an empty value to hide — and
    /// eight bullets over nothing would claim a value the file does not
    /// contain. That is the same small lie `scrollOverflowFade()` avoids by
    /// never fading when there is nothing more to see.
    static func maskedValue(for value: String) -> String {
        value.isEmpty ? "" : String(repeating: "•", count: maskWidth)
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
