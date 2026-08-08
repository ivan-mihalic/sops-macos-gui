import Observation

/// What the application should do about a request to terminate.
///
/// Deliberately not `NSApplication.TerminateReply`. That type has four cases,
/// two of which (`.terminateLater`, and `.terminateCancel` used as a permanent
/// refusal) are ways to hang a logout, and this decision only ever has two
/// answers. Keeping it as its own two-case enum is what lets the decision be
/// tested at all — `App/SopsGUIApp.swift` is an Xcode target outside the Swift
/// package, so anything left in `AppDelegate` is unreachable from `swift test`.
/// The mapping to AppKit that remains there is two lines with no judgement in
/// them.
public enum TerminationDecision: Equatable, Sendable {
    /// Nothing is at stake. Let the termination through.
    case terminateNow
    /// There are unsaved edits. Do not terminate; put the question to the user
    /// instead — `QuitRequest.isAsking` has been set.
    case askFirst
}

/// The single place a request to quit is answered, whoever asked.
///
/// ## Why this is not just `if unsavedChanges.isDirty` in the menu item
///
/// It was, and the menu item was the only thing that asked. `SopsGUIApp`
/// replaced `CommandGroup(.appTermination)` with its own Quit button, so ⌘Q
/// and the app's own Quit menu item prompted — and **nothing else did**. The
/// Dock icon's Quit, the Apple menu at logout/restart/shutdown, and
/// `osascript -e 'quit app "SopsGUI"'` all reach `NSApp.terminate` without
/// passing anywhere near a SwiftUI command, and `AppDelegate` implemented
/// `applicationWillTerminate` (for the pasteboard) but not
/// `applicationShouldTerminate`. The default is `.terminateNow`, so on every
/// one of those paths the user's unsaved edits went away without a word. The
/// plan's own Task 9 Step 3 called this "the one place in the app where a
/// mistake destroys the user's data."
///
/// `applicationShouldTerminate` is the one funnel every terminate goes
/// through, so the decision lives behind it, and this type is what makes that
/// decision testable from the package.
///
/// ## The latch
///
/// Answering "Discard and Quit" calls `NSApp.terminate` again, which arrives
/// back at `applicationShouldTerminate` with the document still dirty. Without
/// `settle()` the prompt would re-present itself forever and the app could
/// never be quit at all — so a confirmed quit is recorded, and every
/// subsequent request is let through. `settle()` is called at the point of no
/// return, immediately before `NSApp.terminate`, never earlier.
///
/// ## `.terminateCancel`, not `.terminateLater`
///
/// AppKit's documented pattern for an asynchronous answer is `.terminateLater`
/// plus `NSApp.reply(toApplicationShouldTerminate:)`. It is rejected here.
/// `.terminateLater` leaves the process in a state where, if the dialog does
/// not come up for any reason, the app hangs unresponsive until macOS force-
/// kills it — and a force-kill loses precisely the edits this is protecting.
/// `.terminateCancel` fails in the safe direction: at worst a logout is
/// cancelled, the app is still running, and the document is still there. Given
/// the choice between an inconvenient failure and a data-losing one, this app
/// takes the inconvenient one.
///
/// **What is not established here.** That the confirmation dialog itself
/// appears, that its buttons are wired to the right actions, or that the
/// AppKit reply is honoured. A `.confirmationDialog` is unreachable from a
/// unit test and invisible to `Scripts/snapshots.sh`, and `App/` is outside
/// the test package entirely. What is proved is this type's decisions, in
/// `QuitRequestTests`.
@MainActor
@Observable
public final class QuitRequest {

    /// Drives the confirmation dialog. Set by `answerTerminationRequest` when
    /// the answer is `.askFirst`; the dialog's Cancel button clears it.
    public var isAsking = false

    /// Whether the user has already committed to quitting. See "The latch".
    public private(set) var isSettled = false

    public init() {}

    /// The answer to one `applicationShouldTerminate`.
    ///
    /// - Parameter documentIsDirty: `UnsavedChangesTracker.isDirty`, which is
    ///   the editor's own `SecretDocumentViewModel.isDirty` — all three kinds
    ///   of pending change, not just edited values. See
    ///   `WorkspaceSwitchDecision`'s "What dirty has to mean here".
    public func answerTerminationRequest(documentIsDirty: Bool) -> TerminationDecision {
        guard !isSettled else { return .terminateNow }
        switch WorkspaceSwitchDecision.forQuit(documentIsDirty: documentIsDirty) {
        case .askAboutUnsavedChanges:
            isAsking = true
            return .askFirst
        case .proceed, .alreadyThere:
            return .terminateNow
        }
    }

    /// Records that the user has committed to quitting, so the next
    /// termination request is let straight through. Call immediately before
    /// `NSApp.terminate`, from "Discard and Quit" and from a *successful*
    /// "Save and Quit" — never from a failed save, which leaves the edits
    /// unsaved and must leave the guard armed.
    public func settle() {
        isSettled = true
        isAsking = false
    }

    /// The user backed out. The prompt closes and nothing is latched, so the
    /// next quit asks again.
    public func cancel() {
        isAsking = false
    }
}
