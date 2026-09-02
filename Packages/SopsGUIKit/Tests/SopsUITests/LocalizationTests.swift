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
        // Both of these format a 1-based line number, not a count of
        // anything — its grammatical form never varies by value, so there is
        // no singular/plural split to add.
        "dotenv-preview.skipped-line-label":
            "%d is a line number, not a count",
        "dotenv-preview.suspicion.duplicate-key":
            "%1$d is the winning entry's own line number, not a count",
        // SOPS-39 task 8. "encrypted for 2 of 3" — two bare tallies inside a
        // pill, with no noun or verb agreeing with either. "encrypted for 1
        // of 3" reads correctly as it stands, and a plural split would need
        // two substitutions to produce the identical string in every form.
        "access.rules.encrypted-for-of":
            "two bare tallies in a pill, with no noun or verb agreeing with them",
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
            // `#@` rather than `%#@`: a key with more than one varying number
            // is written positionally (`%1$#@matched@`), which the narrower
            // spelling does not match — and a two-count sentence is exactly
            // where a missing plural is hardest to notice.
            let formatsACount = forms.contains { $0.contains(countSpecifier) || $0.contains("#@") }
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

    // MARK: - The hole countedStringsPluralize could not see

    /// Call sites whose `String(format:)` argument is deliberately a
    /// pre-stringified number, each with the reason no plural split applies.
    /// Same shape, and same purpose, as `countedStringsWithNoSingularCase`: the
    /// value of the check below is that it forces the question to be answered
    /// once, in writing, rather than answered by accident.
    private static let preStringifiedCountsWithNoSingularCase: [String: String] = [
        // "%1$@ updated, %2$@ unchanged, %3$@ failed" — three bare tallies, no
        // noun and no verb agreeing with any of them, so none has a singular
        // form to get wrong. Pluralizing three counts in one sentence would
        // need three substitutions to produce the identical string.
        "project-access.results.summary":
            "three bare tallies with no noun or verb agreeing with them; every form reads the same at 1",
    ]

    /// M2. `project-access.files-summary` read "1 of the 1 encrypted files found
    /// here **fall** under…" at the most common case a small project has, and
    /// `countedStringsPluralize` walked straight past it: both counts were
    /// interpolated into strings at the call site (`"\(count)"`) and arrived as
    /// `%@`, so the catalog entry contained no decimal specifier for that check
    /// to match on. The catalog cannot see this — the call site can.
    ///
    /// So this reads the module's own source and refuses a
    /// `String(format: LocalizedKey…text, …)` whose arguments interpolate
    /// anything into a string literal. A count that reaches a format string as
    /// `%@` is a count no plural rule will ever apply to, in any language.
    @Test("no call site turns a count into a string before formatting it")
    func noCallSitePreStringifiesACount() throws {
        for (file, source) in try Self.moduleSources() {
            for (key, arguments) in Self.formatCalls(in: source) {
                guard arguments.contains("\"\\(") else { continue }
                if let reason = Self.preStringifiedCountsWithNoSingularCase[key] {
                    _ = reason
                    continue
                }
                Issue.record(
                    """
                    \(file) formats \(key) with a pre-stringified value: \(arguments.trimmingCharacters(in: .whitespacesAndNewlines))
                    Pass the number itself and pluralize the catalog entry on it, or list the key \
                    in preStringifiedCountsWithNoSingularCase with the reason a singular form cannot differ.
                    """)
            }
        }
    }

    /// Every Swift file of the `SopsUI` module, resolved from source rather
    /// than from a build product — same reasoning as `catalogURL` above.
    private static func moduleSources() throws -> [(String, String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SopsUI")
        let enumerator = try #require(
            FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil),
            "could not walk Sources/SopsUI")
        var files: [(String, String)] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append((url.lastPathComponent, try String(contentsOf: url, encoding: .utf8)))
        }
        #expect(!files.isEmpty, "found no SopsUI sources to scan")
        return files
    }

    /// Every `String(format: LocalizedKey.x.text, …)` in `source`, as (catalog
    /// key, argument text). The argument text is taken by balancing parentheses
    /// from the format argument to the end of the call, so a `.filter { … }
    /// .count` inside it does not truncate the scan early.
    private static func formatCalls(in source: String) -> [(String, String)] {
        var calls: [(String, String)] = []
        var search = source.startIndex..<source.endIndex
        while let start = source.range(of: "LocalizedKey.", range: search) {
            search = start.upperBound..<source.endIndex

            // Only the format argument of a `String(format:…)`, not every
            // mention of a key: anything else's arguments are not this test's
            // business, and balancing parens from them would read the wrong
            // call entirely.
            let before = source[source.startIndex..<start.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard before.hasSuffix("format:") else { continue }

            let tail = source[start.upperBound...]
            guard let dotText = tail.range(of: ".text"),
                  tail[dotText.upperBound...].first == ","
            else { continue }
            let name = String(tail[tail.startIndex..<dotText.lowerBound])
            guard let key = LocalizedKey.allCases.first(where: { "\($0)" == name }) else { continue }

            // From the comma to the close of the `String(` call, counting
            // nested parens so a `.filter { … }.count` inside does not end the
            // scan early.
            var depth = 1
            var arguments = ""
            for character in tail[tail.index(after: dotText.upperBound)...] {
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                arguments.append(character)
            }
            calls.append((key.rawValue, arguments))
        }
        return calls
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

        // M1. "Expect a *slightly* larger diff" was an understatement for the
        // one shape it most needed to describe: a `.sops.yaml` whose rules sit
        // flush with `creation_rules:` (`- path_regex:` at column 1) cannot be
        // re-emitted in that form, `inferIndent` falls back to two, and every
        // line inside `creation_rules` shifts. Nothing is harmed — the post-edit
        // guard proves semantic identity — but a user who reads "slightly"
        // cannot predict the diff they are about to see in git.
        #expect(!message.lowercased().contains("slightly"),
                "the confirmation must not understate a whole-file re-indent: \(message)")
        #expect(message.lowercased().contains("flush"),
                "the confirmation must name the flush-style config whose every line shifts: \(message)")
        #expect(message.lowercased().contains("every line"),
                "the confirmation must say every line inside creation_rules can shift: \(message)")
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
        #expect(one.hasPrefix("1 file is sops-encrypted in a format"), "one-file footnote reads: \(one)")
        #expect(many.hasPrefix("3 files are sops-encrypted in a format"), "many-file footnote reads: \(many)")
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
            .projectAccessCollapsedDuplicateFiles,
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

        // M2. `project-access.files-summary` formats *two* counts, so it needs
        // two substitutions rather than one — a shape nothing else in this
        // catalog uses, and one that resolves to a literal `%1$#@matched@` at
        // the user if it is written wrong. The case it read wrongest is the
        // most common one in a small project: matched == found == 1, which used
        // to say "1 of the 1 encrypted files found here fall under…".
        let bothAtOne = String(format: LocalizedKey.projectAccessFilesSummary.text, 1, 1)
        let bothAtMany = String(format: LocalizedKey.projectAccessFilesSummary.text, 2, 3)
        #expect(bothAtOne.contains("1 file of the 1 encrypted file"),
                "the matched-of-found summary at one reads: \(bothAtOne)")
        #expect(bothAtMany.contains("2 files of the 3 encrypted files"),
                "the matched-of-found summary at many reads: \(bothAtMany)")
        #expect(!bothAtOne.contains("%"), "unexpanded format specifier in: \(bothAtOne)")
        #expect(!bothAtMany.contains("%"), "unexpanded format specifier in: \(bothAtMany)")

        // And the removal confirmation's file count, which was the other
        // pre-stringified one.
        let removalAtOne = String(
            format: LocalizedKey.projectAccessApplyFilesRemovalMessage.text, "Alice", 1)
        let removalAtMany = String(
            format: LocalizedKey.projectAccessApplyFilesRemovalMessage.text, "Alice", 4)
        #expect(!removalAtOne.contains("%"), "unexpanded format specifier in: \(removalAtOne)")
        // The `one` form must describe scope ("1 of this project's files"), not
        // assert the project's total file count ("this project's one encrypted
        // file") — the rule's scope can be a strict subset of the project, so
        // the latter phrasing misstates the project in a destructive
        // confirmation shown immediately before files are re-wrapped.
        #expect(removalAtOne.contains("1 of this project's files"),
                "the removal confirmation at one reads: \(removalAtOne)")
        #expect(!removalAtOne.contains("one encrypted file"),
                "the removal confirmation at one must not claim the project's total file count: \(removalAtOne)")
        #expect(removalAtMany.contains("4 of this project's files"),
                "the removal confirmation at many reads: \(removalAtMany)")
    }

    /// D3. Rewriting a creation rule does not change access to anything that
    /// already exists, and the sentence that says who it drops has to carry that
    /// or it reads as a revocation the app never performed.
    ///
    /// Against the catalog JSON, for this file's usual reason.
    @Test("the config-update confirmation's removal sentence cannot be read as a revocation")
    func configUpdateRemovalSentenceDisclaimsRevocation() throws {
        let sentence = try #require(
            Self.englishForms(for: .projectAccessConfigLoses).first,
            "missing catalog entry for the config-update removal sentence")
        #expect(sentence.lowercased().contains("new files"),
                "the sentence must scope itself to new files: \(sentence)")
        #expect(sentence.lowercased().contains("already"),
                "the sentence must say files already on disk keep their access: \(sentence)")
        #expect(sentence.lowercased().contains("apply to files"),
                "the sentence must point at the control that does change access: \(sentence)")
    }

    /// Task 6, Important 2 from the review: importing an already-encrypted
    /// file never modifies the source, only creates a new one — a recipient
    /// named in `newFileEncryptedImportLoses` still reads the source exactly
    /// as before, and only loses the ability to read the *new* copy. The
    /// borrowed "gains"/"loses" vocabulary from `ProjectAccessView` came
    /// without this clarification the first time; this pins that it is
    /// there, the same shape `configUpdateRemovalSentenceDisclaimsRevocation`
    /// already pins for the sibling sentence one screen over.
    @Test("the encrypted-import loses sentence says the source file is untouched")
    func encryptedImportLosesSentenceDisclaimsSourceModification() throws {
        let sentence = try #require(
            Self.englishForms(for: .newFileEncryptedImportLoses).first,
            "missing catalog entry for the encrypted-import loses sentence")
        #expect(sentence.lowercased().contains("new file"),
                "the sentence must scope the loss to the new file, not the source: \(sentence)")
        #expect(sentence.lowercased().contains("untouched"),
                "the sentence must say the source file is untouched: \(sentence)")
        #expect(sentence.lowercased().contains("still readable"),
                "the sentence must say the source stays readable to them there: \(sentence)")
    }

    /// Final review, Important 2: the sentence that discloses
    /// `encrypted_regex` has to say what the rule *does* — scope which
    /// values get encrypted, leaving the rest as plaintext — and must not
    /// promise which fields those are. This app never evaluates the
    /// expression (sops does, at write time), so a sentence naming specific
    /// keys would be a claim it cannot stand behind, and the review asked
    /// for the weaker, true one on purpose.
    @Test("the encrypted_regex disclosure names the field and plaintext, and predicts no specific keys")
    func encryptedRegexDisclosureIsHonestAboutWhatItKnows() throws {
        let sentence = try #require(
            Self.englishForms(for: .newFileInfoEncryptedRegexScoping).first,
            "missing catalog entry for the encrypted_regex disclosure")
        #expect(sentence.contains("encrypted_regex"),
                "the sentence must name the field so it can be found in .sops.yaml: \(sentence)")
        #expect(sentence.lowercased().contains("plaintext"),
                "the sentence must say the non-matching values are stored as plaintext: \(sentence)")
        #expect(sentence.contains("%@"),
                "the sentence must carry the rule's own expression, so the user can check it: \(sentence)")
        #expect(sentence.lowercased().contains("check the rule"),
                "the sentence must send the user to the rule rather than predicting its result: \(sentence)")
        // The overclaim this must never become: naming which fields end up
        // in plaintext is a matching decision only sops makes.
        for overclaim in ["these fields", "the following", "will be plaintext:"] {
            #expect(!sentence.lowercased().contains(overclaim),
                    "the sentence claims to know sops's own matching result: \(sentence)")
        }
    }

    /// Task 6, Important 1: a same-recipients import must not headline
    /// itself as a change. The two titles have to actually read differently
    /// — a catalog entry that pasted the same text under both keys would
    /// satisfy `everyKeyHasCatalogEntry` while leaving the contradiction the
    /// review found fully in place.
    @Test("the encrypted-import diff title and its no-change counterpart read differently")
    func encryptedImportDiffTitlesAreDistinct() throws {
        let change = try #require(
            Self.englishForms(for: .newFileEncryptedImportDiffTitle).first,
            "missing catalog entry for the encrypted-import diff title")
        let noChange = try #require(
            Self.englishForms(for: .newFileEncryptedImportNoChangeTitle).first,
            "missing catalog entry for the encrypted-import no-change title")
        #expect(change != noChange, "the two titles must not read the same: \(change)")
        #expect(change.lowercased().contains("different access"),
                "the change title must say access differs: \(change)")
        #expect(noChange.lowercased().contains("same access"),
                "the no-change title must say access does not differ: \(noChange)")
    }

    /// Forgetting a registry label removes a nickname and no access at all. A
    /// user who reads it as a revocation and moves on has been misled by the one
    /// tool whose job is to say who can read their secrets — so each of the
    /// three places the operation is described has to carry the distinction on
    /// its own, because a user may stop reading at any of them.
    @Test("nothing about forgetting a label reads as removing a recipient")
    func forgettingALabelNeverReadsAsRevocation() throws {
        for key in [
            LocalizedKey.recipientForgetLabel, .recipientForgetLabelAccessibility,
            .recipientForgetConfirmTitle, .recipientForgetConfirmMessage,
            .recipientForgetConfirmButton,
        ] {
            for form in Self.englishForms(for: key) {
                let text = form.lowercased()
                #expect(!text.contains("revoke"),
                        "\(key.rawValue) must not read as a revocation: \(form)")
                #expect(!text.contains("remove this recipient"),
                        "\(key.rawValue) must not read as removing the recipient: \(form)")
            }
        }
    }

    @Test("the forget control's accessibility label says access does not change")
    func forgetAccessibilityLabelDisclaims() throws {
        let text = try #require(
            Self.englishForms(for: .recipientForgetLabelAccessibility).first).lowercased()
        #expect(text.contains("access"), "the a11y label must speak to access: \(text)")
        #expect(text.contains("not change") || text.contains("still"),
                "the a11y label must say access is unchanged: \(text)")
    }

    @Test("the forget confirmation says they can still decrypt, and how to really revoke")
    func forgetConfirmationDisclaims() throws {
        let message = try #require(
            Self.englishForms(for: .recipientForgetConfirmMessage).first).lowercased()
        #expect(message.contains("decrypt"),
                "the confirmation must say they can still decrypt: \(message)")
        #expect(message.contains("nothing about access changes"),
                "the confirmation must say access is unchanged, in as many words: \(message)")
        #expect(message.contains("apply"),
                "the confirmation must point at the control that does change access: \(message)")
    }
}
