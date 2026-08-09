import Foundation
import Testing
@testable import SopsUI

/// Leaving "Projects" in the outer sidebar is leaving the open document.
///
/// This suite exists because it was not. `WorkspaceSwitchDecision.forSwitch`
/// had exactly two call sites, both inside `ProjectWorkspaceView` — the file
/// list and the project sidebar. The outer `NavigationSplitView`'s own
/// selection wrote straight through, and selecting About or Settings took
/// `.projects` out of the `detail:` switch, destroying the `@State` that held
/// the open document. No prompt, no warning, edits gone.
///
/// The compounding part, and the reason this ranked above the other findings
/// in its review: `SecretEditorView`'s `onDisappear` (SecretEditorView.swift:261) calls
/// `unsavedChanges.clear()`. So the same click also disarmed ⌘Q — the user
/// lost the document *and* the warning that would have named it.
@MainActor
@Suite("Leaving Projects asks the same question the other two exits ask")
struct OuterSidebarSwitchTests {

    // MARK: - The exit that was missing

    @Test("a dirty document turns About into a prompt, not a silent teardown")
    func dirtyDocumentBlocksAbout() {
        #expect(
            AppShell.sectionSwitchDecision(
                from: .projects, to: .about,
                documentIsDirty: true, saveIsInFlight: false) == .askAboutUnsavedChanges)
    }

    @Test("Settings is guarded exactly as About is — neither is the special case")
    func dirtyDocumentBlocksSettings() {
        #expect(
            AppShell.sectionSwitchDecision(
                from: .projects, to: .settings,
                documentIsDirty: true, saveIsInFlight: false) == .askAboutUnsavedChanges)
    }

    @Test("a clean document leaves without ceremony")
    func cleanDocumentProceeds() {
        for target in [AppShell.Section.about, .settings] {
            #expect(
                AppShell.sectionSwitchDecision(
                    from: .projects, to: target,
                    documentIsDirty: false, saveIsInFlight: false) == .proceed)
        }
    }

    // MARK: - The window the first fix opened

    /// A save in flight is not "dirty, so ask" — during a save `isDirty` is
    /// still set, and a prompt inside that window has two wrong answers:
    /// "Save" reports a failure over a save that is in fact succeeding, and
    /// "Discard" tears the view down while the write completes anyway. Both
    /// were real, measured in a 133–380 ms window, before
    /// `.waitForSaveInFlight` existed.
    @Test("a save in flight defers the decision rather than prompting inside it")
    func saveInFlightDefers() {
        #expect(
            AppShell.sectionSwitchDecision(
                from: .projects, to: .about,
                documentIsDirty: true, saveIsInFlight: true) == .waitForSaveInFlight)
    }

    /// Saving is answered before dirty, so a save whose document has somehow
    /// already been adopted still defers rather than proceeding into a
    /// half-finished write.
    @Test("saving outranks clean, not just dirty")
    func saveInFlightOutranksClean() {
        #expect(
            AppShell.sectionSwitchDecision(
                from: .projects, to: .about,
                documentIsDirty: false, saveIsInFlight: true) == .waitForSaveInFlight)
    }

    // MARK: - Not every selection write is a departure

    @Test("re-selecting the current section is not a switch, dirty or not")
    func sameSectionIsNotASwitch() {
        for dirty in [true, false] {
            #expect(
                AppShell.sectionSwitchDecision(
                    from: .projects, to: .projects,
                    documentIsDirty: dirty, saveIsInFlight: false) == .alreadyThere)
        }
    }

    /// About → Settings never passes through the editor, so a stale `isDirty`
    /// must not strand the user in a prompt about a document that is not on
    /// screen. It cannot happen today — `onDisappear` clears the tracker — but
    /// that is the very interaction that made this bug worse, so it is pinned
    /// rather than assumed.
    @Test("moving between two non-Projects sections is never a document question")
    func betweenNonProjectSectionsProceeds() {
        #expect(
            AppShell.sectionSwitchDecision(
                from: .about, to: .settings,
                documentIsDirty: false, saveIsInFlight: false) == .proceed)
    }

    // MARK: - One rule, three exits

    /// The point of the fix is not that this exit has a guard; it is that it
    /// has the *same* guard. A second, separately-written notion of "is
    /// anything at stake" is how the ⌘Q path and the Dock-icon path came to
    /// disagree, and how this exit came to have none at all.
    @Test("the section decision is the same rule the file and project switches use")
    func sameRuleAsTheOtherExits() {
        let cases: [(Bool, Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        for (dirty, saving) in cases {
            let section = AppShell.sectionSwitchDecision(
                from: .projects, to: .about,
                documentIsDirty: dirty, saveIsInFlight: saving)
            let file = WorkspaceSwitchDecision.forSwitch(
                from: "a", to: "b",
                documentIsDirty: dirty, saveIsInFlight: saving)
            #expect(section == file, "dirty=\(dirty) saving=\(saving)")
        }
    }
}

/// The routing itself, which the suite above cannot reach.
///
/// `sectionSwitchDecision` is a pure function and tests of it say nothing about
/// whether the sidebar consults it. A review proved the gap: reverting
/// `AppShell`'s two `guardedSelection` uses to `$selection` — the exact bug —
/// left all 577 tests green, because the decision function was still correct
/// and still tested.
///
/// This reads the source. That is weaker than driving the binding, and it is
/// what is available: `selection` is `@State`, so writing it outside a view
/// body does nothing observable, and `AppShell`'s body cannot be evaluated in a
/// test. The repo already uses the technique for the same reason in
/// `ScrollOverflowFadeCoverageTests`. It asserts the wiring is present, not
/// that SwiftUI honours it.
@Suite("The outer sidebar's selection is wired through the guard")
struct OuterSidebarWiringTests {

    /// `AppShell.swift` with `//` comments removed.
    ///
    /// Stripping matters: a review defeated every assertion in this suite by
    /// gutting `guardedSelection`'s setter and leaving the guarded form as a
    /// comment on the line above. The bug was fully restored — a click on About
    /// discarded a dirty document without asking — and all four string checks
    /// still passed, because `#filePath` is read as plain text and a comment is
    /// text too. The suite's own doc comment had warned that checking the name
    /// and not the body is how a source-level test becomes decoration; checking
    /// the body as *text* was one step better and still not enough.
    /// Removes `/* */` blocks as well as `//` line comments.
    ///
    /// The `//`-only version was defeated one round later in the obvious way:
    /// wrap the guarded form in `/* */` above the gutted code and every check
    /// passed while a click on About discarded a dirty document. Still naive —
    /// it does not know about string literals containing `//` — which is one
    /// more reason the real guard is behavioural.
    static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                guard let close = rest.range(of: "*/") else { break }
                index = close.upperBound
                inBlock = false
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                guard let newline = rest.firstIndex(of: "\n") else { break }
                index = newline
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }

    private static var appShellSource: String {
        get throws {
            let raw = try String(
                contentsOfFile: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("Sources/SopsUI/AppShell.swift").path,
                encoding: .utf8)
            return Self.strippingComments(raw)
        }
    }

    @Test("no selection binding in the outer sidebar bypasses the guard")
    func noRawSelectionBinding() throws {
        let source = try Self.appShellSource

        // `$selection` passed to a subview or a List is the unguarded form.
        // The `Binding(get:set:)` inside `guardedSelection` reads `selection`
        // directly and writes through `requestSectionSwitch`, so it does not
        // use the `$` projection at all — which makes any occurrence of it a
        // bypass.
        let raw = source.components(separatedBy: "$selection").count - 1
        #expect(
            raw == 0,
            "AppShell passes $selection somewhere — that write skips WorkspaceSwitchDecision and destroys an open dirty document with no prompt")
    }

    @Test("both sidebar controls take the guarded binding")
    func bothControlsAreGuarded() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains("List(selection: guardedSelection)"),
            "the sidebar List no longer takes guardedSelection")
        #expect(
            source.contains("PinnedSidebarRow(section: section, selection: guardedSelection)"),
            "the pinned rows (About, Settings) no longer take guardedSelection")
    }

    @Test("the guard is disabled during a save, like the other two exits")
    func disabledDuringSave() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains(".disabled(unsavedChanges.isSaving)"),
            "the outer sidebar stays live during a save")
    }

    /// That the controls are wired to the guarded binding at all.
    ///
    /// This is the one claim still made about source text, and it is the
    /// weakest kind: it says the binding is built from the request handler,
    /// not what happens when someone writes to it. What happens is now checked
    /// by running it — see `GuardedSelectionBindingTests` at the end of this
    /// file, which exists because three rounds of increasingly clever string
    /// matching were each defeated by a slightly cleverer comment.
    ///
    /// Kept anyway: the behavioural test cannot see whether anyone hands the
    /// binding to the `List`. Between them they cover both halves.
    @Test("the guarded binding is built from the request handler")
    func bindingIsBuiltFromTheRequestHandler() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains("Self.makeGuardedSelection("),
            "guardedSelection no longer goes through makeGuardedSelection")
        #expect(
            source.contains("request: { requested in requestSectionSwitch(to: requested) }"),
            "the binding's request handler no longer calls requestSectionSwitch — a click on About writes selection directly and the open document dies unasked")
        #expect(
            source.contains("switch Self.sectionSwitchDecision("),
            "requestSectionSwitch no longer consults sectionSwitchDecision")
    }
}


