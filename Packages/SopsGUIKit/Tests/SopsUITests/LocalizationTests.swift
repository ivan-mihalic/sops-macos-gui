import Foundation
import Testing
@testable import SopsUI

// `swift test` (SwiftPM's native build system, the default with no flags) copies
// Localizable.xcstrings into the module bundle uncompiled — it never produces
// `en.lproj/Localizable.strings`. Without that compiled artifact,
// `String(localized:bundle:)` can't resolve anything, so every `LocalizedKey.text`
// falls back to its own raw key.
//
// This is a known SwiftPM limitation, not a project bug: `xcodebuild` and
// `swift test --build-system swiftbuild` (the Swift Build backend, "preview" as of
// Swift 6.3.3) both DO compile the catalog correctly — only the plain llbuild-based
// native build system doesn't. There is no `.xcstrings`-specific option on
// `.process(_:)` in `Package.swift` that changes this; it is a build-system gap, not
// a manifest one. See `.superpowers/sdd/2026-08-07-m2-core-editing/localization-guard-report.md`.
//
// Because the fast loop is plain `swift test`, the guard that must survive there
// cannot depend on the compiled bundle. `everyKeyHasCatalogEntry` below reads
// Localizable.xcstrings' JSON directly and checks it independently of whichever
// build system produced the test binary — that is the restored guard.
//
// The bundle-based checks (`catalogIsBundled`, `everyKeyResolves`) are kept
// alongside it rather than deleted: they are what would catch the *shipped app*
// losing its strings, which the catalog-JSON check cannot see. They're gated with
// `.enabled(if:)` — the same pattern `ExternalToolNetworkTests` and
// `ProjectScanPerformanceTests` use for environment-dependent tests — so they run
// (and can fail) under a build that compiles the catalog, and skip with a stated
// reason under one that structurally can't.
@Suite("localization")
struct LocalizationTests {

    // MARK: - Catalog JSON (fast-loop guard)

    private struct StringCatalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct StringUnit: Decodable {
                    let value: String
                }
                let stringUnit: StringUnit?
            }
            let localizations: [String: Localization]?
        }
        let strings: [String: Entry]
    }

    /// `Tests/SopsUITests/LocalizationTests.swift` → package root → the catalog's
    /// real location. Resolved from source, not from any build product, so this
    /// works no matter which build system ran the test.
    private static let catalogURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // LocalizationTests.swift -> Tests/SopsUITests
        .deletingLastPathComponent()   // Tests/SopsUITests -> Tests
        .deletingLastPathComponent()   // Tests -> package root (Packages/SopsGUIKit)
        .appendingPathComponent("Sources/SopsUI/Resources/Localizable.xcstrings")

    private static let catalog: StringCatalog? = {
        guard let data = try? Data(contentsOf: catalogURL) else { return nil }
        return try? JSONDecoder().decode(StringCatalog.self, from: data)
    }()

    private static func englishValue(for key: LocalizedKey) -> String? {
        catalog?.strings[key.rawValue]?.localizations?["en"]?.stringUnit?.value
    }

    // Every view added in any task must add its keys here. A key with no catalog
    // entry (or an empty English value) means the entry was forgotten — this reads
    // Localizable.xcstrings itself, so it catches that in the fast loop regardless
    // of whether `swift test` compiled it into the module bundle.
    @Test("every key this module uses has a non-empty English catalog entry",
          arguments: LocalizedKey.allCases)
    func everyKeyHasCatalogEntry(key: LocalizedKey) throws {
        let value = try #require(Self.englishValue(for: key),
                                  "missing catalog entry for \(key.rawValue) in Localizable.xcstrings")
        #expect(!value.isEmpty, "empty English catalog entry for \(key.rawValue) in Localizable.xcstrings")
    }

    // MARK: - Bundle-based checks (only meaningful where a build system compiles the catalog)

    /// True when the module bundle has the `Contents/Resources` layout that
    /// xcodebuild and `swift test --build-system swiftbuild` produce. False for
    /// `swift test`'s native build system, which lays the bundle out flat and never
    /// compiles `.xcstrings` in the first place.
    ///
    /// This is a structural fact about how the bundle was assembled — it does not
    /// look at whether `en.lproj/Localizable.strings` exists — so gating the tests
    /// below on it isn't circular: a build that compiles catalogs but loses a
    /// string still has the `Contents/Resources` layout, runs `catalogIsBundled`,
    /// and fails it for real.
    static var bundleHasMacOSLayout: Bool {
        var isDirectory: ObjCBool = false
        let contentsPath = Bundle.module.bundleURL.appendingPathComponent("Contents").path
        return FileManager.default.fileExists(atPath: contentsPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    @Test("the string catalog ships in the module bundle",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "swift test's native build system never compiles .xcstrings; run under xcodebuild or swift test --build-system swiftbuild to exercise this"))
    func catalogIsBundled() throws {
        #expect(Bundle.module.path(forResource: "Localizable", ofType: "strings", inDirectory: "en.lproj") != nil,
                "compiled Localizable.strings is missing from the SopsUI bundle's en.lproj")
    }

    @Test("every key this module uses resolves to English text, not to the key",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "swift test's native build system never compiles .xcstrings, so every key would fall back to its own raw value; run under xcodebuild or swift test --build-system swiftbuild to exercise this"),
          arguments: LocalizedKey.allCases)
    func everyKeyResolves(key: LocalizedKey) {
        #expect(key.text != key.rawValue, "missing catalog entry for \(key.rawValue)")
    }
}
