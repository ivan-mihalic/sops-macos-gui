import Foundation
import SopsProjects
import Testing
@testable import SopsUI

/// Leaving an open document is leaving an open document, whichever row you
/// click.
///
/// This suite exists because that was not true. `WorkspaceSwitchDecision
/// .forSwitch` had exactly two call sites, both inside the old
/// `ProjectWorkspaceView` — the file list and the project sidebar. The outer
/// `NavigationSplitView`'s own selection wrote straight through, and
/// selecting About or Settings took `.projects` out of the `detail:` switch,
/// destroying the `@State` that held the open document. No prompt, no
/// warning, edits gone.
///
/// The compounding part, and the reason this ranked above the other findings
/// in its review: `SecretEditorView`'s `onDisappear` calls
/// `unsavedChanges.clear()`. So the same click also disarmed ⌘Q — the user
/// lost the document *and* the warning that would have named it.
///
/// Since SOPS-39 task 6 there is one selection value and one gate
/// (`WorkspaceSwitchGate`), so these read as questions about
/// `WorkspaceSelection` rather than about an outer `Section` enum that no
/// longer exists. The scenarios are unchanged.
@MainActor
@Suite("Leaving a document asks the same question whichever row you click")
struct OuterSidebarSwitchTests {

    private static let project = StoredProject.ID()
    private static let openFile = WorkspaceSelection.file(
        project: project, url: URL(fileURLWithPath: "/p/secrets.yaml"))

    // MARK: - The exit that was missing

    @Test("a dirty document turns About into a prompt, not a silent teardown")
    func dirtyDocumentBlocksAbout() {
        #expect(
            WorkspaceSwitchGate.decision(
                from: Self.openFile, to: .about,
                documentIsDirty: true, saveIsInFlight: false) == .askAboutUnsavedChanges)
    }

    @Test("Settings is guarded exactly as About is — neither is the special case")
    func dirtyDocumentBlocksSettings() {
        #expect(
            WorkspaceSwitchGate.decision(
                from: Self.openFile, to: .settings,
                documentIsDirty: true, saveIsInFlight: false) == .askAboutUnsavedChanges)
    }

    /// And neither is the *project's own* row, its Access panel, or another
    /// project's file — three destinations the four-column window needed
    /// three separate guards to cover, one of which it shipped without.
    @Test("every destination leaving a dirty document asks, not just About and Settings")
    func everyDestinationAsks() {
        let destinations: [WorkspaceSelection] = [
            .about, .settings,
            .projectHome(Self.project),
            .access(project: Self.project),
            .file(project: Self.project, url: URL(fileURLWithPath: "/p/other.yaml")),
            .file(project: StoredProject.ID(), url: URL(fileURLWithPath: "/q/other.yaml")),
        ]
        for destination in destinations {
            #expect(
                WorkspaceSwitchGate.decision(
                    from: Self.openFile, to: destination,
                    documentIsDirty: true, saveIsInFlight: false) == .askAboutUnsavedChanges,
                "\(destination) leaves a dirty document without asking")
        }
    }

    @Test("a clean document leaves without ceremony")
    func cleanDocumentProceeds() {
        for target in [WorkspaceSelection.about, .settings] {
            #expect(
                WorkspaceSwitchGate.decision(
                    from: Self.openFile, to: target,
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
            WorkspaceSwitchGate.decision(
                from: Self.openFile, to: .about,
                documentIsDirty: true, saveIsInFlight: true) == .waitForSaveInFlight)
    }

    /// Saving is answered before dirty, so a save whose document has somehow
    /// already been adopted still defers rather than proceeding into a
    /// half-finished write.
    @Test("saving outranks clean, not just dirty")
    func saveInFlightOutranksClean() {
        #expect(
            WorkspaceSwitchGate.decision(
                from: Self.openFile, to: .about,
                documentIsDirty: false, saveIsInFlight: true) == .waitForSaveInFlight)
    }

    // MARK: - Not every selection write is a departure

    @Test("re-selecting the current row is not a switch, dirty or not")
    func sameSelectionIsNotASwitch() {
        for dirty in [true, false] {
            #expect(
                WorkspaceSwitchGate.decision(
                    from: Self.openFile, to: Self.openFile,
                    documentIsDirty: dirty, saveIsInFlight: false) == .alreadyThere)
        }
    }

    /// About → Settings never passes through the editor, so a stale
    /// `isDirty` must not strand the user in a prompt about a document that
    /// is not on screen. `WorkspaceSwitchGate.decision` guarantees it
    /// structurally — it only forwards `documentIsDirty` when the selection
    /// being *left* is itself a document — rather than relying on the tracker
    /// having been cleared, which is the very interaction that made this bug
    /// worse.
    @Test("moving between two non-document screens is never a document question")
    func betweenNonDocumentScreensProceeds() {
        #expect(
            WorkspaceSwitchGate.decision(
                from: .about, to: .settings,
                documentIsDirty: true, saveIsInFlight: false) == .proceed)
    }

    // MARK: - One rule, every exit

    /// The point of the fix is not that this exit has a guard; it is that it
    /// has the *same* guard. A second, separately-written notion of "is
    /// anything at stake" is how the ⌘Q path and the Dock-icon path came to
    /// disagree, and how this exit came to have none at all.
    @Test("the workspace decision is the same rule every other exit uses")
    func sameRuleAsTheOtherExits() {
        let cases: [(Bool, Bool)] = [(false, false), (true, false), (false, true), (true, true)]
        for (dirty, saving) in cases {
            let workspace = WorkspaceSwitchGate.decision(
                from: Self.openFile, to: .about,
                documentIsDirty: dirty, saveIsInFlight: saving)
            let generic = WorkspaceSwitchDecision.forSwitch(
                from: "a", to: "b",
                documentIsDirty: dirty, saveIsInFlight: saving)
            #expect(workspace == generic, "dirty=\(dirty) saving=\(saving)")
        }
    }
}

