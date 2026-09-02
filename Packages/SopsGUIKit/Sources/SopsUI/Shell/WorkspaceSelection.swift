import Foundation
import SopsProjects

/// What the workspace has selected, across every project — not just one.
///
/// `AppShell` today has two independent selections: an outer `Section`
/// (projects/about/settings) and, once inside `.projects`, a file within
/// whichever project is open. Task 6 collapses that into one project tree, so
/// every leaf a user can click — a file, a project's Access panel, a
/// project's own row, About, Settings — has to be one value the tree can
/// hold in a single `selection` and compare with `==`. This is that value.
///
/// It carries no view state and no side effects; the point of pulling it out
/// on its own, before the tree that will use it exists, is that
/// `WorkspaceSwitchGate` below can be tested against it without a view in
/// the loop at all.
public enum WorkspaceSelection: Hashable, Sendable {
    /// A specific file open in a specific project. The only case that can
    /// have unsaved edits — see `isDocument`.
    case file(project: StoredProject.ID, url: URL)
    /// A project's Access (recipients) panel.
    case access(project: StoredProject.ID)
    /// A project's own row, selected but with no file open yet.
    case projectHome(StoredProject.ID)
    /// The About screen — not scoped to any project.
    case about
    /// The Settings screen — not scoped to any project.
    case settings
    /// The Setup guide (PROPOSAL.md §5) — not scoped to any project.
    case setupGuide

    /// The project this selection belongs to, or `nil` for the
    /// project-independent screens.
    public var projectID: StoredProject.ID? {
        switch self {
        case .file(let project, _): project
        case .access(let project): project
        case .projectHome(let project): project
        case .about, .settings, .setupGuide: nil
        }
    }

    /// Whether this selection can itself be a dirty, unsaved document.
    /// `WorkspaceSwitchGate` only ever has to ask "are we leaving a
    /// document" for `.file` — every other case is inert with respect to
    /// unsaved changes.
    public var isDocument: Bool {
        if case .file = self { true } else { false }
    }
}

/// The two pieces of state a selection change acts on: what is open now, and
/// — while a dirty document is blocking a switch — what was asked for and is
/// waiting on the user's answer.
///
/// Mirrors `AppShell.SectionSwitchState`, generalised from `Section` to
/// `WorkspaceSelection?` so it covers a switch away from a file as well as a
/// switch away from a whole outer section.
public struct WorkspaceSwitchState: Equatable, Sendable {
    public var selection: WorkspaceSelection?
    public var pending: WorkspaceSelection?

    public init(selection: WorkspaceSelection?, pending: WorkspaceSelection?) {
        self.selection = selection
        self.pending = pending
    }
}

/// The pure logic behind changing `WorkspaceSelection` — ported from
/// `AppShell.sectionSwitchDecision` / `AppShell.applying(_:requested:to:)`
/// onto the wider value type Task 6's project tree selects over.
///
/// Both halves already existed for `AppShell.Section`; nothing here is new
/// behaviour, only a wider domain. The old functions and their tests
/// (`SectionSwitchEffectTests`) are left in place — Task 6 is what retires
/// them, once the tree is wired to this type instead.
public enum WorkspaceSwitchGate {

    /// The decision for a requested selection change. Delegates to
    /// `WorkspaceSwitchDecision.forSwitch`, which already answers this for
    /// any `Equatable` target — `Optional<WorkspaceSelection>` qualifies
    /// because `WorkspaceSelection` is `Hashable` (hence `Equatable`).
    ///
    /// The one thing specific to this domain is *which* dirty flag counts:
    /// leaving a non-document selection (Access, a project's home, About,
    /// Settings) can never be blocked by unsaved document edits, because
    /// nothing but `.file` can hold any — so `documentIsDirty` is only
    /// passed through when `from` is itself a document. Passing it through
    /// unconditionally would let a stray `true` (e.g. a caller that forgot
    /// to clear it after closing the document) block a switch that has
    /// nothing at stake.
    public static func decision(
        from: WorkspaceSelection?, to: WorkspaceSelection?,
        documentIsDirty: Bool, saveIsInFlight: Bool
    ) -> WorkspaceSwitchDecision {
        WorkspaceSwitchDecision.forSwitch(
            from: from, to: to,
            documentIsDirty: from?.isDocument == true && documentIsDirty,
            saveIsInFlight: saveIsInFlight)
    }

    /// The state a decision produces — same four branches as
    /// `AppShell.applying`, same reasoning for each:
    ///
    /// - `.alreadyThere` / `.waitForSaveInFlight`: nothing moves.
    /// - `.proceed`: `selection` moves to `requested`.
    /// - `.askAboutUnsavedChanges`: only `pending` moves. Moving `selection`
    ///   here is the data-loss bug `AppShell.applying`'s doc comment
    ///   describes — the editor would be torn down with unsaved edits still
    ///   in it, before the user has answered anything.
    public static func applying(
        _ decision: WorkspaceSwitchDecision,
        requested: WorkspaceSelection?,
        to state: WorkspaceSwitchState
    ) -> WorkspaceSwitchState {
        var next = state
        switch decision {
        case .alreadyThere:
            break
        case .proceed:
            next.selection = requested
        case .askAboutUnsavedChanges:
            next.pending = requested
        case .waitForSaveInFlight:
            break
        }
        return next
    }
}
