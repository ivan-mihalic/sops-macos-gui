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
                /// A plural (or device, or width) split. Only `plural` is used
                /// here; the container is keyed by category name — `one`,
                /// `other`, and whatever else a language needs.
                struct Variations: Decodable {
                    let plural: [String: Localization]?
                }
                /// Xcode's shape when the varying number is not the only
                /// argument: the top-level `stringUnit` carries a `%#@name@`
                /// token and the real forms live under `substitutions[name]`.
                struct Substitution: Decodable {
                    let argNum: Int?
                    let formatSpecifier: String?
                    let variations: Variations?
                }
                let stringUnit: StringUnit?
                let variations: Variations?
                let substitutions: [String: Substitution]?
            }
            let localizations: [String: Localization]?
        }
        let strings: [String: Entry]
    }

    /// Every English form a key can produce, whichever shape it is written in:
    /// a plain `stringUnit`, a direct plural split, or a `%#@token@` with the
    /// forms under `substitutions`. Flattened so a check can look at all of
    /// them without caring which shape the catalog happens to use.
    private static func englishForms(_ entry: StringCatalog.Entry) -> [String] {
        guard let english = entry.localizations?["en"] else { return [] }
        var forms: [String] = []
        if let value = english.stringUnit?.value { forms.append(value) }
        forms += (english.variations?.plural?.values ?? [:].values)
            .compactMap { $0.stringUnit?.value }
        for substitution in english.substitutions?.values ?? [:].values {
            forms += (substitution.variations?.plural?.values ?? [:].values)
                .compactMap { $0.stringUnit?.value }
        }
        return forms
    }

    /// True when the key pluralizes properly — a direct plural split, or a
    /// substitution that carries one.
    private static func hasPluralForms(_ entry: StringCatalog.Entry) -> Bool {
        guard let english = entry.localizations?["en"] else { return false }
        if english.variations?.plural != nil { return true }
        return english.substitutions?.values.contains { $0.variations?.plural != nil } ?? false
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

    /// Every English form for a key, in whichever shape the catalog writes it.
    /// Not `stringUnit` alone: a pluralized entry has no top-level string unit
    /// at all, so reading only that reported `files.other-format.note` as a
    /// *missing* entry the moment it was pluralized properly.
    private static func englishForms(for key: LocalizedKey) -> [String] {
        guard let entry = catalog?.strings[key.rawValue] else { return [] }
        return englishForms(entry)
    }

    // Every view added in any task must add its keys here. A key with no catalog
    // entry (or an empty English value) means the entry was forgotten — this reads
    // Localizable.xcstrings itself, so it catches that in the fast loop regardless
    // of whether `swift test` compiled it into the module bundle.
    @Test("every key this module uses has a non-empty English catalog entry",
          arguments: LocalizedKey.allCases)
    func everyKeyHasCatalogEntry(key: LocalizedKey) throws {
        let forms = Self.englishForms(for: key)
        #expect(!forms.isEmpty,
                "missing catalog entry for \(key.rawValue) in Localizable.xcstrings")
        for form in forms {
            #expect(!form.isEmpty,
                    "empty English catalog entry for \(key.rawValue) in Localizable.xcstrings")
        }
    }

    /// No shipped string may name an age key file's path.
    ///
    /// `key.import.legacy-button` read literally "Import from
    /// ~/.config/sops/age/keys.txt" — a path the app does not necessarily read
    /// and, on macOS, usually does not (`AgeKeyFileLocations` has the citation
    /// from sops's own `age/keysource.go`). A hardcoded path in a *label* is
    /// worse than one in code: the user reads it as a statement of where the
    /// app is looking, so it hides the mismatch instead of exposing it.
    ///
    /// Paths that a click will really read are composed at runtime with
    /// `Text(verbatim:)` from `LegacyKeyFileImportOptions`, never written into
    /// the catalog — so nothing legitimate needs an exception here. This reads
    /// the catalog JSON rather than resolved text, so it holds under both of
    /// this machine's compilers (see this suite's header).
    @Test("no catalog string hardcodes a key-file path")
    func noCatalogStringNamesAKeyFilePath() throws {
        let catalog = try #require(Self.catalog)
        let forbidden = ["keys.txt", "~/.config", "sops/age", "Application Support"]

        // Every form, not just the top-level one: a path written into a plural
        // variation is exactly as shipped as one written anywhere else.
        for (key, entry) in catalog.strings {
            for value in Self.englishForms(entry) {
                for fragment in forbidden {
                    #expect(!value.contains(fragment),
                            "\(key) names \"\(fragment)\": a key-file path belongs to LegacyKeyFileImportOptions at runtime, not to a translatable string — \"\(value)\"")
                }
            }
        }
    }

    /// `file(s)`, `item(s)`, `entry(ies)` — the shape that turns a count into a
    /// sentence no language reads naturally, English included.
    ///
    /// It is not a cosmetic complaint. `%d file(s) use a sops format…` is what
    /// the file list actually drew under the one case that is most common —
    /// exactly one file — and it drew it wrong twice over: the parenthesis and
    /// the verb ("use" for a single file). It was found by looking at a
    /// rendered PNG for `docs/GUIDE.md`, not by any test, which is why there is
    /// now a test.
    ///
    /// Reads the catalog JSON, so it holds under both of this machine's
    /// compilers (see this suite's header).
    @Test("no English string fakes a plural with (s)")
    func noParentheticalPlurals() throws {
        let catalog = try #require(Self.catalog)
        for (key, entry) in catalog.strings {
            for form in Self.englishForms(entry) {
                #expect(!form.contains("(s)") && !form.contains("(es)") && !form.contains("(ies)"),
                        "\(key) fakes a plural: \"\(form)\" — use a plural variation in the catalog instead")
            }
        }
    }

    /// Keys whose English text formats a count but legitimately need no plural
    /// split, each with the reason the singular case cannot occur. An entry
    /// here is a claim about the call site, so it states which one.
    ///
    /// Deliberately not a blanket exemption for "error strings" or similar: the
    /// value of the check below is that adding a counted string forces this
    /// question to be answered once, in writing.
    private static let countedStringsWithNoSingularCase: [String: String] = [
        // `SessionKeyStore.importFromKeysFileContents` throws
        // `.multipleKeysInFile(count:)` only after finding **more than one**
        // non-comment line, so the count is 2 or greater by construction.
        "key.error.multiple-keys":
            "raised only when a keys.txt holds more than one key, so the count is never 1",
    ]

    @Test("every string that formats a count pluralizes on it")
    func countedStringsPluralize() throws {
        let catalog = try #require(Self.catalog)
        // `%d`, `%lld`, `%2$d` — a decimal specifier in any of the spellings
        // this catalog uses, positional or not.
        let countSpecifier = try Regex(#"%(\d+\$)?l*d"#)

        for (key, entry) in catalog.strings {
            let forms = Self.englishForms(entry)
            // `%#@token@` counts too. Once a key is written with a
            // substitution its own forms hold `%arg` rather than `%d`, so
            // matching only on a decimal specifier would quietly stop checking
            // the very keys this rule already reached — including a future one
            // whose substitution carries no plural split at all.
            let formatsACount = forms.contains { $0.contains(countSpecifier) || $0.contains("%#@") }
            guard formatsACount else { continue }
            if let reason = Self.countedStringsWithNoSingularCase[key] {
                #expect(!Self.hasPluralForms(entry),
                        "\(key) is listed as having no singular case (\(reason)) but now pluralizes — remove the exemption")
                continue
            }
            #expect(Self.hasPluralForms(entry),
                    "\(key) formats a count with no plural variation: \"\(forms.first ?? "")\" — a count of 1 will read wrong. Add one, or list the key in countedStringsWithNoSingularCase with the reason 1 cannot occur.")
        }
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

    /// I3. Rewriting `.sops.yaml` re-encodes the whole document, so blank
    /// lines, a leading `---` marker and a trailing comment's alignment do not
    /// survive — inherent to the yaml.v3 node-tree edit `UpdateConfigRecipients`
    /// performs, and established empirically against that library rather than
    /// assumed. `.sops.yaml` is almost always in version control, so a user who
    /// is not told meets it as a surprise diff. The engine itself refuses an
    /// entire config over merge keys for exactly this reason ("changing a part
    /// of it nobody asked to change"), so applying the same class of change
    /// silently was the inconsistency this closes.
    ///
    /// Asserted against the catalog JSON rather than through
    /// `LocalizedKey.text`, for the reason this file's header states: under
    /// plain `swift test` the catalog is copied uncompiled and every key
    /// resolves to its own raw value, so an English-content assertion there
    /// fails for a reason that has nothing to do with the string. The
    /// `.confirmationDialog` that renders this message is not reachable from a
    /// unit test at all — the documented limitation `WorkspaceSwitchDecisionTests`
    /// and `QuitRequestTests` both state — so what is pinned is that the
    /// sentence exists and cannot be dropped without this failing.
    @Test("the config-update confirmation warns that the whole .sops.yaml is rewritten")
    func configUpdateConfirmationDisclosesReformatting() throws {
        let message = try #require(
            Self.englishForms(for: .projectAccessUpdateConfigConfirmMessage).first,
            "missing catalog entry for the config-update confirmation")

        #expect(message.lowercased().contains("blank lines"),
                "the confirmation must say blank lines are lost: \(message)")
        #expect(message.contains("---"),
                "the confirmation must name the document marker: \(message)")
        #expect(message.lowercased().contains("diff"),
                "the confirmation must set the expectation of a larger diff: \(message)")
        // ...without overclaiming: the rules, keys and comments themselves do
        // survive, and the sentence has to say so or it reads as data loss.
        #expect(message.lowercased().contains("every rule"),
                "the confirmation must also say what does survive: \(message)")
    }

    /// That the plural variations actually *resolve* — the half the catalog-JSON
    /// checks above cannot see.
    ///
    /// Both call sites go through `String(format: LocalizedKey…text, count)`, so
    /// what matters is not only that the catalog holds two forms but that
    /// `String(localized:bundle:)` hands back the `%#@…@` template and
    /// `String(format:)` expands it against the count. A catalog entry that is
    /// shaped right and resolves wrong would leave the app printing a literal
    /// `%#@count@` at the user, which is worse than the `(s)` it replaced.
    @Test("counted strings read correctly at one and at many",
          .enabled(if: LocalizationTests.bundleHasMacOSLayout,
                   "swift test's native build system never compiles .xcstrings, so every key falls back to its raw value; run under xcodebuild or swift test --build-system swiftbuild to exercise this"))
    func pluralsResolve() {
        let one = String(format: LocalizedKey.filesOtherFormatNote.text, 1)
        let many = String(format: LocalizedKey.filesOtherFormatNote.text, 3)
        #expect(one.hasPrefix("1 file uses a sops format"), "one-file footnote reads: \(one)")
        #expect(many.hasPrefix("3 files use a sops format"), "many-file footnote reads: \(many)")
        #expect(!one.contains("%"), "unexpanded format specifier in: \(one)")

        let oneMore = String(format: LocalizedKey.projectsErrorDropPartial.text, "That folder isn't readable.", 1)
        let manyMore = String(format: LocalizedKey.projectsErrorDropPartial.text, "That folder isn't readable.", 4)
        #expect(oneMore.contains("1 more item in that drop"), "one-extra drop error reads: \(oneMore)")
        #expect(manyMore.contains("4 more items in that drop"), "many-extra drop error reads: \(manyMore)")
        #expect(!oneMore.contains("%"), "unexpanded format specifier in: \(oneMore)")

        // Task 4's four counted strings. Added because this check had been
        // left covering only the two keys that existed when it was written,
        // which is exactly how a plural entry that is "shaped right and
        // resolves wrong" reaches a user: the JSON guard above sees two forms
        // and is satisfied, and nothing expands them.
        for key: LocalizedKey in [
            .projectAccessUnmatchedNote, .projectAccessCancelledNote,
            .projectAccessApplyFilesConfirmMessage, .projectAccessAllFilesInScope,
        ] {
            let singular = String(format: key.text, 1)
            let plural = String(format: key.text, 5)
            #expect(singular.contains("1"), "\(key.rawValue) at one reads: \(singular)")
            #expect(plural.contains("5"), "\(key.rawValue) at many reads: \(plural)")
            #expect(!singular.contains("%"), "unexpanded format specifier in: \(singular)")
            #expect(!plural.contains("%"), "unexpanded format specifier in: \(plural)")
            // The two forms must actually differ — a catalog entry whose
            // `one` and `other` were pasted identical resolves fine and still
            // reads "1 files".
            #expect(
                singular.replacingOccurrences(of: "1", with: "#")
                    != plural.replacingOccurrences(of: "5", with: "#"),
                "\(key.rawValue) reads the same at one and at many: \(singular)")
        }
    }
}
