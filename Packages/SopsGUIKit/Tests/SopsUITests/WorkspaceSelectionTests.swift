import Foundation
import Testing
@testable import SopsUI
import SopsProjects

/// `WorkspaceSelection` is the single value Task 6's project tree will select
/// over — a file, a project's Access panel, a project's home, About or
/// Settings. `WorkspaceSwitchGate` ports `AppShell.sectionSwitchDecision` /
/// `SectionSwitchState.applying` onto that value, unchanged in behaviour:
/// same four decisions, same rule that only a *document* being left can ever
/// block a switch.
@Suite("WorkspaceSwitchGate: deciding what a selection change does")
struct WorkspaceSwitchGateTests {

    private let projectA = StoredProject.ID()
    private let projectB = StoredProject.ID()

    // MARK: - decision

    @Test("moving from a dirty file to Access of the same project still asks")
    func dirtyFileBlocksAccess() {
        let p = StoredProject.ID()
        let from = WorkspaceSelection.file(project: p, url: URL(fileURLWithPath: "/p/a.env"))
        let d = WorkspaceSwitchGate.decision(
            from: from, to: .access(project: p),
            documentIsDirty: true, saveIsInFlight: false)
        #expect(d == .askAboutUnsavedChanges)
    }

    @Test("re-selecting the same file is a no-op even when dirty")
    func sameFileIsNoop() {
        let p = StoredProject.ID()
        let u = URL(fileURLWithPath: "/p/a.env")
        let d = WorkspaceSwitchGate.decision(
            from: .file(project: p, url: u), to: .file(project: p, url: u),
            documentIsDirty: true, saveIsInFlight: false)
        #expect(d == .alreadyThere)
    }

    @Test("a dirty file with a save in flight waits, it does not ask")
    func dirtyFileWithSaveInFlightWaits() {
        let p = StoredProject.ID()
        let from = WorkspaceSelection.file(project: p, url: URL(fileURLWithPath: "/p/a.env"))
        let d = WorkspaceSwitchGate.decision(
            from: from, to: .access(project: p),
            documentIsDirty: true, saveIsInFlight: true)
        #expect(d == .waitForSaveInFlight)
    }

    @Test("leaving a non-document selection never asks, even if a stray dirty flag is set")
    func leavingNonDocumentSelectionAlwaysProceeds() {
        let d = WorkspaceSwitchGate.decision(
            from: .about, to: .settings,
            documentIsDirty: true, saveIsInFlight: false)
        #expect(d == .proceed)
    }

    @Test("a clean file switches straight away")
    func cleanFileProceeds() {
        let p = StoredProject.ID()
        let from = WorkspaceSelection.file(project: p, url: URL(fileURLWithPath: "/p/a.env"))
        let d = WorkspaceSwitchGate.decision(
            from: from, to: .projectHome(p),
            documentIsDirty: false, saveIsInFlight: false)
        #expect(d == .proceed)
    }

    @Test("nothing open to nothing requested is already there")
    func nilToNilIsAlreadyThere() {
        let d = WorkspaceSwitchGate.decision(
            from: nil, to: nil, documentIsDirty: false, saveIsInFlight: false)
        #expect(d == .alreadyThere)
    }

    // MARK: - applying

    private func start(_ selection: WorkspaceSelection?) -> WorkspaceSwitchState {
        WorkspaceSwitchState(selection: selection, pending: nil)
    }

    @Test("an unsaved document parks the request and leaves the selection alone")
    func askDoesNotMoveTheSelection() {
        let next = WorkspaceSwitchGate.applying(
            .askAboutUnsavedChanges, requested: .settings, to: start(.about))
        #expect(next.selection == .about,
                "the selection moved before the user was asked, so the editor is gone and the edits with it")
        #expect(next.pending == .settings,
                "nothing recorded where the user was trying to go, so the sheet has nothing to confirm")
    }

    @Test("a clean decision switches straight away")
    func proceedMovesTheSelection() {
        let next = WorkspaceSwitchGate.applying(
            .proceed, requested: .settings, to: start(.about))
        #expect(next.selection == .settings)
        #expect(next.pending == nil, "a clean switch left a pending request behind")
    }

    @Test("switching to where you already are changes nothing")
    func alreadyThereIsInert() {
        let s = start(.about)
        #expect(WorkspaceSwitchGate.applying(.alreadyThere, requested: .about, to: s) == s)
    }

    @Test("waiting for a save in flight changes nothing yet")
    func waitingIsInert() {
        let s = start(.about)
        #expect(WorkspaceSwitchGate.applying(.waitForSaveInFlight, requested: .settings, to: s) == s)
    }

    @Test("an inert decision does not clear a pending request")
    func inertDecisionsPreservePending() {
        let parked = WorkspaceSwitchState(selection: .about, pending: .settings)
        #expect(WorkspaceSwitchGate.applying(.alreadyThere, requested: .about, to: parked) == parked)
        #expect(WorkspaceSwitchGate.applying(.waitForSaveInFlight, requested: .settings, to: parked) == parked)
    }
}

@Suite("WorkspaceSelection")
struct WorkspaceSelectionTests {

    @Test("projectID is the id for file, access and projectHome, nil for about and settings")
    func projectIDByCase() {
        let p = StoredProject.ID()
        let u = URL(fileURLWithPath: "/p/a.env")
        #expect(WorkspaceSelection.file(project: p, url: u).projectID == p)
        #expect(WorkspaceSelection.access(project: p).projectID == p)
        #expect(WorkspaceSelection.projectHome(p).projectID == p)
        #expect(WorkspaceSelection.about.projectID == nil)
        #expect(WorkspaceSelection.settings.projectID == nil)
    }

    @Test("isDocument is true only for .file")
    func isDocumentByCase() {
        let p = StoredProject.ID()
        let u = URL(fileURLWithPath: "/p/a.env")
        #expect(WorkspaceSelection.file(project: p, url: u).isDocument)
        #expect(!WorkspaceSelection.access(project: p).isDocument)
        #expect(!WorkspaceSelection.projectHome(p).isDocument)
        #expect(!WorkspaceSelection.about.isDocument)
        #expect(!WorkspaceSelection.settings.isDocument)
    }
}
