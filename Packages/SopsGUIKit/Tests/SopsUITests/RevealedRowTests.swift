import AppKit
import Foundation
import SopsEngine
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

/// Reveal — the one piece of editor state whose failure mode is "a secret the
/// user never asked to see is on screen in plaintext".
///
/// Before this file, `grep -r 'revealedRowIDs\|isRevealed\|toggleReveal'` over
/// `Tests/` and `SnapshotTool/` returned nothing: the whole feature was
/// unverified, and that is how the aliasing defect below survived. An
/// untested security-relevant UI state is not a gap in coverage, it is the
/// reason there was something to find.
///
/// Two halves, deliberately:
///
/// 1. `RevealedRows`/`RowSelection` driven directly — the rule itself, exactly,
///    with no window and nothing to flake.
/// 2. The rule driven through a **real, laid-out `SecretEditorView`** and read
///    back out of the accessibility tree, because the rule being right is not
///    the same claim as the view applying it. The probe is the same
///    never-shown `NSHostingView`/`NSWindow` technique `AccessibilityTreeTests`
///    established (see `Snapshot.swift`'s header for why it works headless),
///    with one addition: the host is kept alive between walks so the model can
///    be changed *underneath a view that already has reveal state*, which is
///    the only way the defect can be reproduced at all.

// MARK: - The rule, on its own

@Suite("what a reveal is a claim about")
struct RevealedRowsTests {

    @Test("a revealed row reads as revealed in the generation it was revealed in")
    func revealHoldsWithinItsGeneration() {
        var revealed = RevealedRows()
        revealed.reveal("ports:1:1", in: 7)
        #expect(revealed.contains("ports:1:1", in: 7))
    }

    /// The defect, as a single assertion. Removing a list element renumbers
    /// the rest, so `ports.1` stops naming the value it named — and the
    /// reveal must not follow the id across.
    @Test("a reveal is not a claim about any other generation")
    func revealIsVoidInAnotherGeneration() {
        var revealed = RevealedRows()
        revealed.reveal("ports:1:1", in: 7)
        #expect(!revealed.contains("ports:1:1", in: 8))
        #expect(!revealed.contains("ports:1:1", in: 6))
    }

    /// The subtle half. A prune written as "drop ids that are no longer
    /// present" would keep this one — the id *is* still present — and that is
    /// precisely the case that shows a different secret.
    @Test("an id that survives a renumbering is still not carried across")
    func survivingIDIsNotCarriedAcross() {
        var revealed = RevealedRows()
        revealed.reveal("0:5:ports:1:1", in: 1)
        // Same id, next generation: the row it names now holds what used to be
        // at index 2.
        #expect(!revealed.contains("0:5:ports:1:1", in: 2))
    }

    @Test("revealing in a new generation does not resurrect the old generation's reveals")
    func revealingAgainStartsFromNothing() {
        var revealed = RevealedRows()
        revealed.reveal("a", in: 1)
        revealed.reveal("b", in: 2)
        #expect(revealed.contains("b", in: 2))
        #expect(!revealed.contains("a", in: 2), "the earlier generation's reveal came back")
    }

    @Test("toggling reveals and hides within one generation")
    func toggleRoundTrips() {
        var revealed = RevealedRows()
        revealed.toggle("a", in: 3)
        #expect(revealed.contains("a", in: 3))
        revealed.toggle("a", in: 3)
        #expect(!revealed.contains("a", in: 3))
        #expect(revealed.isEmpty)
    }

    /// Toggling an id that is only "revealed" in an older generation must
    /// reveal it, not hide it — the user is looking at a masked row and
    /// clicking the eye.
    @Test("toggling a row whose reveal has been voided reveals it rather than hiding it")
    func toggleAfterInvalidationReveals() {
        var revealed = RevealedRows()
        revealed.reveal("a", in: 1)
        revealed.toggle("a", in: 2)
        #expect(revealed.contains("a", in: 2))
    }

