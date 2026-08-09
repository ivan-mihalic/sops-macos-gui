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
///
/// ## Why a save in flight is its own answer
/// `documentIsDirty` used to be the only input, and during the 133–380 ms a
/// save spends encrypting it is still `true` — so a switch requested inside
/// that window got the ordinary unsaved-changes prompt, in which *both*
/// answers were wrong:
///
/// - **"Save and continue"** called `SecretDocumentViewModel.save()`, which
///   refuses a re-entrant save (`"a save of this document is already in
///   progress"`). The user was shown a save-failed alert while their save was
///   in fact succeeding — the app contradicting the file, which is the one
///   thing this editor may not do.
/// - **"Discard changes"** tore the editor down, but the `Task` running the
///   save holds a strong reference to the document and finished anyway:
///   verified, the discarded changes landed on disk. The user said discard and
///   the app wrote.
///
/// Neither is fixed by wording. The question itself is unanswerable while a
/// save is in flight, because "are there unsaved changes" has no settled
/// answer yet — so the decision is `.waitForSaveInFlight`, and the caller asks
/// again once the save has finished (`SecretDocumentViewModel
/// .awaitSaveInFlight()`), against a document that has settled. Nothing is
/// torn down and nothing is asked in the meantime.
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

    /// A save is in flight, so whether anything is at stake is not yet
    /// decided. Do not tear anything down and do not put the question to the
    /// user; wait for the save to finish and ask again. See the type's doc
    /// comment for what asking anyway did.
    ///
    /// Deliberately *not* "refuse the switch": the user's click is honoured,
    /// only late. Dropping it would make the file list feel broken for the
    /// few hundred milliseconds a save takes, which is how a user learns to
    /// click twice.
    case waitForSaveInFlight

    /// The decision, for any switch target that can be compared — a file URL
    /// or a project id; both reach the same four answers and differ only in
    /// how the caller acts on them.
    ///
    /// `saveIsInFlight` is checked before `documentIsDirty`, because during a
    /// save the dirty flag is still set (it clears only when the saved
    /// document is adopted) and it is precisely that combination —
    /// dirty *and* saving — that used to produce a prompt with two wrong
    /// answers.
    ///
    /// - Parameters:
    ///   - current: what the workspace has open now, `nil` for nothing.
    ///   - requested: what the user just asked for, `nil` to close.
    ///   - documentIsDirty: `SecretDocumentViewModel.isDirty` for the open
    ///     document; `false` when no document is open.
    ///   - saveIsInFlight: `SecretDocumentViewModel.isSaving` for the open
    ///     document; `false` when no document is open. Not defaulted, on
    ///     purpose: a default would let a new call site silently reintroduce
    ///     the hole this parameter exists to close.
    public static func forSwitch<Target: Equatable>(
        from current: Target, to requested: Target,
        documentIsDirty: Bool, saveIsInFlight: Bool
    ) -> WorkspaceSwitchDecision {
        guard current != requested else { return .alreadyThere }
        if saveIsInFlight { return .waitForSaveInFlight }
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
    /// The same delegation is why it takes `saveIsInFlight` too. Terminating
    /// mid-save is the switch hole with the process teardown added: the write
    /// may not have happened yet, and there is no editor left to notice. See
    /// `QuitRequest` for what the app does with the answer.
    ///
    /// Never returns `.alreadyThere`: there is no such thing as already having
    /// quit, and the caller would have nothing to do with the answer.
    public static func forQuit(documentIsDirty: Bool, saveIsInFlight: Bool)
        -> WorkspaceSwitchDecision
    {
        forSwitch(from: SwitchTarget.theOpenDocument, to: SwitchTarget.nothing,
                  documentIsDirty: documentIsDirty, saveIsInFlight: saveIsInFlight)
    }

    /// Only exists to give `forQuit` two distinguishable values to hand
    /// `forSwitch`; nothing else should need it.
    private enum SwitchTarget: Equatable {
        case theOpenDocument
        case nothing
    }
}
