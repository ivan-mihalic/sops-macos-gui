import Foundation
import Testing
@testable import SopsUI

/// Every copy of a **secret** goes through `ClipboardClearing.copy`.
///
/// Mutation-verified as unguarded: replacing the editor's copy button with a
/// direct `NSPasteboard.general.setString` left all 242 tests in this target
/// green, because all eight clipboard tests call `ClipboardClearing.copy`
/// directly and none of them go through the button. What that costs is
/// everything `ClipboardClearing` does — the 30-second clear, the
/// `org.nspasteboard.ConcealedType` marker that keeps clipboard managers from
/// recording it, and `.currentHostOnly`, without which the secret is pushed to
/// every Mac, iPhone and iPad on the account via Universal Clipboard, where
/// nothing in this process can ever clear it.
///
/// A source-text guard, for the same reason `ScrollOverflowFadeCoverageTests`
/// is one: what is being asserted is that a particular call is *present at a
/// particular site*, and no runtime probe can see which pasteboard API a view's
/// button closure chose. Comments are stripped first — this exact attack has
/// beaten a source-text test in this suite three separate rounds.
@Suite("Secrets reach the pasteboard only through ClipboardClearing")
struct ClipboardRoutingTests {

    private static let sourceRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/SopsUI")

    private func source(_ relativePath: String) throws -> String {
        OuterSidebarWiringTests.strippingComments(
            try String(contentsOf: Self.sourceRoot.appendingPathComponent(relativePath), encoding: .utf8))
    }

    /// The editor is the only view that puts a decrypted secret on the
    /// pasteboard.
    @Test("the editor's copy control routes through ClipboardClearing")
    func editorCopyIsRouted() throws {
        let text = try source("Editor/SecretEditorView.swift")
        #expect(text.contains("ClipboardClearing.copy("),
                "the editor no longer copies through ClipboardClearing: no deadline, no ConcealedType marker, and Universal Clipboard carries it to every device on the account")
        #expect(!text.contains("NSPasteboard"),
                "the editor touches NSPasteboard directly; every secret copy must go through ClipboardClearing")
    }

    /// The two views that legitimately use `NSPasteboard` directly copy a
    /// *remediation command* — `brew upgrade age`, `chmod 600 …` — which is
    /// public text the user is meant to paste into a terminal and keep. Pinned
    /// so that a secret cannot quietly move into one of them.
    @Test("only remediation commands bypass it", arguments: [
        "Health/HealthFindingRow.swift", "Editor/KeyImportView.swift",
    ])
    func onlyCommandsBypass(_ relativePath: String) throws {
        let text = try source(relativePath)
        guard text.contains("NSPasteboard") else { return }
        #expect(text.contains("setString(command, forType: .string)"),
                "\(relativePath) writes something other than a remediation command straight to the pasteboard")
    }
}

/// Two more wirings that a mutation showed nothing depends on. Both are
/// source-text guards for the same reason as above: what is asserted is that a
/// call is present at a site, which no runtime probe can see. Comments are
/// stripped first.
@Suite("Editor wiring that nothing else observes")
struct EditorWiringCoverageTests {

    private static let editor = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/SopsUI/Editor/SecretEditorView.swift")

    private func source() throws -> String {
        OuterSidebarWiringTests.strippingComments(
            try String(contentsOf: Self.editor, encoding: .utf8))
    }

    /// Replacing `unsavedChanges.update(...)` with `_ = state` left all 658
    /// tests green. `QuitRequestTests` and `UnsavedChangesTrackerTests` both
    /// feed the tracker by hand; nothing hands the *shared* tracker to the
    /// editor and checks that editing marks it dirty. Unregistered, ⌘Q after an
    /// edit closes the app without asking — which is the entire reason
    /// `QuitRequest` exists.
    @Test("the editor registers its dirty state with the shared tracker")
    func editorRegistersWithTheTracker() throws {
        let text = try source()
        #expect(text.contains("unsavedChanges.update("),
                "the editor no longer reports its dirty state, so quitting after an edit will not ask")
        #expect(text.contains("isDirty: state.isDirty"),
                "the editor reports something other than its own dirty state to the tracker")
    }

    /// `shippedTimeoutIsThirtySeconds` pins the constant and `revealTimesOut`
    /// injects 80 ms; nothing connected the two, so the default could be
    /// changed to thirty *minutes* with both still green — and a revealed
    /// secret would sit on screen for half an hour.
    @Test("the shipped reveal timeout is the constant, not a second literal")
    func revealTimeoutDefaultIsTheConstant() throws {
        #expect(try source().contains("revealTimeout: Duration = SecretEditorView.revealTimeout"),
                "the reveal timeout's default no longer comes from the constant the tests pin")
    }
}