    @Test("hideAll leaves nothing revealed in any generation")
    func hideAllClearsEverything() {
        var revealed = RevealedRows()
        revealed.reveal("a", in: 1)
        revealed.reveal("b", in: 1)
        revealed.hideAll()
        #expect(revealed.isEmpty)
        #expect(!revealed.contains("a", in: 1))
    }

    @Test("hiding the last revealed row leaves the value equal to a fresh one")
    func hidingTheLastRowIsIndistinguishableFromFresh() {
        var revealed = RevealedRows()
        revealed.reveal("a", in: 1)
        revealed.hide("a", in: 1)
        #expect(revealed == RevealedRows())
    }

    @Test("an editor built with nothing revealed is not revealing anything")
    func emptyInitialSetRevealsNothing() {
        let revealed = RevealedRows(revealing: [], in: 9)
        #expect(revealed == RevealedRows())
        #expect(!revealed.contains("a", in: 9))
    }

    @Test("an editor built with rows revealed reveals exactly those, in that generation")
    func initialSetIsScopedLikeAnyOtherReveal() {
        let revealed = RevealedRows(revealing: ["a", "b"], in: 9)
        #expect(revealed.contains("a", in: 9))
        #expect(revealed.contains("b", in: 9))
        #expect(!revealed.contains("a", in: 10), "a seam that skipped the rule could not review it")
    }
}

/// The selection aliases exactly as the reveal does — same path-derived id,
/// held across the same renumbering — so it is scoped the same way. The cost
/// of getting this one wrong is the `−` button deleting a row other than the
/// one the user can see is selected.
@Suite("what a selection is a claim about")
struct RowSelectionTests {

    @Test("a selection holds within its generation")
    func selectionHolds() {
        var selection = RowSelection()
        selection.select("ports:1:0", in: 4)
        #expect(selection.id(in: 4) == "ports:1:0")
    }

    @Test("a selection is void once the rows may have been renumbered")
    func selectionIsVoidInAnotherGeneration() {
        var selection = RowSelection()
        selection.select("ports:1:0", in: 4)
        #expect(selection.id(in: 5) == nil, "the next `−` would delete a different row")
    }

    @Test("deselecting reads as nothing selected in every generation")
    func deselectingClears() {
        var selection = RowSelection()
        selection.select("a", in: 1)
        selection.select(nil, in: 1)
        #expect(selection.id(in: 1) == nil)
        #expect(selection == RowSelection())
    }

    @Test("clear leaves nothing selected")
    func clearClears() {
        var selection = RowSelection()
        selection.select("a", in: 1)
        selection.clear()
        #expect(selection.id(in: 1) == nil)
    }

    @Test("an editor built with a row selected selects exactly that row")
    func initialSelectionIsScoped() {
        let selection = RowSelection("a", in: 2)
        #expect(selection.id(in: 2) == "a")
        #expect(selection.id(in: 3) == nil)
    }
}

// MARK: - The rule, through a real editor

/// A laid-out `SecretEditorView` whose accessibility tree can be read more
/// than once, with the model changing in between.
///
/// `AccessibilityTreeTests`' `AXProbe` builds a host, walks it and throws it
/// away, which is right for the question it asks and useless for this one:
/// reveal lives in the view's `@State`, so a fresh host is a fresh, unrevealed
/// editor. Keeping the host means the second walk is of the *same* view, with
/// the reveal it already had — which is the only arrangement in which "the
/// reveal followed the id onto a different secret" can be observed at all.
///
/// Duplicated from `AXProbe` rather than shared, for the reason that file
/// already states about its own `AgeKey`: both are file-private by design, and
/// a shared probe is how one suite's change silently alters another's meaning.
@MainActor
private final class EditorHost {

    struct Node {
        let role: String
        let label: String
        let value: String
    }

