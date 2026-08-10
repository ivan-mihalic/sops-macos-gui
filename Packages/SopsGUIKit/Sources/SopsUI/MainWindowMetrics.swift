import CoreGraphics

/// How big the main window is when it first opens.
///
/// It exists because nothing used to decide this. `WindowGroup` with no
/// `.defaultSize` sizes the window from its content's ideal dimensions, and
/// `AppShell` is a `NavigationSplitView` whose panes all say
/// `maxWidth: .infinity` — so on a large display the first launch produced a
/// window as wide as the screen. That is not a size anyone chose; it is the
/// absence of a choice.
///
/// A default window size is a design decision, so it does not scale with the
/// display: the same 1180 pt on a laptop and on a 5K panel. The only thing the
/// screen is consulted for is whether that size *fits* — a window that opens
/// larger than the display puts its own title bar controls out of reach.
public enum MainWindowMetrics {

    /// Wide enough for the sidebar (220), a file list (260) and an editor pane
    /// with room for a value column, without being so wide that a full-height
    /// window covers a laptop screen.
    public static let idealSize = CGSize(width: 1180, height: 760)

    /// The floor the window may be dragged to, and the size below which the
    /// three-pane layout stops being usable. Also what
    /// `.windowResizability(.contentMinSize)` reads to decide how small the
    /// user may make it.
    public static let minimumSize = CGSize(width: 880, height: 560)

    /// `idealSize`, shrunk only as far as it must be to fit on `visibleFrame`.
    ///
    /// `visibleFrame` rather than `frame`, at the call site: the menu bar and
    /// the Dock are not available to a window, and sizing against the raw
    /// screen would put the bottom edge underneath the Dock on exactly the
    /// setups where that matters most.
    public static func defaultSize(forVisibleFrame visible: CGSize) -> CGSize {
        // No `max(minimumSize, …)` here, deliberately. On a display smaller
        // than `minimumSize` the honest answer is "as much as there is": a
        // window forced to 880 pt on an 800 pt screen hangs off the edge, and
        // the user cannot drag it back because the part they would grab is the
        // part that is off-screen.
        CGSize(width: min(idealSize.width, visible.width),
               height: min(idealSize.height, visible.height))
    }
}
