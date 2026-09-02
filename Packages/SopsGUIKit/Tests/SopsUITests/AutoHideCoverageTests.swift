import Foundation
import Testing
@testable import SopsUI

/// Every way of touching a revealed value restarts its countdown.
///
/// A source-text guard, for the same reason `ScrollOverflowFadeCoverageTests`
/// and `ClipboardRoutingTests` are: what is asserted is that a particular call
/// is present *at a particular site*, and no runtime probe can reach it. The
/// auto-hide timer is a `Task` inside `SecretEditorView`'s `@State`, typing
/// into a `TextEditor` cannot be driven in a headless host, and a closure that
/// is simply never wired up is invisible to every behavioural test that does
/// not first find a way to press the key.
///
/// ## What the countdown's shape is, and why the sites are these
/// `.onChange(of: revealed, initial: true)` in `SecretEditorView.body` is the
/// **single owner** for anything that changes *what is revealed* — the table's
/// eye, the inspector's eye, the `+` sheet's reveal, the initial set. SOPS-39
/// removed a second `restartAutoHide()` next to the table's toggle for exactly
/// that reason: it restarted the same timer twice and implied the owner did
/// not already cover reveals.
///
/// What the owner cannot see is activity that leaves `revealed` unchanged:
///
/// - **typing in the inspector's value editor.** The row list this replaced
///   had `onChange(of: text) { … restartAutoHide() }` per row; deleting
///   `SecretRowView` deleted that, and without a replacement a value long
///   enough to take 30 s to retype re-masks — and takes its own editor off
///   screen — under the user's hands.
/// - **Apply**, which commits that value.
/// - **opening the inspector**, which brings a revealed value onto a surface
///   that was not on screen a moment ago.
///
/// ## Ablation
/// Verified by mutation, each separately: deleting `onActivity()` from the
/// `TextEditor`'s `onChange`, deleting it from Apply's action, and replacing
/// the editor's `onActivity: { restartAutoHide() }` with `onActivity: {}` each
/// turn exactly one of the expectations below red. Deleting the owning
/// `.onChange(of: revealed, initial: true)` turns the last one red.
@Suite("auto-hide coverage — every touch restarts the countdown")
struct AutoHideCoverageTests {

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/SopsUITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appendingPathComponent("Sources/SopsUI")

    /// Comments stripped first — the same attack has beaten a source-text
    /// test in this suite three separate rounds, and a `//` in front of the
    /// call is the cheapest way to pass one of these while shipping the bug.
    private func source(_ relativePath: String) throws -> String {
        OuterSidebarWiringTests.strippingComments(
            try String(contentsOf: Self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    @Test("typing in the inspector's value editor reports activity")
    func typingReportsActivity() throws {
        let text = try source("Editor/SecretRowInspector.swift")
        // Sanity first, so a renamed editor fails as a missing editor rather
        // than passing as a file with nothing to type into.
        #expect(text.contains("TextEditor(text: $draft)"),
                "the inspector no longer has a value editor")
        #expect(text.contains("onChange(of: draft) { _, _ in onActivity() }"),
                "typing no longer restarts the auto-hide countdown: a long edit re-masks, and hides its own editor, mid-keystroke")
    }

    @Test("Apply reports activity")
    func applyReportsActivity() throws {
        let text = try source("Editor/SecretRowInspector.swift")
        #expect(text.contains("viewModel.update(rowID: row.id, to: draft)\n                onActivity()"),
                "Apply no longer restarts the auto-hide countdown")
    }

    @Test("the editor wires the inspector's activity to restartAutoHide")
    func editorWiresActivity() throws {
        let text = try source("Editor/SecretEditorView.swift")
        #expect(text.contains("onActivity: { restartAutoHide() }"),
                "the inspector's activity is wired to nothing; typing and Apply restart no countdown")
    }

    /// The owner itself, stated here so that removing it fails as what it is
    /// rather than as four unrelated tests going quiet.
    @Test("one owner restarts the countdown for every change to what is revealed")
    func revealChangesHaveASingleOwner() throws {
        let text = try source("Editor/SecretEditorView.swift")
        #expect(text.contains("onChange(of: revealed, initial: true)"),
                "nothing restarts the countdown when what is revealed changes")
        #expect(text.contains("restartAutoHide()"),
                "the countdown is never restarted at all")
    }
}