    private static let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")

    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init(size: CGSize, _ build: @MainActor () -> AnyView) {
        // Set here and again before every walk. Without it SwiftUI never
        // builds accessibility elements at all and every assertion below
        // passes by finding nothing — `AccessibilityTreeTests` says the same
        // thing about its own probe. Re-set per walk because it is a
        // process-wide switch that other suites turn back off; both the set
        // and the walk run on this actor with no suspension between them, so
        // nothing can interleave.
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhanced)
        hosting = NSHostingView(rootView: build())
        hosting.frame = CGRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        settle()
    }

    /// Gives SwiftUI a chance to apply anything the model changed since the
    /// last walk, then relays out. The `await` is what lets the update SwiftUI
    /// scheduled on this actor actually run — without it the host would still
    /// be showing the previous rows, and `rowsOnScreen` below is the canary
    /// that says so rather than letting a test pass on a stale view.
    func settleAfterAModelChange() async {
        try? await Task.sleep(for: .milliseconds(120))
        settle()
    }

    func settle() {
        // Twice with a display in between, for the reason `Snapshot.render`
        // does it: the first pass sizes the host, the second lets content that
        // depends on that size settle.
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        hosting.layoutSubtreeIfNeeded()
    }

    func nodes() -> [Node] {
        NSApplication.shared.accessibilitySetValue(true, forAttribute: Self.enhanced)
        var found: [Node] = []
        var seen: Set<ObjectIdentifier> = []
        Self.walk(hosting, depth: 0, seen: &seen, into: &found)

        // Same reasoning as `AccessibilityTreeTests.AXProbe.tree`, corrected
        // the same way — but `EditorHost` is one of the two probes (with
        // `RecipientAccessGatingTests.GatingHost`) where
        // `AXEnhancedUserInterface` really *is* measured to get cleared out
        // from under a live walk: ~90 times across a full suite run, because
        // this host is kept alive and re-walked while a concurrent probe's
        // own `defer` can flip the process-wide flag off in between. That
        // clearing turned out to cost nothing: a control walk, a walk
        // cleared then relaid out, and a fresh walk all returned the
        // identical 92 nodes on a 12-row `List` — only a walk built with the
        // flag off from the very start undercounts (68, not 0). So even
        // here, a non-empty tree is not evidence the flag stayed on — this
        // assertion is not a diagnostic for that mechanism, just a minimal
        // sanity check that nothing more total went wrong. Kept once, here,
        // so `text()`, `rowsOnScreen()` and `valueFields()` — everything
        // below that reads through `nodes()` — inherit it for free instead
        // of failing on a confusing "the row the test revealed is not
        // actually revealed" that reads like a defect in reveal itself.
        #expect(!found.isEmpty,
                "EditorHost.nodes() saw a completely empty accessibility tree — that is never a valid result for a rendered view (even a walk built with AXEnhancedUserInterface off from the start still returns most of the tree; see this function's comment). Something more total than the usual bug is wrong here.")
        return found
    }

    /// Everything the tree says, as one string — what a test asks "is this
    /// secret anywhere on screen" of.
    func text() -> String {
        nodes().map { "\($0.label)\u{1}\($0.value)" }.joined(separator: "\n")
    }

    /// The key paths the editor is currently listing, read out of the tree.
    /// Used as the canary: if the host did not pick up a model change, this
    /// still reports the old rows and the test fails on it instead of passing
    /// against a stale view.
    func rowsOnScreen() -> Set<String> {
        Set(nodes().map(\.value).filter { $0.hasPrefix("ports.") })
    }

    /// The masked value fields, so a test can say "everything is masked"
    /// rather than only "this particular secret is absent".
    func valueFields() -> [String] {
        nodes().filter { $0.role == "AXTextField" }.map(\.value)
    }

    func finish() {
        NSApplication.shared.accessibilitySetValue(false, forAttribute: Self.enhanced)
        window.contentView = nil
    }

    private static func walk(
        _ element: Any, depth: Int, seen: inout Set<ObjectIdentifier>, into nodes: inout [Node]
    ) {
        guard depth < 24 else { return }
        let object = element as AnyObject
        guard seen.insert(ObjectIdentifier(object)).inserted else { return }

        func string(_ name: String) -> String {
            let selector = Selector((name))
            guard object.responds(to: selector),
                  let raw = object.perform(selector)?.takeUnretainedValue() else { return "" }
            if let text = raw as? String { return text }
            if let role = raw as? NSAccessibility.Role { return role.rawValue }
            return "\(raw)"
        }

        let node = Node(
            role: string("accessibilityRole"), label: string("accessibilityLabel"),
            value: string("accessibilityValue"))
        if !(node.role.isEmpty && node.label.isEmpty && node.value.isEmpty) {
            nodes.append(node)
        }

        var children: [Any] = []
        for name in ["accessibilityChildren", "accessibilityRows", "accessibilityContents"] {
            let selector = Selector((name))
            if object.responds(to: selector),
               let more = object.perform(selector)?.takeUnretainedValue() as? [Any] {
                children += more
            }
        }
        // The value field is a real AppKit view, so it carries its
        // accessibility on itself and never appears among the element
        // children. Missing this branch makes every assertion here vacuous.
        if let view = element as? NSView { children += view.subviews }

        for child in children { walk(child, depth: depth + 1, seen: &seen, into: &nodes) }
    }
}

