/// What happens when the workspace is asked to leave the document it has
/// open — by picking another file, or another project.
///
/// ## Why this is a type and not three lines inside the view
/// It *was* three lines inside `ProjectWorkspaceView`, which is a
/// `private struct` whose prompt is a `.confirmationDialog`. Neither a unit
/// test nor `Scripts/snapshots.sh` can reach either, so the single property
/// this milestone says must not break — an edit is never abandoned without
/// asking — was verified by reading the code and nothing else (Task 12's
/// carried list says so in those words). Pulling the decision out as a pure
/// function of state is what makes it checkable; the dialog stays a thin
/// presentation over the answer, with no judgement of its own.
///
/// ## What "dirty" has to mean here
/// `documentIsDirty` is `SecretDocumentViewModel.isDirty`, which is composed
/// from *all three* kinds of pending change — edited values, rows the user
/// added, and rows they removed (see that type's `recompose()`). It is not
/// "some value was typed into". A user who added a key and switched away
/// without saving has to be warned exactly as much as one who edited a value,
/// and `WorkspaceSwitchDecisionTests` drives a real document through both to
/// prove it rather than trusting the flag's name.
public enum WorkspaceSwitchDecision: Equatable, Sendable {

    /// The request names what is already open. Nothing to do, and — the part
    /// worth stating — nothing to *ask*: re-selecting the open row is not
    /// leaving it, so prompting there would train the user to dismiss the one
    /// prompt that matters.
    case alreadyThere

    /// Nothing is at stake. Switch immediately.
    case proceed

    /// There are unsaved edits in the open document. Ask before anything is
    /// torn down.
    case askAboutUnsavedChanges

    /// The decision, for any switch target that can be compared — a file URL
    /// or a project id; both reach the same three answers and differ only in
    /// how the caller acts on them.
    ///
    /// - Parameters:
    ///   - current: what the workspace has open now, `nil` for nothing.
    ///   - requested: what the user just asked for, `nil` to close.
    ///   - documentIsDirty: `SecretDocumentViewModel.isDirty` for the open
    ///     document; `false` when no document is open.
    public static func forSwitch<Target: Equatable>(
        from current: Target, to requested: Target, documentIsDirty: Bool
    ) -> WorkspaceSwitchDecision {
        guard current != requested else { return .alreadyThere }
        return documentIsDirty ? .askAboutUnsavedChanges : .proceed
    }

    /// The decision for quitting the application.
    ///
    /// Quitting is leaving the open document, so it is the same question with
    /// the target fixed: from "a document is open" to "none will be". It
    /// delegates to `forSwitch` rather than restating `documentIsDirty ? ask :
    /// proceed`, and that is the whole reason it exists as a function instead
    /// of two lines in the app delegate — a second, separately-written notion
    /// of "is anything at stake" is exactly how the ⌘Q path and the
    /// Dock-icon path came to disagree in the first place.
    ///
    /// Never returns `.alreadyThere`: there is no such thing as already having
    /// quit, and the caller would have nothing to do with the answer.
    public static func forQuit(documentIsDirty: Bool) -> WorkspaceSwitchDecision {
        forSwitch(from: SwitchTarget.theOpenDocument, to: SwitchTarget.nothing,
                  documentIsDirty: documentIsDirty)
    }

    /// Only exists to give `forQuit` two distinguishable values to hand
    /// `forSwitch`; nothing else should need it.
    private enum SwitchTarget: Equatable {
        case theOpenDocument
        case nothing
    }
}
