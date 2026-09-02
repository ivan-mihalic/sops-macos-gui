import AppKit
import Foundation

/// How tall the inspector's value editor is — the user's choice, remembered
/// across launches.
///
/// Same shape as `ClipboardClearIntervalPreference`: a `UserDefaults`-backed
/// static with an injectable `defaults`, clamped on the way in so a
/// `defaults read` shows the value that will actually be honoured. Global
/// rather than per file: the height is about the inspector column and the
/// user's screen, not about any one document.
public enum InspectorEditorHeightSetting {
    public static let defaultsKey = "inspector.valueEditorHeight"

    /// Taller than the 120 pt minimum the editor shipped with (SOPS-40): a
    /// secret that is a certificate or a multi-line token needs room, and
    /// the inspector column has it.
    public static let defaultHeight: CGFloat = 200

    /// The floor keeps three lines visible; the ceiling keeps the drag from
    /// pushing Apply/Revert/Remove off the bottom of any realistic window.
    public static let allowedRange: ClosedRange<CGFloat> = 120...800

    public static func height(in defaults: UserDefaults = .standard) -> CGFloat {
        EditorHeightStorage.read(key: defaultsKey, fallback: defaultHeight, range: allowedRange, in: defaults)
    }

    public static func setHeight(_ height: CGFloat, in defaults: UserDefaults = .standard) {
        EditorHeightStorage.write(height, key: defaultsKey, range: allowedRange, in: defaults)
    }
}

/// How tall the `+` sheet's value field is. Same rules as
/// `InspectorEditorHeightSetting`; its own key because the two fields sit
/// in different places and are dragged for different reasons.
public enum AddSheetValueHeightSetting {
    public static let defaultsKey = "editor.addSheetValueHeight"

    /// About five lines of the monospaced body font — what Ivan asked for
    /// as the resting size — plus the editor's own insets.
    public static let defaultHeight: CGFloat = {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let lineHeight = font.ascender - font.descender + font.leading
        return (5 * lineHeight + 12).rounded()
    }()

    public static let allowedRange: ClosedRange<CGFloat> = 60...600

    public static func height(in defaults: UserDefaults = .standard) -> CGFloat {
        EditorHeightStorage.read(key: defaultsKey, fallback: defaultHeight, range: allowedRange, in: defaults)
    }

    public static func setHeight(_ height: CGFloat, in defaults: UserDefaults = .standard) {
        EditorHeightStorage.write(height, key: defaultsKey, range: allowedRange, in: defaults)
    }
}

/// The one read/write rule both settings share. Anything that is not a
/// finite number — unset, a string, NaN — reads as the fallback rather
/// than as zero, which would collapse the editor.
enum EditorHeightStorage {
    static func read(key: String, fallback: CGFloat, range: ClosedRange<CGFloat>, in defaults: UserDefaults) -> CGFloat {
        guard let number = defaults.object(forKey: key) as? NSNumber else { return fallback }
        let value = CGFloat(number.doubleValue)
        guard value.isFinite, value > 0 else { return fallback }
        return clamp(value, to: range)
    }

    static func write(_ value: CGFloat, key: String, range: ClosedRange<CGFloat>, in defaults: UserDefaults) {
        let clamped = value.isFinite ? clamp(value, to: range) : range.lowerBound
        defaults.set(Double(clamped), forKey: key)
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