/// The three list entries. Distinct, obviously-fake, and long enough that a
/// substring search cannot match one inside another.
private let revealFirst = "aaa-first-EXAMPLE"
private let revealSecond = "bbb-second-EXAMPLE"
private let revealThird = "ccc-third-EXAMPLE"

private let revealPlaintext = """
    ports:
        - \(revealFirst)
        - \(revealSecond)
        - \(revealThird)
    """

/// Not `@MainActor` at the suite level, and `.serialized`, for the reasons
/// `AccessibilityTreeTests`' doc comment sets out: the fixture work is a real
/// `age-keygen` subprocess plus a real sops encrypt, and holding the main
/// actor across those starves `ClipboardClearingTests`' clear timer, which
/// runs concurrently.
@Suite("a revealed row, through the editor", .serialized)
struct RevealedRowTests {

    private func document() async throws -> (SecretDocumentViewModel, RevealWritten) {
        let key = try RevealAgeKey.generate()
        let encrypted = try SopsBridge.encryptYAML(revealPlaintext, recipients: [key.public])
        let written = RevealWritten()
        let model = try await MainActor.run {
            let store = SessionKeyStore()
            try store.importKey(key.private)
            return SecretDocumentViewModel(
                fileURL: URL(fileURLWithPath: "/dev/null/reveal.yaml"),
                keyStore: store,
                readFile: { _ in encrypted },
                fingerprintFile: { _ in nil },
                writeFile: { contents, _, _ in
                    written.contents = contents
                    return nil
                })
        }
        await model.load()
        #expect(await model.loadState == .loaded, "the fixture document did not decrypt")
        return (model, written)
    }

    @MainActor
    private func rowID(_ model: SecretDocumentViewModel, _ index: Int) throws -> String {
        try #require(model.rows.first { $0.path == ["ports", String(index)] }).id
    }

