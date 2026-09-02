import AppKit
import SwiftUI

/// A thin grab bar that lets the user drag the height of the view above it.
///
/// SwiftUI has no vertical splitter that works inside a `ScrollView`, and
/// both places this is used — the inspector's value editor and the `+`
/// sheet's value field — sit inside one. So: a capsule, a resize cursor on
/// hover, and a drag that moves `height` within `range`. `onCommit` fires
/// once at the end of the drag, which is where the caller persists the
/// result; writing `UserDefaults` on every `onChanged` would be a write per
/// pixel.
///
/// `highPriorityGesture` rather than `gesture`, because a `ScrollView`
/// otherwise claims a vertical drag as a scroll before this view sees it.
///
/// Keyboard and VoiceOver reach it through the adjustable action: increment
/// and decrement move by `step`, and commit immediately since there is no
/// drag to end.
struct VerticalResizeHandle: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    var step: CGFloat = 20
    let onCommit: (CGFloat) -> Void

    @State private var startHeight: CGFloat?

    var body: some View {
        Capsule()
            .fill(.tertiary)
            .frame(width: 36, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 10)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let start = startHeight ?? height
                        startHeight = start
                        height = Self.clamped(start: start, translation: drag.translation.height, range: range)
                    }
                    .onEnded { _ in
                        startHeight = nil
                        onCommit(height)
                    })
            .accessibilityElement()
            .accessibilityLabel(LocalizedKey.resizeHandleLabel.text)
            .accessibilityValue(Text(verbatim: "\(Int(height))"))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: height = Self.clamped(start: height, translation: step, range: range)
                case .decrement: height = Self.clamped(start: height, translation: -step, range: range)
                @unknown default: return
                }
                onCommit(height)
            }
    }

    /// The whole rule, on its own so a test can pin it without a gesture.
    static func clamped(start: CGFloat, translation: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(start + translation, range.lowerBound), range.upperBound)
    }
}