/// The routing itself, which the suite above cannot reach.
///
/// `WorkspaceSwitchGate.decision` is a pure function and tests of it say
/// nothing about whether the sidebar consults it. A review proved the gap
/// once: reverting `AppShell`'s `guardedSelection` uses to `$selection` — the
/// exact bug — left all 577 tests green, because the decision function was
/// still correct and still tested.
///
/// This reads the source. That is weaker than driving the binding, and it is
/// what is available: `selection` is `@State`, so writing it outside a view
/// body does nothing observable, and `AppShell`'s body cannot be evaluated in
/// a test. It asserts the wiring is present, not that SwiftUI honours it.
@Suite("The sidebar's selection is wired through the guard")
struct OuterSidebarWiringTests {

    /// Source with `//` **and** `/* */` comments removed.
    ///
    /// Stripping matters: a review defeated every assertion in this suite by
    /// gutting `guardedSelection`'s setter and leaving the guarded form as a
    /// comment on the line above. The bug was fully restored — a click on
    /// About discarded a dirty document without asking — and all four string
    /// checks still passed, because `#filePath` is read as plain text and a
    /// comment is text too. The `//`-only version was then defeated one round
    /// later in the obvious way, with `/* */`. Still naive — it does not know
    /// about string literals containing `//` — which is one more reason the
    /// real guard is behavioural.
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