/// The binding, driven rather than read.
///
/// Three rounds of source-text tests each answered the previous attack and
/// invited the next: check the name → gut the setter; check the setter's text
/// → move the literal into a `//` comment; strip `//` → use `/* */`. The last
/// of those left every assertion in this file green while a click on About
/// discarded a dirty document without asking.
///
/// A `Binding` can be written to from a test. That closes the whole family.
@MainActor
@Suite("The guarded binding routes writes, verified by writing to it")
struct GuardedSelectionBindingTests {

    @Test("every write goes to the request handler, never straight to selection")
    func writesAreRouted() {
        var currentValue = AppShell.Section.projects
        var requested: [AppShell.Section] = []

        let binding = AppShell.makeGuardedSelection(
            current: { currentValue },
            request: { requested.append($0) })

        binding.wrappedValue = .about
        binding.wrappedValue = .settings

        #expect(
            requested == [.about, .settings],
            "a write bypassed the request handler — that write is a dirty document dying unasked")
        #expect(
            currentValue == .projects,
            "the binding mutated the selection directly instead of asking; the guard can no longer refuse")
    }

    @Test("the getter reflects the live value rather than a captured copy")
    func getterIsLive() {
        var currentValue = AppShell.Section.projects
        let binding = AppShell.makeGuardedSelection(current: { currentValue }, request: { _ in })

        #expect(binding.wrappedValue == .projects)
        currentValue = .settings
        #expect(
            binding.wrappedValue == .settings,
            "the binding captured the value once, so a refused switch would not visually revert")
    }
}