    /// The finding, end to end, in the exact four gestures the report names:
    /// reveal `ports.1`, select `ports.0`, press `−`, Save — and the third
    /// list entry must not end up on screen in plaintext.
    @Test("a reveal does not follow its row id across a shape-changing save")
    func revealDoesNotSurviveARenumbering() async throws {
        let (model, written) = try await document()

        let host = try await MainActor.run {
            let revealed = try rowID(model, 1)
            let selected = try rowID(model, 0)
            return EditorHost(size: CGSize(width: 760, height: 420)) {
                AnyView(
                    SecretEditorView(
                        viewModel: model, fileName: "reveal.yaml",
                        unsavedChanges: UnsavedChangesTracker(),
                        initiallySelectedRowID: selected,
                        initiallyRevealedRowIDs: [revealed]))
            }
        }
        defer { Task { @MainActor in host.finish() } }

        // Canary. If reveal did not work, nothing below can fail for the right
        // reason: an editor that reveals nothing trivially reveals no secret.
        await MainActor.run {
            #expect(host.rowsOnScreen() == ["ports.0", "ports.1", "ports.2"],
                    "the tree did not populate — every assertion here would be vacuous")
            #expect(host.text().contains(revealSecond),
                    "the row the test revealed is not actually revealed")
        }

        // `−` on the *first* entry, then Save. Removing index 0 renumbers the
        // rest: what was `ports.1` is now `ports.0` and what was `ports.2` is
        // now `ports.1`.
        await MainActor.run {
            let first = try? rowID(model, 0)
            model.removeRow(id: first ?? "")
        }
        #expect(await model.save() == .saved)
        #expect(await written.contents != nil, "the fixture save never reached the writer")
        await host.settleAfterAModelChange()

        await MainActor.run {
            // Canary again, this time that the view really re-read the model.
            #expect(host.rowsOnScreen() == ["ports.0", "ports.1"],
                    "the host is still showing the pre-save rows — this proves nothing")
            #expect(!host.text().contains(revealThird),
                    "a secret the user never revealed is on screen in plaintext")
            #expect(!host.text().contains(revealSecond),
                    "a reveal survived a save that renumbered the rows out from under it")
            #expect(host.valueFields().allSatisfy { $0.allSatisfy { $0 == "•" } },
                    "some value field is showing something other than the mask")
        }
    }

    /// The other side of the same rule, and the one that would make the fix
    /// useless if it went the wrong way: typing into a revealed row cannot
    /// move any path, so the row must stay revealed. A masked field is
    /// `.disabled`, so masking mid-edit would take the keyboard away.
    @Test("a reveal survives typing into the revealed row")
    func revealSurvivesAnOrdinaryEdit() async throws {
        let (model, _) = try await document()

        let host = try await MainActor.run {
            let revealed = try rowID(model, 1)
            return EditorHost(size: CGSize(width: 760, height: 420)) {
                AnyView(
                    SecretEditorView(
                        viewModel: model, fileName: "reveal.yaml",
                        unsavedChanges: UnsavedChangesTracker(),
                        initiallyRevealedRowIDs: [revealed]))
            }
        }
        defer { Task { @MainActor in host.finish() } }

        await MainActor.run {
            #expect(host.text().contains(revealSecond),
                    "the tree did not populate — this test would be vacuous")
        }

        let edited = "bbb-edited-EXAMPLE"
        try await MainActor.run {
            model.update(rowID: try rowID(model, 1), to: edited)
        }
        await host.settleAfterAModelChange()

        await MainActor.run {
            #expect(model.isDirty, "the fixture edit did not take")
            #expect(host.text().contains(edited),
                    "the row the user is typing into was masked out from under them")
        }
    }

    /// A revealed value is plaintext on a screen the user has stopped looking
    /// at. `Cmd-Tab` is the ordinary way that happens.
    @Test("the app losing the front-app position hides every revealed value")
    func resigningActiveHidesEverything() async throws {
        let (model, _) = try await document()

        let host = try await MainActor.run {
            let revealed = try rowID(model, 1)
            return EditorHost(size: CGSize(width: 760, height: 420)) {
                AnyView(
                    SecretEditorView(
                        viewModel: model, fileName: "reveal.yaml",
                        unsavedChanges: UnsavedChangesTracker(),
                        initiallyRevealedRowIDs: [revealed]))
            }
        }
        defer { Task { @MainActor in host.finish() } }

        await MainActor.run {
            #expect(host.text().contains(revealSecond),
                    "the tree did not populate — this test would be vacuous")
            NotificationCenter.default.post(
                name: NSApplication.didResignActiveNotification,
                object: NSApplication.shared)
        }
        await host.settleAfterAModelChange()

        await MainActor.run {
            #expect(host.rowsOnScreen() == ["ports.0", "ports.1", "ports.2"],
                    "the host stopped rendering rows — this proves nothing")
            #expect(!host.text().contains(revealSecond),
                    "a revealed secret stayed on screen after the app went to the background")
        }
    }

    /// The same for `Cmd-H`, which does not post `didResignActive` on its own.
    @Test("hiding the app hides every revealed value")
    func hidingTheAppHidesEverything() async throws {
        let (model, _) = try await document()

        let host = try await MainActor.run {
            let revealed = try rowID(model, 2)
            return EditorHost(size: CGSize(width: 760, height: 420)) {
                AnyView(
                    SecretEditorView(
                        viewModel: model, fileName: "reveal.yaml",
                        unsavedChanges: UnsavedChangesTracker(),
                        initiallyRevealedRowIDs: [revealed]))
            }
        }
        defer { Task { @MainActor in host.finish() } }

        await MainActor.run {
            #expect(host.text().contains(revealThird),
                    "the tree did not populate — this test would be vacuous")
            NotificationCenter.default.post(
                name: NSApplication.didHideNotification, object: NSApplication.shared)
        }
        await host.settleAfterAModelChange()

        await MainActor.run {
            #expect(!host.text().contains(revealThird),
                    "a revealed secret stayed on screen after the app was hidden")
        }
    }

    /// The timeout, which is what closes the `+` sheet's hole: a row added
    /// through the sheet is revealed on purpose, and used to stay revealed for
    /// the rest of the session. 80 ms here rather than the real
    /// `SecretEditorView.revealTimeout`, which is 30 s.
    @Test("a revealed value hides itself after the timeout")
    func revealTimesOut() async throws {
        let (model, _) = try await document()

        let host = try await MainActor.run {
            let revealed = try rowID(model, 1)
            return EditorHost(size: CGSize(width: 760, height: 420)) {
                AnyView(
                    SecretEditorView(
                        viewModel: model, fileName: "reveal.yaml",
                        unsavedChanges: UnsavedChangesTracker(),
                        initiallyRevealedRowIDs: [revealed],
                        revealTimeout: .milliseconds(80)))
            }
        }
        defer { Task { @MainActor in host.finish() } }

        await MainActor.run {
            #expect(host.text().contains(revealSecond),
                    "the tree did not populate — this test would be vacuous")
        }

        try? await Task.sleep(for: .milliseconds(500))
        await host.settleAfterAModelChange()

        await MainActor.run {
            #expect(host.rowsOnScreen() == ["ports.0", "ports.1", "ports.2"],
                    "the host stopped rendering rows — this proves nothing")
            #expect(!host.text().contains(revealSecond),
                    "a revealed secret was still on screen well past its timeout")
        }
    }

    /// The real timeout is not the test's timeout. A default of zero, or of
    /// something absurd, would make the test above pass and the app wrong.
    @Test("the shipped reveal timeout is the ~30s PROPOSAL.md sets for a copied secret")
    func shippedTimeoutIsThirtySeconds() {
        #expect(SecretEditorView.revealTimeout == .seconds(30))
    }
}

/// Where the fixture's saved bytes go. `/dev/null/reveal.yaml` is not a real
/// path and nothing here may create one.
@MainActor
private final class RevealWritten {
    var contents: String?
}

/// A throwaway age identity from the real `age-keygen`. Mirrors the same
/// helper in `AccessibilityTreeTests` and `WorkspaceSwitchDecisionTests` —
/// duplicated for the reason both of those state.
private struct RevealAgeKey {
    let `private`: String
    let `public`: String

    static func generate() throws -> RevealAgeKey {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in output.split(separator: "\n") {
            if line.hasPrefix("AGE-SECRET-KEY-") { priv = String(line) }
            if line.hasPrefix("# public key: ") { pub = String(line.dropFirst("# public key: ".count)) }
        }
        struct Failure: Error {}
        guard !priv.isEmpty, !pub.isEmpty else { throw Failure() }
        return RevealAgeKey(private: priv, public: pub)
    }
}
