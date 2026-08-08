import Foundation
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

/// "Quit the app with an unsaved edit open — is the prompt actually shown?"
///
/// Before `QuitRequest` the honest answer was "only if you used ⌘Q or the
/// app's own Quit menu item". `SopsGUIApp` replaced
/// `CommandGroup(.appTermination)` with a button that checked `isDirty`
/// itself, and `AppDelegate` implemented `applicationWillTerminate` but not
/// `applicationShouldTerminate` — so the Dock icon's Quit, the Apple menu at
/// logout/restart/shutdown, and `osascript -e 'quit app "SopsGUI"'` all got
/// AppKit's default `.terminateNow` and destroyed the edit without a word.
///
/// ## What these tests do and do not establish
///
/// They establish the decision: what `applicationShouldTerminate` is told to
/// answer for every combination of dirty state and latch, and that the answer
/// is computed from the same `WorkspaceSwitchDecision` the file-switch prompt
/// uses rather than from a second notion of "dirty" that can drift.
///
/// They do **not** establish that the `.confirmationDialog` appears, that its
/// buttons are wired to `settle()`/`cancel()`, or that AppKit honours the
/// reply. A `.confirmationDialog` is unreachable from a unit test and
/// invisible to `Scripts/snapshots.sh`, and `App/SopsGUIApp.swift` is an Xcode
/// target outside this package — so there is no way to reach any of it from
/// here, and this file does not pretend to. What was done instead was to make
/// the untestable part as small as it can be: two lines in `AppDelegate` that
/// map `TerminationDecision` onto `NSApplication.TerminateReply` with no
/// judgement of their own.
@Suite("the quit decision")
@MainActor
struct QuitRequestTests {

    // MARK: - The decision

    /// The property the finding is about, stated at the level the app
    /// delegate asks the question.
    @Test("a termination request with unsaved edits is refused and asks instead")
    func dirtyTerminationAsks() {
        let request = QuitRequest()
        #expect(request.answerTerminationRequest(documentIsDirty: true) == .askFirst)
        #expect(request.isAsking, "the refusal has to actually put the question on screen")
    }

    @Test("a termination request with nothing unsaved goes straight through")
    func cleanTerminationProceeds() {
        let request = QuitRequest()
        #expect(request.answerTerminationRequest(documentIsDirty: false) == .terminateNow)
        #expect(!request.isAsking, "there is nothing to ask about")
    }

    /// Every route into `applicationShouldTerminate` gets the same answer,
    /// because they all arrive at the same call. This is the regression the
    /// whole change exists to prevent — a second path that decides for itself.
    @Test("repeated requests answer identically: no path is special-cased")
    func everyRouteGetsTheSameAnswer() {
        let request = QuitRequest()
        // ⌘Q, then the Dock icon, then a logout, then osascript — four
        // deliveries of the same question with nothing changed in between.
        for _ in 1...4 {
            #expect(request.answerTerminationRequest(documentIsDirty: true) == .askFirst)
        }
    }

    // MARK: - The latch

    /// Without this the app could never be quit at all: "Discard and Quit"
    /// calls `NSApp.terminate`, which comes back through
    /// `applicationShouldTerminate` with the document still dirty.
    @Test("after the user commits, a still-dirty document no longer blocks the quit")
    func settledRequestLetsTheQuitThrough() {
        let request = QuitRequest()
        #expect(request.answerTerminationRequest(documentIsDirty: true) == .askFirst)

        request.settle()

        #expect(request.answerTerminationRequest(documentIsDirty: true) == .terminateNow)
        #expect(!request.isAsking, "committing to the quit has to take the prompt down")
    }

    @Test("the latch stays down for every later request, not just the next one")
    func settledStaysSettled() {
        let request = QuitRequest()
        request.settle()
        for _ in 1...3 {
            #expect(request.answerTerminationRequest(documentIsDirty: true) == .terminateNow)
        }
        #expect(request.isSettled)
    }

    /// The other direction, and the one that costs data if it is wrong: a
    /// failed "Save and Quit" must not latch. `SopsGUIApp.saveAndQuit()` calls
    /// `settle()` only on the `.saved` branch; this pins what happens when it
    /// is not called.
    @Test("a cancelled prompt leaves the guard armed for the next quit")
    func cancellingRearmsTheGuard() {
        let request = QuitRequest()
        #expect(request.answerTerminationRequest(documentIsDirty: true) == .askFirst)

        request.cancel()

        #expect(!request.isAsking)
        #expect(!request.isSettled, "backing out of a quit is not committing to one")
        #expect(
            request.answerTerminationRequest(documentIsDirty: true) == .askFirst,
            "the next quit has to ask again")
    }

    @Test("a fresh request has not latched anything")
    func freshRequestIsNotSettled() {
        let request = QuitRequest()
        #expect(!request.isSettled)
        #expect(!request.isAsking)
    }

    // MARK: - The same notion of dirty as the file-switch prompt

    /// `forQuit` delegates to `forSwitch` rather than restating the rule, so
    /// that the two prompts cannot come to disagree about what "unsaved"
    /// means. This pins the delegation itself.
    @Test("the quit decision is the file-switch decision with the target fixed")
    func quitIsASwitchToNothing() {
        for dirty in [true, false] {
            #expect(
                WorkspaceSwitchDecision.forQuit(documentIsDirty: dirty)
                    == WorkspaceSwitchDecision.forSwitch(
                        from: 1, to: 0, documentIsDirty: dirty),
                "quitting must reach the same answer as switching away from the document")
        }
    }

    @Test("quitting never reports alreadyThere: there is no such thing as having already quit")
    func quitNeverReportsAlreadyThere() {
        #expect(WorkspaceSwitchDecision.forQuit(documentIsDirty: true) != .alreadyThere)
        #expect(WorkspaceSwitchDecision.forQuit(documentIsDirty: false) != .alreadyThere)
    }

    // MARK: - Driven by a real document, not by a Bool

    /// The dirty flag the app delegate passes in is
    /// `UnsavedChangesTracker.isDirty`, which is a real
    /// `SecretDocumentViewModel.isDirty`. `WorkspaceSwitchDecisionTests`
    /// already proves that flag is composed from all three kinds of pending
    /// change; this proves the quit path is fed by that same flag, through the
    /// same tracker the editor registers with, rather than by something the
    /// app delegate works out for itself.
    @Test("a tracker holding a dirty document makes the quit ask")
    func trackerDrivesTheQuitDecision() async {
        let tracker = UnsavedChangesTracker()
        let request = QuitRequest()

        #expect(request.answerTerminationRequest(documentIsDirty: tracker.isDirty) == .terminateNow)

        tracker.update(isDirty: true, save: { .saved })
        #expect(request.answerTerminationRequest(documentIsDirty: tracker.isDirty) == .askFirst)

        // The editor leaving clears the registration, and the quit stops
        // asking — the same `clear()` that stops "Save and Quit" resurrecting
        // a save against a document the user already moved away from.
        tracker.clear()
        request.cancel()
        #expect(request.answerTerminationRequest(documentIsDirty: tracker.isDirty) == .terminateNow)
    }
}
