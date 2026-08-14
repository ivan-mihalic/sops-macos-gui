/// The one definition of "is this document's pending state settled enough
/// to act on" — the question every exit from a dirty document has to answer
/// before it is allowed to discard, reload, or otherwise stand on the
/// assumption that nothing would be lost.
///
/// ## Why this exists (ticket #23)
///
/// Before this type, `WorkspaceSwitchDecision.forSwitch`,
/// `SecretEditorView.canOpenAccessPanel` and `ProjectAccessGate.canOpen`
/// each wrote their own copy of `!isDirty && !isSaving` — three
/// independently maintained boolean expressions that happened to agree only
/// because nobody had changed one without also checking the other two by
/// hand. `AccessGateAsymmetryTests` and `ProjectAccessGate`'s own doc
/// comment establish that the gates are still right to *differ* in what
/// else they require — the per-file panel's subject is the open document,
/// the project panel's is the project, and `WorkspaceSwitchDecision` has a
/// third answer (`.waitForSaveInFlight`) neither boolean gate needs — so
/// unifying the three call sites into one function was not the fix; sharing
/// the one term they all agree on, and always agreed on for the same
/// reason, is. See `UnsavedWorkGateCoverageTests` for what stops a fourth
/// exit from reintroducing a fourth hand-written copy instead of calling
/// this.
///
/// A free function on its own would do, but this codebase's convention for
/// a pulled-out judgement — `WorkspaceSwitchDecision`, `QuitRequest`,
/// `ProjectAccessGate` — is a type with nothing but the decision in it, so
/// this follows the same shape rather than being the one exception.
public enum UnsavedWorkGate {
    /// `true` when there is nothing pending that an action taken right now
    /// would discard: the document is neither dirty nor mid-save.
    ///
    /// `isSaving` outranks `isDirty` in every caller of this that has to
    /// choose *what to do* about a `false` answer (see
    /// `WorkspaceSwitchDecision.forSwitch`'s own doc comment for why a save
    /// in flight is its own answer and not the ordinary unsaved-changes
    /// prompt) — but the two are symmetric here, because "is it safe" does
    /// not need to know which reason it wasn't.
    public static func isClear(isDirty: Bool, isSaving: Bool) -> Bool {
        !isDirty && !isSaving
    }
}
