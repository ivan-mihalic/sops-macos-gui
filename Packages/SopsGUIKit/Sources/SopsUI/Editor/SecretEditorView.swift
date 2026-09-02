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

    /// What the project scan knows about this file, for the inspector's
    /// no-selection state. `nil` — the default — simply shows less; nothing
    /// here guesses a format or a rule it was not told.
    private let fileAccess: AccessInventory.FileAccess?

    /// The registry's label for an age recipient, `nil` when it has none.
    private let recipientNameFor: (String) -> String?

    /// The `path_regex` of the `.sops.yaml` rule governing this file,
    /// resolved by the caller from the project's `AccessInventory` — `nil`
    /// when no rule governs it, or before the first scan.
    private let fileRuleLabel: String?

    @State private var revealed = RevealedRows()
    @State private var selection = RowSelection()
    @State private var saveErrorMessage: String?
    @State private var addRequest: AddRowRequest?
    @State private var accessRequest: AccessRequest?
    /// The pending auto-hide. Held so each reveal or edit can restart it
    /// rather than stacking a second timer on top of the first.
    @State private var autoHide: Task<Void, Never>?

    /// Whether the trailing inspector is showing. Open by default: it is
    /// where a value is edited now, and an editor that opens with no way to
    /// change anything visible would read as read-only.
    @State private var showInspector: Bool

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
        /// This file's on-disk shape, so `RecipientAccessModel` reads and
        /// re-wraps it as what it actually is rather than as YAML always —
        /// see `RecipientAccessModel.init`'s doc comment (SOPS-38 fix-wave
        /// I1). No default: every call site names it explicitly, the same
        /// house rule `SecretDocumentViewModel`'s own `format` parameter
        /// follows.
        let format: SopsFileFormat

        public init(fileURL: URL, keyStore: SessionKeyStore, projectURL: URL? = nil, format: SopsFileFormat) {
            self.fileURL = fileURL
            self.keyStore = keyStore
            self.projectURL = projectURL
            self.format = format
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

    /// Whether the toolbar's Access button may be pressed right now.
    ///
    /// Requires a **clean** document (`!isDirty`), not just a loaded one.
    /// `RecipientAccessModel` reads and writes this file independently of
    /// `SecretDocumentViewModel`'s own save path, and a successful apply
    /// reloads the open document (`.sheet(item: $accessRequest)`'s
    /// `onApplied` above) so its save-time fingerprint resyncs with the
    /// rewrapped bytes. That reload calls `SecretDocumentViewModel.load()`,
    /// which discards every pending edit, addition and removal — so without
    /// this gate, typing an unsaved change into a row, then adding a
    /// recipient and pressing Apply, silently threw the typed value away
    /// with no prompt, no error and no dirty indicator surviving to warn
    /// the user. Pulled out as a pure function — mirroring
    /// `WorkspaceSwitchDecision`/`QuitRequest` elsewhere in this module — so
    /// the gate is directly testable without a rendered view. The `!isDirty
    /// && !isSaving` half of the question is `UnsavedWorkGate.isClear`, not
    /// written out here — see that type's doc comment (ticket #23) for why
    /// three hand-written copies of it used to exist.
    static func canOpenAccessPanel(loadState: LoadState, isDirty: Bool, isSaving: Bool) -> Bool {
        loadState == .loaded && UnsavedWorkGate.isClear(isDirty: isDirty, isSaving: isSaving)
    }

    /// The Access button's help text — its tooltip when enabled, and its
    /// *reason* for being disabled otherwise. `canOpenAccessPanel` collapses
    /// several distinct reasons into one boolean (not loaded, dirty,
    /// saving); this is honest about the one of them worth naming
    /// separately.
    ///
    /// SOPS-38 phase F3 finding: before this existed, a `.readOnlyCiphertext`
    /// document's Access button was disabled — correctly, `loadState !=
    /// .loaded` already refuses it — but explained itself with
    /// `accessDisabledUnsavedChanges` ("Save your changes before managing
    /// access."), which is false here: this document was never decrypted, so
    /// there is nothing to save, and no amount of saving would make Access
    /// reachable. A disabled control with an honest reason ("you can't change
    /// access to a file you can't decrypt") beats a vanished one, which is
    /// why this state hides nothing — see `CiphertextReadOnlyView`'s own doc
    /// comment for why there genuinely is no path from that view to a
    /// recipient change.
    ///
    /// Pulled out as a pure function — mirroring `canOpenAccessPanel` and
    /// this module's other `WorkspaceSwitchDecision`/`QuitRequest`-shaped
    /// helpers — so the distinction is directly testable without rendering
    /// this view.
    static func accessButtonHelpText(loadState: LoadState, canOpenAccess: Bool) -> LocalizedKey {
        guard !canOpenAccess else { return .accessToolbarButton }
        if case .readOnlyCiphertext = loadState { return .accessDisabledReadOnlyCiphertext }
        return .accessDisabledUnsavedChanges
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
        recipientAccess: RecipientAccessContext? = nil,
        fileAccess: AccessInventory.FileAccess? = nil,
        recipientNameFor: @escaping (String) -> String? = { _ in nil },
        fileRuleLabel: String? = nil,
        inspectorInitiallyShown: Bool = true
    ) {
        self.viewModel = viewModel
        self.fileName = fileName
        self.unsavedChanges = unsavedChanges
        self.revealTimeout = revealTimeout
        self.recipientAccess = recipientAccess
        self.fileAccess = fileAccess
        self.recipientNameFor = recipientNameFor
        self.fileRuleLabel = fileRuleLabel
        self._showInspector = State(initialValue: inspectorInitiallyShown)
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
        .inspector(isPresented: $showInspector) {
            SecretRowInspector(
                viewModel: viewModel,
                selectedRowID: selectedRowID,
                fileName: fileName,
                access: fileAccess,
                nameFor: recipientNameFor,
                ruleLabel: fileRuleLabel,
                // The same `RevealedRows` the table reads, not a second copy:
                // the eye in a row and the one in the inspector are one
                // switch, and one timeout clears both.
                revealed: revealed,
                generation: rowGeneration,
                onToggleReveal: { id in toggleReveal(id) },
                // Typing and Apply are not changes to `revealed`, so the
                // countdown's usual owner never hears about them. This is the
                // one path that has to say so explicitly.
                onActivity: { restartAutoHide() })
                .inspectorColumnWidth(min: 260, ideal: 300, max: 420)
        }
        // Opening the inspector is touching the document the same way
        // revealing a row is, so it restarts the auto-hide countdown rather
        // than letting a reveal age out while the user works in the pane
        // next to it.
        .onChange(of: showInspector) { _, isShown in
            if isShown { restartAutoHide() }
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
                allowedKinds: viewModel.allowedAddKinds,
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
                let canOpenAccess = Self.canOpenAccessPanel(
                    loadState: viewModel.loadState, isDirty: viewModel.isDirty, isSaving: isSaving)
                Button {
                    let model = RecipientAccessModel(
                        fileURL: recipientAccess.fileURL,
                        projectURL: recipientAccess.projectURL,
                        keyStore: recipientAccess.keyStore,
                        format: recipientAccess.format)
                    accessRequest = AccessRequest(model: model)
                } label: {
                    Label(.accessToolbarButton, systemImage: "person.2.badge.key")
                }
                .disabled(!canOpenAccess)
                .help(Self.accessButtonHelpText(loadState: viewModel.loadState, canOpenAccess: canOpenAccess).text)
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
                showInspector.toggle()
            } label: {
                Label(LocalizedKey.inspectorToggle.text, systemImage: "sidebar.trailing")
            }
            .help(LocalizedKey.inspectorToggle.text)
            .accessibilityLabel(LocalizedKey.inspectorToggle.text)

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
        case .readOnlyCiphertext(let reason, let rawCiphertext, let recipients):
            // SOPS-38 phase F3: the real view — raw ciphertext, this file's
            // own recipients (labelled where the registry knows them), and
            // the wrong-key explanation `.failed` used to carry. See
            // `CiphertextReadOnlyView`'s own doc comment for why there is no
            // path from here back to decrypt/save/addRow/updateRecipients.
            CiphertextReadOnlyView(
                reason: reason, rawCiphertext: rawCiphertext, recipients: recipients,
                projectURL: recipientAccess?.projectURL)
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
        SecretTableView(
            rows: viewModel.rows,
            selection: selectionBinding,
            revealed: revealed,
            generation: rowGeneration,
            // No `restartAutoHide()` here, deliberately. `.onChange(of:
            // revealed, initial: true)` in `body` is the **single owner** of
            // the countdown for anything that changes what is revealed, and
            // this toggle changes exactly that. A second call at this site
            // restarted the same timer twice and, worse, implied the owner
            // does not cover reveals — which is how a third way of revealing
            // a row would come to arrive without a deadline attached.
            onToggleReveal: { id in toggleReveal(id) })
        // A save snapshots the pending changes and then spends a few hundred
        // milliseconds encrypting. An edit made in that window has no
        // baseline it can be expressed against afterwards, so the model
        // refuses it — and a control that silently ignores what is asked of
        // it is worse than one that is plainly unavailable.
        .disabled(isSaving)
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
/// Public for the same narrow reason `SecretRowInspector` is: that view's
/// `public init` takes one, and the headless snapshot catalog lives in its
/// own target. Nothing outside this module constructs one.
public struct RevealedRows: Equatable {

    /// `nil` means "nothing is revealed, under any generation".
    private var generation: Int?
    private var ids: Set<String> = []

    public init() {}

    /// The starting state for `SecretEditorView`'s `initiallyRevealedRowIDs`
    /// seam. Empty stays generation-less so an editor constructed with nothing
    /// revealed is `== RevealedRows()` whatever generation it was built in.
    public init(revealing ids: Set<String>, in generation: Int) {
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
    /// The kinds this document's format can actually hold —
    /// `SecretDocumentViewModel.allowedAddKinds`, so this sheet's type picker
    /// can never offer a choice the save would only refuse. Used to be a
    /// private constant here (`emptyMap`/`emptyList` are rows the editor can
    /// show but not create: an empty container is not a value, and adding
    /// one would be a shape the user could not then put anything into
    /// without a second, differently-shaped operation) — that part is
    /// unchanged and still true of every element this can ever contain; what
    /// moved is *which* of the remaining kinds apply, because that now
    /// depends on the document's format rather than being fixed for every
    /// document this app can open.
    let allowedKinds: [SecretRow.Kind]
    let onCancel: () -> Void
    let onAdd: (String, SecretRow.Kind, String) -> Void

    @State private var key = ""
    @State private var kind: SecretRow.Kind
    @State private var value = ""

    /// Written out rather than synthesized. A `private struct`'s memberwise
    /// initializer is itself private, and this machine's three Swift
    /// compilers disagree about whether that is reachable from the enclosing
    /// type — the open-source toolchain rejects it where Xcode's accepts it,
    /// which is the same defect CLAUDE.md records for `HealthFindingRow`.
    public init(
        destination: SecretDocumentViewModel.AddDestination,
        refusal: @escaping (String) -> SecretDocumentViewModel.AddRowRefusal?,
        allowedKinds: [SecretRow.Kind],
        onCancel: @escaping () -> Void,
        onAdd: @escaping (String, SecretRow.Kind, String) -> Void
    ) {
        self.destination = destination
        self.refusal = refusal
        self.allowedKinds = allowedKinds
        self.onCancel = onCancel
        self.onAdd = onAdd
        // `.string` whenever it is offered — the common case, and the only
        // choice at all for a format restricted to it — otherwise the first
        // (and, today, only other) kind this document's format allows.
        self._kind = State(initialValue: allowedKinds.contains(.string) ? .string : (allowedKinds.first ?? .string))
    }

    /// The model's own answer, so the sheet and the save can never disagree
    /// about whether a name is allowed. `nil` while the field is still empty
    /// — "you have not typed anything yet" is not an error worth shouting —
    /// **except** when the destination itself is the problem
    /// (`.unsupportedForFormat`): an INI document's root can refuse every
    /// name equally (SOPS-38 phase F2 task 4 — see `AddCapabilities` on the
    /// model), and that is worth saying immediately rather than waiting for
    /// the user to type something that could never have been accepted
    /// anyway. `refusalForAdding` checks the destination before it ever
    /// looks at the name, so calling it with an empty key still gets the
    /// right answer for that case.
    private var currentRefusal: SecretDocumentViewModel.AddRowRefusal? {
        guard !destination.isList else { return nil }
        let trimmedKey = key.trimmingCharacters(in: .whitespaces)
        let result = refusal(trimmedKey)
        if result == .unsupportedForFormat { return result }
        guard !trimmedKey.isEmpty else { return nil }
        return result
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
                    ForEach(allowedKinds, id: \.self) { offered in
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

    /// Every reason worth a message here is one `currentRefusal` above can
    /// actually surface: a *name*'s own refusal (`duplicateKey`,
    /// `reservedKey`, `invalidDotenvKey`, `invalidINIKey`), or the one
    /// *destination*-level refusal that is reachable from this sheet
    /// (`.unsupportedForFormat` — INI's root; see `AddCapabilities`). The
    /// other `.unsupportedForFormat` shapes (a nested/list destination on a
    /// format with no containers, a list append on a format with no lists)
    /// stay unreachable from here for the reason the model's own doc comment
    /// gives: this sheet's `kind` picker is built from `allowedKinds`, so it
    /// can never offer a kind the model would refuse, and a document flat
    /// enough to refuse a nested destination never produces a selection that
    /// resolves to one in the first place
    /// (`addDestination(forSelectedRowID:)`) — but the *message* is generic
    /// enough to be true of all of them, so nothing here has to distinguish
    /// which shape it is.
    static func explanation(for refusal: SecretDocumentViewModel.AddRowRefusal) -> LocalizedKey? {
        switch refusal {
        case .duplicateKey: .editorAddDuplicateKey
        case .reservedKey: .editorAddReservedKey
        case .invalidDotenvKey: .editorAddInvalidDotenvKey
        case .invalidINIKey: .editorAddInvalidINIKey
        case .unsupportedForFormat: .editorAddUnsupportedForFormat
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

/// Pure, `View`-free helpers `SecretTableView` and
/// `SecretRowInspector` render from — split out so
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
