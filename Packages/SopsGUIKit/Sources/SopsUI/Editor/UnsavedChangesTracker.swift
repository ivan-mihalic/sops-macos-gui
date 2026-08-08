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
    private var saveAction: (() async -> SaveOutcome)?

    public init() {}

    /// Called by the active editor whenever its document's `isDirty` changes,
    /// and once when it appears. `save` is invoked, if at all, from
    /// `save()` below — never stored and called except in response to an
    /// explicit save request, and never retained past the next `update`/`clear`.
    public func update(isDirty: Bool, save: (() async -> SaveOutcome)?) {
        self.isDirty = isDirty
        self.saveAction = save
    }

    /// Called when the active editor leaves — a file switch already resolved
    /// its own prompt, or there is no longer any document open at all. Without
    /// this, a tracker left pointing at a `save` closure for a view that no
    /// longer exists would let ⌘Q's "Save and Quit" resurrect a save call
    /// against a document the user already moved away from.
    public func clear() {
        isDirty = false
        saveAction = nil
    }

    /// Invokes the registered save action, if any. `nil` means there was
    /// nothing to save — not a failure, just nothing registered (the tracker
    /// was already cleared, or nothing was ever loaded).
    @discardableResult
    public func save() async -> SaveOutcome? {
        await saveAction?()
    }
}
