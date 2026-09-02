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
        // SOPS-39 task 7: the copy button moved out of the row and into the
        // table's action cell, in its own file. The obligation followed it.
        let text = try source("Editor/SecretTableView.swift")
        #expect(text.contains("ClipboardClearing.copy("),
                "the editor no longer copies through ClipboardClearing: no deadline, no ConcealedType marker, and Universal Clipboard carries it to every device on the account")
        #expect(!text.contains("NSPasteboard"),
                "the table touches NSPasteboard directly; every secret copy must go through ClipboardClearing")
        // The editor and the inspector both hold decrypted values too, and
        // neither may reach the pasteboard on its own.
        for neighbour in ["Editor/SecretEditorView.swift", "Editor/SecretRowInspector.swift"] {
            #expect(!(try source(neighbour)).contains("NSPasteboard"),
                    "\(neighbour) touches NSPasteboard directly; every secret copy must go through ClipboardClearing")
        }
    }

    /// Ticket #6, claim 3: these two views used to bypass `ClipboardClearing`
    /// entirely for a *remediation command* — `chmod 600 <path>` — on the
    /// reasoning that it is "not a secret". That reasoning missed that the
    /// command carries the absolute path to the user's private age key file,
    /// which a clipboard manager's on-disk history or Universal Clipboard
    /// should not retain forever, unmarked, just because the string itself
    /// is not key material.
    ///
    /// The criterion is now explicit rather than "these two files may touch
    /// NSPasteboard": a remediation command still gets the concealed/transient
    /// markers and host-only scoping every other pasteboard write in this app
    /// gets, via `ClipboardClearing.copyWithoutAutoClear` — it only skips the
    /// *timer*, because the user pastes it into a terminal on their own
    /// schedule and an auto-clear would take back something they asked for.
    /// No file may reach `NSPasteboard` directly any more; that is the whole
    /// point of the fix.
    /// Since SOPS-41 the routing lives in one place, `CommandSnippetView`,
    /// and the two views build that instead of touching the pasteboard.
    @Test("remediation commands route through ClipboardClearing too, just without the timer")
    func remediationCommandsRouteThroughClipboardClearing() throws {
        let snippet = try source("Support/CommandSnippetView.swift")
        #expect(!snippet.contains("NSPasteboard"),
                "CommandSnippetView writes to NSPasteboard directly — remediation commands carry paths (e.g. to the private key file) and must go through ClipboardClearing like everything else")
        #expect(snippet.contains("ClipboardClearing.copyWithoutAutoClear(command)"),
                "CommandSnippetView no longer routes its command through ClipboardClearing.copyWithoutAutoClear")
    }

    @Test("the views that show a remediation command go through CommandSnippetView", arguments: [
        "Health/HealthFindingRow.swift", "Editor/KeyImportView.swift", "Guide/SetupGuideView.swift",
    ])
    func remediationViewsUseTheSnippetView(_ relativePath: String) throws {
        let text = try source(relativePath)
        #expect(!text.contains("NSPasteboard"), "\(relativePath) writes to NSPasteboard directly")
        #expect(text.contains("CommandSnippetView("),
                "\(relativePath) shows a command without CommandSnippetView, so its copy bypasses ClipboardClearing")
    }

    /// Ticket #6, claim 2's own doc comment says there is no public API to
    /// read `.currentHostOnly` back, so no runtime test can assert it — a gap
    /// this suite left completely open until now (none of the eight tests in
    /// `ClipboardClearingTests` mention it). Without this, a regression here
    /// pushes every secret copied through this app to every other Mac, iPhone
    /// and iPad on the Apple Account via Universal Clipboard, and nothing
    /// anywhere would go red. A source-text guard, same reasoning and same
    /// technique as `editorCopyIsRouted` above.
    @Test("copy and copyWithoutAutoClear both scope new contents to this host")
    func pasteboardWritesAreHostOnly() throws {
        let text = try source("Editor/ClipboardClearing.swift")
        #expect(text.contains("prepareForNewContents(with: .currentHostOnly)"),
                "no pasteboard write scopes new contents with .currentHostOnly any more — a secret copied through this app would be pushed to every device on the Apple Account via Universal Clipboard, where nothing in this process can ever clear it")
        // Both entry points must route through the one function that applies
        // that scoping, not duplicate their own pasteboard-writing logic —
        // two copies of this is exactly how one of them silently drifted
        // without the marker before.
        #expect(text.contains("write(value, to: pasteboard)"),
                "copy(_:clearingAfter:) no longer routes through the shared write(_:to:) helper that applies .currentHostOnly")
        #expect(text.contains("write(value, to: .general)"),
                "copyWithoutAutoClear(_:) no longer routes through the shared write(_:to:) helper that applies .currentHostOnly")
    }

    /// Ticket #6, claim 4: `defaultInterval` used to be a hardcoded
    /// `static let .seconds(30)` with nothing anywhere reading `UserDefaults`.
    /// A runtime test would have to touch `UserDefaults.standard` — the one
    /// dictionary every parallel test in this suite shares — to observe this,
    /// which is exactly the hazard `ClipboardClearIntervalPreferenceTests`
    /// avoids by using a dedicated suite per test. A source-text guard, same
    /// technique as this file's other checks, catches the same regression
    /// (someone reverting `defaultInterval` back to a frozen literal) without
    /// that risk.
    @Test("defaultInterval reads the UserDefaults-backed preference, not a frozen literal")
    func defaultIntervalReadsThePreference() throws {
        let text = try source("Editor/ClipboardClearing.swift")
        #expect(text.contains("ClipboardClearIntervalPreference.interval()"),
                "defaultInterval no longer reads ClipboardClearIntervalPreference — the clear delay is frozen again and a value set in UserDefaults stops being honoured")
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
