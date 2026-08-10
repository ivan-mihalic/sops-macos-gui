import AppKit
import SwiftUI

// Visual snapshots: each view renders to a PNG through a real (but never
// shown) `NSHostingView`/`NSWindow` pair.
//
// ## Why this, and not a screenshot of the running app
//
// Reliably photographing this app's window on the machine it's built on has
// meant launching it and screenshotting — which steals focus on the
// developer's own desktop, and is unreliable to boot: the agent shell that
// drives builds runs in a `Background` launchd session rather than `Aqua`,
// the physical display sleeps when nobody is at the machine, and
// `screencapture` then returns black or a bare desktop — the window is
// registered with the window server, but never actually composited. Neither
// this technique nor `ImageRenderer` needs any of that: both render straight
// into a bitmap, never onto a display, and the window this file creates is
// never ordered front — `NSWindow.orderFront`/`makeKeyAndOrderFront` are
// never called, only `setIsVisible(false)`.
//
// The side effect is better than the original goal — the output is
// **deterministic** (no sleeping display, no Spaces, no permissions prompts),
// so it can run unattended and be diffed between commits like a regression.
//
// ## Why not `ImageRenderer`
//
// `ImageRenderer` was the first thing tried here, and it is a fine choice
// for a from-scratch SwiftUI design system. This app is not one — it leans
// on native AppKit-bridged chrome throughout (`List`, a styled `Form`,
// `Link`, `NavigationSplitView`), and `ImageRenderer` does not draw any of
// that. Verified empirically, not assumed: a minimal `List { Text(...) }`,
// a `Form { ... }.formStyle(.grouped)`, and a `Link(...)` were each rendered
// through `ImageRenderer` in isolation. `List` and `Link` came back as a
// large red-and-yellow "unsupported content" glyph covering the entire
// view; the grouped `Form` came back entirely blank. That is not a partial
// gap this app could route around by avoiding one view — `List` alone is
// load-bearing in `AppShell`, `HealthPanel`, `ProjectSidebar`, and every
// category step of `OnboardingWizard`, including the one snapshot this tool
// exists foremost to take (the long multi-line finding, M2's brief). An
// `ImageRenderer`-based tool would have "succeeded" at rendering 16 PNGs
// while quietly showing nothing of substance in most of them.
//
// Hosting the real view in a real (offscreen) window and asking AppKit to
// draw it — `NSView.cacheDisplay(in:to:)`, the standard technique for
// capturing a view that was never put on screen — goes through the same
// drawing path a real, visible window would use, so `List`'s `NSTableView`,
// `Form`'s grouped chrome, and `Link` all draw correctly. Confirmed by the
// same three-view experiment: identical content, this path, all three
// render their real content.
//
// ## Forcing native chrome to the right appearance
//
// `.environment(\.colorScheme, _)` on the content is not enough by itself to
// put `List`/`NavigationSplitView` chrome in the right light/dark mode —
// that native chrome reads `NSApplication.shared.effectiveAppearance` (or
// the hosting window's own `appearance`), not a SwiftUI environment value.
// `SnapshotRenderer.png(for:)` sets both `NSApp.appearance` and the
// offscreen window's own `appearance` before every render. Snapshots render
// one at a time, sequentially, on the main actor, so mutating `NSApp`'s
// shared, global appearance between renders is safe.
//
// ## What this is NOT
//
// Not a replacement for running the app. This still cannot draw
// `NSViewRepresentable` content that wraps something genuinely dynamic
// (nothing in this app's catalog does), and a `ScrollView`'s interior
// renders only whatever is laid out within its own frame — content that
// would only become visible by actually scrolling stays offscreen (a `List`
// is a `ScrollView` internally, so the same is true of a long list: only
// its unscrolled top is ever captured). This covers layout, spacing,
// alignment, colors, and text, which is exactly what a "does this look
// right" pass is checking for.
//
// One further, narrower gap, found and left undiagnosed rather than
// papered over: `NavigationSplitView`'s own `sidebar:` column does not
// populate through this technique — verified on `AppShell`'s two
// snapshots, where the `List`s in both the outer sidebar and the nested
// `ProjectSidebar` render blank while the `detail:` column (down through
// `ProjectWorkspaceView`'s own nested `NavigationSplitView`) renders
// correctly. A bare `List` outside of a `NavigationSplitView`'s `sidebar:`
// slot is unaffected — `HealthPanel`, `ProjectSidebar` snapshotted on its
// own, and every `List`-based step of `OnboardingWizard` all render their
// real rows. Neither a longer settle pause nor `makeKeyAndOrderFront` with
// the process's activation policy set to `.regular` changed the result.
// The most likely cause: this tool's own process runs in a `Background`
// launchd session (`launchctl managername`) even on a machine with an
// active `Aqua` login session — the exact environment gap that motivated
// building this tool in the first place — and `NavigationSplitView`'s
// sidebar item apparently gates its column population on a real
// window-visibility/occlusion signal that a `Background` session's
// `NSApplication` never receives, where a plain `List` does not need one.
// `AppShell`'s two snapshots are kept in the catalog regardless — the
// `detail` column, the toolbar-adjacent chrome, and both color schemes are
// still real signal — but do not trust them for sidebar content; use the
// standalone `ProjectSidebar`/`HealthPanel` snapshots for that.

