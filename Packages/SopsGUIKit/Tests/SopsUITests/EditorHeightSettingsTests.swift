import Foundation
import Testing
@testable import SopsUI

/// The two remembered editor heights — the inspector's value editor and the
/// `+` sheet's value field. Same `UserDefaults(suiteName:)`-per-test shape as
/// `ClipboardClearIntervalPreferenceTests`, for the same parallelism reason.
@Suite("Editor height settings")
struct EditorHeightSettingsTests {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "EditorHeightSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test("an untouched inspector height reads the shipped default")
    func inspectorUnsetReadsTheDefault() {
        let defaults = freshDefaults()
        #expect(InspectorEditorHeightSetting.height(in: defaults) == InspectorEditorHeightSetting.defaultHeight)
        #expect(InspectorEditorHeightSetting.defaultHeight >= 200, "Ivan asked for a taller editor")
    }

    @Test("an inspector height round-trips")
    func inspectorRoundTrips() {
        let defaults = freshDefaults()
        InspectorEditorHeightSetting.setHeight(333, in: defaults)
        #expect(InspectorEditorHeightSetting.height(in: defaults) == 333)
    }

    @Test("an inspector height outside the range is clamped on write", arguments: [CGFloat(1), 10_000])
    func inspectorClamps(_ value: CGFloat) {
        let defaults = freshDefaults()
        InspectorEditorHeightSetting.setHeight(value, in: defaults)
        let stored = InspectorEditorHeightSetting.height(in: defaults)
        #expect(InspectorEditorHeightSetting.allowedRange.contains(stored))
        #expect(defaults.double(forKey: InspectorEditorHeightSetting.defaultsKey) == Double(stored))
    }

    @Test("a corrupt inspector height falls back to the default")
    func inspectorCorruptFallsBack() {
        let defaults = freshDefaults()
        defaults.set("garbage", forKey: InspectorEditorHeightSetting.defaultsKey)
        #expect(InspectorEditorHeightSetting.height(in: defaults) == InspectorEditorHeightSetting.defaultHeight)
    }

    @Test("the add sheet's value height defaults to about five monospaced lines")
    func addSheetDefaultIsFiveLines() {
        let defaults = freshDefaults()
        let height = AddSheetValueHeightSetting.height(in: defaults)
        #expect(height == AddSheetValueHeightSetting.defaultHeight)
        #expect(height >= 70 && height <= 130, "\(height)")
    }

    @Test("an add sheet height round-trips and clamps", arguments: [CGFloat(200), 5, 5_000])
    func addSheetRoundTripsAndClamps(_ value: CGFloat) {
        let defaults = freshDefaults()
        AddSheetValueHeightSetting.setHeight(value, in: defaults)
        let stored = AddSheetValueHeightSetting.height(in: defaults)
        #expect(AddSheetValueHeightSetting.allowedRange.contains(stored))
        if AddSheetValueHeightSetting.allowedRange.contains(value) { #expect(stored == value) }
    }

    @Test("the two settings never share a key")
    func keysDiffer() {
        #expect(InspectorEditorHeightSetting.defaultsKey != AddSheetValueHeightSetting.defaultsKey)
    }
}

@Suite("VerticalResizeHandle")
struct VerticalResizeHandleTests {

    @Test("a drag never leaves the allowed range", arguments: [CGFloat(-10_000), -50, 0, 50, 10_000])
    func clampedNeverLeavesRange(_ translation: CGFloat) {
        let range: ClosedRange<CGFloat> = 120...800
        let result = VerticalResizeHandle.clamped(start: 200, translation: translation, range: range)
        #expect(range.contains(result))
        if range.contains(200 + translation) { #expect(result == 200 + translation) }
    }
}
