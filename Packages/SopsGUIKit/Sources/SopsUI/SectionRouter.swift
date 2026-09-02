import Observation

/// How the macOS menu bar asks the app to show a sidebar section.
///
/// `⌘,` and About used to be their own scenes: `Settings { }` opened a
/// separate window, and AppKit's stock About item opened another. Both showed
/// content this app already has a place for, in the sidebar `PROPOSAL §4`
/// pins them to — so a user could end up looking at Settings in two windows
/// at once, with the sidebar row still saying it owns that pane.
///
/// The menu items now ask for a screen instead of opening a window. They
/// cannot set `AppShell.selection` themselves, and that restriction is the
/// whole reason this type exists rather than a plain binding: a selection
/// change has to pass `AppShell.requestSwitch(to:)`, which is what refuses to
/// walk away from a dirty document without asking. A menu item writing
/// `selection` directly would be a second, unguarded door into the same
/// state, and it would look right in every case except the one that matters.
///
/// So this holds a *request*. `AppShell` observes it, hands it to the same
/// guarded binding the sidebar list uses, and clears it.
@MainActor
@Observable
public final class SectionRouter {
    /// The screen a menu item asked for, or `nil` when nothing is pending.
    ///
    /// A `WorkspaceSelection` since SOPS-39 task 6 — the same value the
    /// sidebar selects over, so a menu request and a click are literally the
    /// same write. The menu only ever asks for `.about`/`.settings`; the type
    /// is wider because the *binding* it is handed to is.
    ///
    /// Deliberately a single slot rather than a queue: two menu presses land
    /// at most one runloop turn apart, and the user meant the second one.
    /// Queueing would walk them through a section they had already changed
    /// their mind about.
    public private(set) var requested: WorkspaceSelection?

    public init() {}

    public func show(_ screen: WorkspaceSelection) {
        requested = screen
    }

    /// Called by whoever handled the request. Idempotent — clearing a router
    /// that is already clear is a no-op, so an observer that fires twice for
    /// one change cannot turn into a crash or a lost request.
    public func clear() {
        requested = nil
    }
}