/// One snapshot: what to render, how big, and in which appearance.
struct Snapshot {
    let name: String
    let size: CGSize
    let colorScheme: ColorScheme
    let content: @MainActor () -> AnyView

    init(
        _ name: String,
        size: CGSize = CGSize(width: 900, height: 600),
        colorScheme: ColorScheme = .light,
        @ViewBuilder content: @escaping @MainActor () -> some View
    ) {
        self.name = name
        self.size = size
        self.colorScheme = colorScheme
        self.content = { AnyView(content()) }
    }
}

@MainActor
enum SnapshotRenderer {
    /// Renders `snapshot` to PNG data. `nil` means the render failed — that
    /// propagates up to a nonzero exit code rather than a silently-written
    /// empty or placeholder file.
    static func png(for snapshot: Snapshot) -> Data? {
        // Increased Contrast is deliberately not offered here, and it was
        // tried. `NSAppearance(named: .accessibilityHighContrastAqua)` resolves
        // and can be assigned, and the resulting PNG came out **byte-identical**
        // to the ordinary one — verified with `cmp`. SwiftUI derives
        // `\.colorSchemeContrast` from the *system* setting
        // (`NSWorkspace.accessibilityDisplayShouldIncreaseContrast`), not from a
        // view's appearance, and this app's surfaces use SwiftUI colours rather
        // than AppKit-drawn chrome. Shipping those images would have been a
        // catalog full of snapshots claiming an appearance they were not
        // rendered in.
        let appearance = NSAppearance(named: snapshot.colorScheme == .dark ? .darkAqua : .aqua)
        // See "Forcing native chrome to the right appearance" above.
        NSApplication.shared.appearance = appearance

        let view = snapshot.content()
            .environment(\.colorScheme, snapshot.colorScheme)
            .frame(width: snapshot.size.width, height: snapshot.size.height)
            .background(Color(nsColor: .windowBackgroundColor))

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = CGRect(origin: .zero, size: snapshot.size)
        hostingView.appearance = appearance

        // A real window, created but never shown — `setIsVisible(false)`,
        // never `orderFront`/`makeKeyAndOrderFront` — gives AppKit-backed
        // content a real window/layer hierarchy to lay out and draw into.
        // See "Why not `ImageRenderer`" above for why that is necessary here.
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: snapshot.size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.contentView = hostingView
        window.setIsVisible(false)

        hostingView.layoutSubtreeIfNeeded()
        // Gives AppKit a beat to populate table/collection-view-backed
        // content (`List`'s rows, `Form`'s grouped sections) before capture.
        // Without this pause, some renders in testing raced ahead of that
        // population and came back with rows missing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            return nil
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }
}
