import Foundation
import Testing
@testable import SopsUI

/// The unsaved-changes guard, from decision to state.
///
/// The decision was already covered; what was not was what the view *does* with
/// it. Changing the `.askAboutUnsavedChanges` branch from `pendingSection` to
/// `selection` passed all 685 tests — and that change is silent data loss: a
/// user with unsaved secret edits clicks About or Settings, no sheet appears,
/// the editor is torn down, the edits are gone.
@Suite("What a section switch does to the view's state")
struct SectionSwitchEffectTests {

    private let start = AppShell.SectionSwitchState(selection: .projects, pendingSection: nil)

    /// The one that matters. `selection` must not move, or the sheet never
    /// gets a chance to appear.
    @Test("an unsaved document parks the request and leaves the selection alone")
    func askDoesNotMoveTheSelection() {
        let next = AppShell.applying(.askAboutUnsavedChanges, requested: .settings, to: start)

        #expect(next.selection == .projects,
                "the selection moved before the user was asked, so the editor is gone and the edits with it")
        #expect(next.pendingSection == .settings,
                "nothing recorded where the user was trying to go, so the sheet has nothing to confirm")
    }

    @Test("a clean document switches straight away")
    func proceedMovesTheSelection() {
        let next = AppShell.applying(.proceed, requested: .settings, to: start)
        #expect(next.selection == .settings)
        #expect(next.pendingSection == nil, "a clean switch left a pending request behind")
    }

    @Test("switching to where you already are changes nothing")
    func alreadyThereIsInert() {
        #expect(AppShell.applying(.alreadyThere, requested: .projects, to: start) == start)
    }

    /// The caller re-asks once the save lands; the state must not move in the
    /// meantime, or the user is switched mid-save.
    @Test("waiting for a save in flight changes nothing yet")
    func waitingIsInert() {
        #expect(AppShell.applying(.waitForSaveInFlight, requested: .settings, to: start) == start)
    }

    /// A pending request already on the books must not be silently replaced by
    /// an inert decision.
    @Test("an inert decision does not clear a pending request")
    func inertDecisionsPreservePending() {
        let parked = AppShell.SectionSwitchState(selection: .projects, pendingSection: .settings)
        #expect(AppShell.applying(.alreadyThere, requested: .projects, to: parked) == parked)
        #expect(AppShell.applying(.waitForSaveInFlight, requested: .settings, to: parked) == parked)
    }
}
