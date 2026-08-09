import Observation

/// Whether *some* open document currently has unsaved edits, and how to save
/// it — shared between the editor (which knows) and the app's quit command
/// (which needs to know, but lives outside the view that owns the actual
/// `SecretDocumentViewModel`).
///
/// This exists because of where the two things it connects live: the active
/// `SecretDocumentViewModel` is scoped to whichever file is open inside the
/// projects workspace, but "should ⌘Q ask first" has to be answered from
/// `SopsGUIApp`'s own `.commands`, which has no path down into that nested
/// view state. A single shared instance, constructed once alongside
/// `ProjectStore`/`SessionKeyStore` and threaded down through `AppShell`, is
/// the same shape those two already use for the identical reason (one
/// instance, several readers, no relaunch-required staleness).
///
/// Holds *at most one* document's state — this app opens one file at a time
/// (PROPOSAL.md's editor is single-document), so "the" active document is
/// unambiguous. `SecretEditorView` registers itself while its document is on
/// screen and clears the registration when it leaves, via `update`/`clear`.
@MainActor
@Observable
public final class UnsavedChangesTracker {

    public private(set) var isDirty = false

    /// Whether the active editor's document has a save in flight — the
    /// editor's own `SecretDocumentViewModel.isSaving`, forwarded for the same
    /// reason `isDirty` is: the quit path has to know, and it cannot reach the
    /// view model. Terminating inside that window, or offering to save again
    /// inside it, is the hole `WorkspaceSwitchDecision.waitForSaveInFlight`
    /// exists to close.
    public private(set) var isSaving = false

    private var saveAction: (() async -> SaveOutcome)?

    /// Forwarded alongside `saveAction` for the same reason: a caller outside
    /// the editor — the outer sidebar, the quit path — can see `isSaving` but
    /// has no way to wait for it to finish. Without this, "re-ask once the
    /// save lands" would have to be a poll, and a poll on a document's write
    /// is how you end up sampling it in the wrong state.
    private var awaitSaveAction: (() async -> Void)?

    public init() {}

    /// Called by the active editor whenever its document's `isDirty` or
    /// `isSaving` changes, and once when it appears. `save` is invoked, if at
    /// all, from `save()` below — never stored and called except in response to
    /// an explicit save request, and never retained past the next
    /// `update`/`clear`.
    public func update(
        isDirty: Bool, isSaving: Bool,
        save: (() async -> SaveOutcome)?,
        awaitSaveInFlight: (() async -> Void)? = nil
    ) {
        self.isDirty = isDirty
        self.isSaving = isSaving
        self.saveAction = save
        self.awaitSaveAction = awaitSaveInFlight
    }

    /// Called when the active editor leaves — a file switch already resolved
    /// its own prompt, or there is no longer any document open at all. Without
    /// this, a tracker left pointing at a `save` closure for a view that no
    /// longer exists would let ⌘Q's "Save and Quit" resurrect a save call
    /// against a document the user already moved away from.
    public func clear() {
        isDirty = false
        isSaving = false
        saveAction = nil
        awaitSaveAction = nil
    }

    /// Returns once the registered document's save, if any, has finished.
    /// Returns immediately when nothing is registered — "no document" and
    /// "document not saving" are the same answer to the only question the
    /// caller is asking.
    public func awaitSaveInFlight() async {
        await awaitSaveAction?()
    }

    /// Invokes the registered save action, if any. `nil` means there was
    /// nothing to save — not a failure, just nothing registered (the tracker
    /// was already cleared, or nothing was ever loaded).
    @discardableResult
    public func save() async -> SaveOutcome? {
        await saveAction?()
    }
}