    private static func source(_ relativePath: String) throws -> String {
        let raw = try String(
            contentsOfFile: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relativePath).path,
            encoding: .utf8)
        return Self.strippingComments(raw)
    }

    private static var appShellSource: String {
        get throws { try source("Sources/SopsUI/AppShell.swift") }
    }

    private static var sidebarSource: String {
        get throws { try source("Sources/SopsUI/Shell/ProjectTreeSidebar.swift") }
    }

    @Test("no selection binding in the shell bypasses the guard")
    func noRawSelectionBinding() throws {
        let source = try Self.appShellSource

        // `$selection` passed to a subview or a List is the unguarded form.
        // The `Binding(get:set:)` inside `guardedSelection` reads `selection`
        // directly and writes through `requestSwitch`, so it does not use the
        // `$` projection at all — which makes any occurrence of it a bypass.
        let raw = source.components(separatedBy: "$selection").count - 1
        #expect(
            raw == 0,
            "AppShell passes $selection somewhere — that write skips WorkspaceSwitchGate and destroys an open dirty document with no prompt")
    }

    /// And no *direct* write to `selection` outside the three places entitled
    /// to make one.
    ///
    /// `noRawSelectionBinding` above only forbids handing the raw projection
    /// to a control. It said nothing about a plain assignment, and one got in:
    /// the Access panel's `onClose` wrote `selection = .projectHome(…)`
    /// directly, which is a second unguarded exit from an open document —
    /// exactly the class of hole the four-column window shipped for a whole
    /// milestone, reintroduced by a one-line callback.
    ///
    /// Two spellings are allowed, and both are the guard rather than a way
    /// round it: `selection = next.selection` is `requestSwitch` applying
    /// `WorkspaceSwitchGate`'s own answer, and `selection = requested` is a
    /// switch the *user* already confirmed (`commit`, `saveThenGo`). Anything
    /// else fails, and the fix is to route it through `requestSwitch`.
    @Test("nothing assigns selection directly except the gate and the confirmed-leave paths")
    func noUnguardedSelectionAssignment() throws {
        let allowed: Set<String> = ["selection = next.selection", "selection = requested"]

        let offenders = try Self.appShellSource
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                // `pendingSelection = …` and `lastSelectedFile[…] = …` are
                // different properties; matched on the exact prefix so they
                // are not swept in.
                line.hasPrefix("selection = ") && !allowed.contains(line)
            }

        #expect(offenders.isEmpty, """
            AppShell writes selection directly: \(offenders.joined(separator: " | ")).             That write skips WorkspaceSwitchGate, so an open dirty document is torn down             with no prompt — route it through requestSwitch(to:)
            """)
    }

    /// Every row in the sidebar goes through the unsaved-changes guard.
    ///
    /// One `List` with one selection binding is a stronger property than the
    /// version this replaces: the four-column window had three bindings and
    /// shipped with one of them unguarded for a whole milestone. Here there
    /// is one place to get it wrong, and these two checks are both halves of
    /// it — the shell hands over the guarded binding, and the sidebar puts it
    /// on the `List` rather than keeping a selection of its own.
    @Test("the sidebar list is driven by the guarded binding the shell hands it")
    func theListTakesTheGuardedBinding() throws {
        let shell = try Self.appShellSource
        #expect(
            shell.contains("selection: guardedSelection"),
            "AppShell builds the sidebar with something other than the guarded binding")

        let sidebar = try Self.sidebarSource
        #expect(
            sidebar.contains("List(selection: selection)"),
            "ProjectTreeSidebar no longer drives its List from the binding it was handed — a click would write a selection of its own, unguarded")
    }

    /// About and Settings still have to be *in* that list: moving them back
    /// out to any other control is exactly how the guard gets bypassed again,
    /// and PROPOSAL §4 pins them to the bottom of the sidebar besides.
    @Test("About and Settings are rows of the guarded list, pinned at the bottom")
    func aboutAndSettingsAreRows() throws {
        let sidebar = try Self.sidebarSource
        #expect(sidebar.contains(".tag(WorkspaceSelection.about)"),
                "the About row is no longer a tagged row of the sidebar list")
        #expect(sidebar.contains(".tag(WorkspaceSelection.settings)"),
                "the Settings row is no longer a tagged row of the sidebar list")

        // Last section of the list, i.e. after every project — which is what
        // "pinned to the bottom" means once there is only one list.
        let about = try #require(sidebar.range(of: ".tag(WorkspaceSelection.about)"))
        let projects = try #require(sidebar.range(of: "ForEach(projects.groups)"))
        #expect(projects.lowerBound < about.lowerBound,
                "About is rendered above the projects — PROPOSAL §4 pins it to the bottom")
    }

    @Test("the Setup guide is a row of the same guarded list")
    func setupGuideIsARowOfTheGuardedList() throws {
        let sidebar = try Self.sidebarSource
        #expect(sidebar.contains(".tag(WorkspaceSelection.setupGuide)"),
                "the Setup guide row is not tagged into the guarded selection")
    }

    @Test("the guard is disabled during a save, like every other exit")
    func disabledDuringSave() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains(".disabled(unsavedChanges.isSaving)"),
            "the sidebar stays live during a save")
    }

    /// That the binding is wired to the request handler at all.
    ///
    /// The weakest kind of claim: it says the binding is built from the
    /// request handler, not what happens when someone writes to it. What
    /// happens is checked by running it — see `GuardedSelectionBindingTests`
    /// below, which exists because three rounds of increasingly clever string
    /// matching were each defeated by a slightly cleverer comment.
    @Test("the guarded binding is built from the request handler")
    func bindingIsBuiltFromTheRequestHandler() throws {
        let source = try Self.appShellSource
        #expect(
            source.contains("Self.makeGuardedSelection("),
            "guardedSelection no longer goes through makeGuardedSelection")
        #expect(
            source.contains("request: { requested in requestSwitch(to: requested) }"),
            "the binding's request handler no longer calls requestSwitch — a click on About writes selection directly and the open document dies unasked")
        #expect(
            source.contains("WorkspaceSwitchGate.decision("),
            "requestSwitch no longer consults WorkspaceSwitchGate")
        // The decision's *effect* used to be applied inline, where nothing
        // could observe it — swapping `pending` for `selection` in the ask
        // branch passed all 685 tests and silently lost the user's edits. It
        // goes through the gate's own `applying`, every branch of which is
        // asserted behaviourally in `WorkspaceSwitchGateTests`.
        #expect(
            source.contains("WorkspaceSwitchGate.applying("),
            "requestSwitch applies the decision inline again, where no test can see it")
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
        var currentValue: WorkspaceSelection?
        var requested: [WorkspaceSelection?] = []

        let binding = AppShell.makeGuardedSelection(
            current: { currentValue },
            request: { requested.append($0) })

        binding.wrappedValue = .about
        binding.wrappedValue = .settings

        #expect(
            requested == [.about, .settings],
            "a write bypassed the request handler — that write is a dirty document dying unasked")
        #expect(
            currentValue == nil,
            "the binding mutated the selection directly instead of asking; the guard can no longer refuse")
    }

    @Test("the getter reflects the live value rather than a captured copy")
    func getterIsLive() {
        var currentValue: WorkspaceSelection?
        let binding = AppShell.makeGuardedSelection(current: { currentValue }, request: { _ in })

        #expect(binding.wrappedValue == nil)
        currentValue = .settings
        #expect(
            binding.wrappedValue == .settings,
            "the binding captured the value once, so a refused switch would not visually revert")
    }
}
