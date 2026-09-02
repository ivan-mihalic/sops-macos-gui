import Foundation
import SwiftUI
import SopsEngine
import Testing
@testable import SopsUI

/// Column widths (and order) of the secret table, remembered per file so a
/// layout the user dragged into shape survives a relaunch. Keyed by the
/// file's canonical path — a file lives in exactly one project, so the
/// project is implied.
@Suite("EditorLayoutStore")
struct EditorLayoutStoreTests {

    private func freshDefaults() -> UserDefaults {
        let suiteName = "EditorLayoutStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func customized() -> TableColumnCustomization<SecretRow> {
        var c = TableColumnCustomization<SecretRow>()
        // The only publicly mutable field — width and order are opaque but
        // ride along in the same `Codable` payload.
        c[visibility: "type"] = .hidden
        return c
    }

    @Test("an unknown file gets the default customization")
    func unknownFileGetsDefaultCustomization() {
        let defaults = freshDefaults()
        let columns = EditorLayoutStore.columns(for: URL(fileURLWithPath: "/nowhere/a.yaml"), in: defaults)
        #expect(columns == TableColumnCustomization<SecretRow>())
    }

    @Test("a customization round-trips per file and does not leak to another file")
    func customizationRoundTripsPerFile() {
        let defaults = freshDefaults()
        let a = URL(fileURLWithPath: "/proj/a.yaml")
        let b = URL(fileURLWithPath: "/proj/b.yaml")
        EditorLayoutStore.setColumns(customized(), for: a, in: defaults)
        #expect(EditorLayoutStore.columns(for: a, in: defaults) == customized())
        #expect(EditorLayoutStore.columns(for: b, in: defaults) == TableColumnCustomization<SecretRow>())
    }

    @Test("the key is the canonical path, so /private/tmp and /tmp are one file")
    func keyIsCanonical() {
        let defaults = freshDefaults()
        let name = "layout-\(UUID().uuidString).yaml"
        EditorLayoutStore.setColumns(customized(), for: URL(fileURLWithPath: "/private/tmp/\(name)"), in: defaults)
        #expect(EditorLayoutStore.columns(for: URL(fileURLWithPath: "/tmp/\(name)"), in: defaults) == customized())
    }

    @Test("corrupt stored data falls back to the default instead of throwing")
    func corruptDataFallsBackToDefault() {
        let defaults = freshDefaults()
        let a = URL(fileURLWithPath: "/proj/a.yaml")
        defaults.set([CanonicalPathForTests.of(a.path): Data("not json".utf8)], forKey: EditorLayoutStore.defaultsKey)
        #expect(EditorLayoutStore.columns(for: a, in: defaults) == TableColumnCustomization<SecretRow>())
    }

    @Test("forget drops one file's layout only")
    func forgetDropsOneFile() {
        let defaults = freshDefaults()
        let a = URL(fileURLWithPath: "/proj/a.yaml")
        let b = URL(fileURLWithPath: "/proj/b.yaml")
        EditorLayoutStore.setColumns(customized(), for: a, in: defaults)
        EditorLayoutStore.setColumns(customized(), for: b, in: defaults)
        EditorLayoutStore.forget(a, in: defaults)
        #expect(EditorLayoutStore.columns(for: a, in: defaults) == TableColumnCustomization<SecretRow>())
        #expect(EditorLayoutStore.columns(for: b, in: defaults) == customized())
    }

    /// Width persistence is invisible to the public API, so the one thing a
    /// test can pin is that every column takes part: a column without a
    /// `customizationID` is left out of the payload, and a fixed `.width(n)`
    /// cannot be dragged at all.
    @Test("every table column has a customizationID and none has a fixed width")
    func everyColumnHasACustomizationIDAndNoFixedWidth() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SopsUI/Editor/SecretTableView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let ids = source.components(separatedBy: ".customizationID(").count - 1
        #expect(ids == 4, "expected four customizationIDs, found \(ids)")
        #expect(source.contains("columnCustomization:"), "the Table must bind its customization")
        let fixed = try Regex(#"\.width\(\s*\d+\s*\)"#)
        #expect(source.firstMatch(of: fixed) == nil, "a fixed .width(n) column cannot be resized")
    }
}

/// `CanonicalPath` lives in `SopsHealth`; mirrored here so this test does not
/// need that module's testable import for one call.
private enum CanonicalPathForTests {
    static func of(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : resolved
    }
}
