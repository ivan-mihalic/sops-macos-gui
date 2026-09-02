import Testing
@testable import SopsUI
import SopsProjects

/// The menu bar's ⌘, and About items ask for a sidebar screen instead of
/// opening windows of their own, and this is the property that has to hold
/// while they do: **the request goes through the same guard a sidebar click
/// goes through.**
///
/// That guard is what stops a section switch from walking away from a dirty
/// document without asking. A menu item that set `selection` directly would
/// be a second, unguarded way into the same state — and it would look
/// correct, because the ordinary case (nothing unsaved) behaves identically.
/// The difference only shows up on the one path that matters.
@Suite("SectionRouter")
@MainActor
struct SectionRouterTests {

    @Test("a router request reaches the guarded setter, not the raw selection")
    func requestGoesThroughTheGuard() {
        var current: WorkspaceSelection? = nil
        var guardedRequests: [WorkspaceSelection?] = []

        // The same binding the sidebar list is given.
        let guarded = AppShell.makeGuardedSelection(
            current: { current },
            request: { guardedRequests.append($0) })

        let router = SectionRouter()
        router.show(.settings)

        // What `AppShell` does when it observes a request: hand it to the
        // guarded binding and clear the router.
        if let requested = router.requested {
            guarded.wrappedValue = requested
            router.clear()
        }

        #expect(guardedRequests == [.settings])
        // Nothing wrote the selection directly — the guard decides that, and
        // in the app it may legitimately refuse.
        #expect(current == nil)
        #expect(router.requested == nil)
        current = .settings   // silence the unused-write warning honestly
        #expect(current == .settings)
    }

    @Test("a second request replaces an unhandled one rather than queueing")
    func latestRequestWins() {
        let router = SectionRouter()
        router.show(.settings)
        router.show(.about)

        // Two menu presses before a single observation is a real sequence
        // (they are one runloop turn apart at most). The user meant the last
        // one; a queue would walk them through a section they no longer want.
        #expect(router.requested == .about)
    }

    @Test("a Setup guide request is carried like any other section")
    func aSetupGuideRequestIsCarried() {
        let router = SectionRouter()
        router.show(.setupGuide)
        #expect(router.requested == .setupGuide)
        #expect(WorkspaceSelection.setupGuide.projectID == nil)
        #expect(!WorkspaceSelection.setupGuide.isDocument)
    }

    @Test("clearing an already-clear router is harmless")
    func clearIsIdempotent() {
        let router = SectionRouter()
        router.clear()
        #expect(router.requested == nil)
        router.show(.about)
        router.clear()
        router.clear()
        #expect(router.requested == nil)
    }
}
