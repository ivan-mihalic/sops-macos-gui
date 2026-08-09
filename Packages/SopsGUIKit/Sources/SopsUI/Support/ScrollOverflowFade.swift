import SwiftUI

/// A bottom (and, once scrolled past the top, top) edge fade over a
/// scrollable view — `List` or `ScrollView` — that is only present while
/// there is genuinely more content past what is currently visible.
///
/// ## Why this exists
/// A snapshot of `OnboardingWizard`'s `.projects` step, showing a real
/// multi-line recipients finding inside the wizard's fixed 640×520 sheet,
/// rendered a line of text cut off mid-sentence at the bottom of the `List`
/// with nothing else on screen suggesting there was more: no scrollbar, no
/// fade, no affordance. The content is not lost — `List` scrolls, as it
/// always has — but a user has no way to tell that from looking at it, and
/// can reasonably read a hard mid-sentence cutoff as the whole finding. This
/// app's editor has the identical shape of risk: a long value or a long file
/// list can run past the visible area the exact same way. This is the fix,
/// applied once and reused everywhere a `List` in this app can overflow its
/// frame — `OnboardingWizard`'s category and orphaned-findings lists,
/// `HealthPanel`'s list, `SecretEditorView`'s row list, and
/// `FileListView`'s file list.
///
/// ## Why not `.scrollIndicators(.visible)` alone
/// Tried first, since it is the one-line native answer. Verified empirically
/// against `SnapshotTool`'s headless render (`Snapshot.swift`'s header
/// explains why screenshots of the running app are not reliable here, so
/// this app's own headless tool is the only way to check): with
/// `.scrollIndicators(.visible)` applied, the long-finding snapshot still
/// showed no visible scroll track at all. `NSScroller`'s own draw path is
/// evidently still gated on something this offscreen, never-shown
/// `NSWindow`/`NSHostingView` pair does not supply — most likely the same
/// class of gap `Snapshot.swift` already documents for `NavigationSplitView`'s
/// sidebar (a real window-occlusion/interaction signal this tool's
/// `Background`-session process never receives). Rather than ship something
/// that is unverifiable by this project's only working visual-verification
/// tool, this reads the scroll geometry directly and draws its own fade,
/// which is fully within SwiftUI's control and confirmed rendering in the
/// snapshot.
///
/// ## How "more content" is detected
/// `onScrollGeometryChange` (macOS 15+) reports the scrollable content's
/// offset, container size and content size from the real layout pass — no
/// user interaction required, so it fires correctly even in a headless,
/// never-interacted-with render. "More below" is `contentOffset.y +
/// containerSize.height` not yet reaching the bottom of `contentSize`;
/// "more above" is the mirror image. Both start `false` and only ever
/// become `true` when the content genuinely does not fit, so a short list —
/// the common case — never grows a fade it does not need.
extension View {
    /// Applies the overflow fade described above. `List`/`ScrollView` are
    /// the only tested content — apply directly to one of those, not to an
    /// arbitrary wrapper around one, since the scroll-geometry read only
    /// makes sense on the scrollable view itself.
    func scrollOverflowFade() -> some View {
        modifier(ScrollOverflowFadeModifier())
    }
}

private struct ScrollOverflowFadeModifier: ViewModifier {
    @State private var hasMoreAbove = false
    @State private var hasMoreBelow = false

    func body(content: Content) -> some View {
        content
            .onScrollGeometryChange(for: OverflowState.self) { geometry in
                let epsilon = 0.5
                return OverflowState(
                    above: geometry.contentOffset.y > geometry.contentInsets.top + epsilon,
                    below: geometry.contentOffset.y + geometry.containerSize.height
                        < geometry.contentSize.height + geometry.contentInsets.top - epsilon
                )
            } action: { _, newValue in
                hasMoreAbove = newValue.above
                hasMoreBelow = newValue.below
            }
            .overlay(alignment: .top) {
                if hasMoreAbove { EdgeFade(edge: .top) }
            }
            .overlay(alignment: .bottom) {
                if hasMoreBelow { EdgeFade(edge: .bottom) }
            }
    }

    private struct OverflowState: Equatable {
        var above: Bool
        var below: Bool
    }
}

/// The fade itself: a thin gradient from transparent to the window
/// background color, at whichever edge has more content past it. Never
/// intercepts clicks or scroll events, and never read by VoiceOver — it is a
/// purely visual cue layered on top of content that is itself already
/// accessible.
private struct EdgeFade: View {
    let edge: VerticalEdge

    var body: some View {
        // Tall enough to cover most of one ordinary row — `SecretEditorView`'s
        // rows run ~50-60pt tall, and a shallow fade (originally 24pt, tuned
        // against `HealthFindingRow`'s much shorter lines) only ever touched
        // a cut-off row's very last sliver, leaving the rest of that row
        // looking fully intact right up to a hard edge. Confirmed against
        // this tool's own headless render — see `scrollOverflowFade()`'s doc
        // comment for why a screenshot, not a guess, is what tuning this
        // against means here. Near-opaque at the far end so the cue reads at
        // a glance, not only on close inspection.
        LinearGradient(
            colors: [backgroundColor.opacity(0), backgroundColor.opacity(0.97)],
            startPoint: edge == .bottom ? .top : .bottom,
            endPoint: edge == .bottom ? .bottom : .top
        )
        .frame(height: 44)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var backgroundColor: Color {
        Color(nsColor: .windowBackgroundColor)
    }
}
