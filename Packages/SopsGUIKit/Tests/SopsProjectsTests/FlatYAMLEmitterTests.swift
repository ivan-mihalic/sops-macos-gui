import Foundation
import SopsEngine
import Testing

@testable import SopsProjects

/// `FlatYAMLEmitter` is the only place in this feature where a secret is
/// hand-serialised into YAML text rather than passed through sops's own
/// store. An escaping bug here does not crash — it silently produces a
/// document that decrypts to the *wrong* value, and nothing downstream would
/// notice. That is why every test here proves correctness by round-tripping
/// through the real bridge (`SopsBridge.encryptYAML` → `decryptToRows`)
/// instead of comparing the emitted text against an expected string: a text
/// comparison would only prove this file agrees with itself, not that sops
/// reads it back the same way it was written.
@Suite("FlatYAMLEmitter")
struct FlatYAMLEmitterTests {

    /// One age identity for the whole suite — key generation shells out to
    /// `age-keygen` and is comparatively slow; nothing here needs more than
    /// one recipient.
    private static let pair = try! AgeKeyPair.generate()

    /// Round-trips `entries` through `emit` → `encryptYAML` → `decryptToRows`
    /// and returns the resulting rows, so each test can assert on the shape
    /// it cares about.
    private func roundTrip(_ entries: [DotEnvEntry]) throws -> [SecretRow] {
        let yaml = FlatYAMLEmitter.emit(entries)
        let encrypted = try SopsBridge.encrypt(yaml, format: .yaml, recipients: [Self.pair.public])
        return try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: Self.pair.private)
    }

    @Test("every escape-table value shape survives the round trip intact")
    func valuesSurviveRoundTrip() throws {
        let entries = [
            DotEnvEntry(key: "NEWLINE", value: "line one\nline two", line: 1),
            DotEnvEntry(key: "QUOTE", value: "she said \"hi\"", line: 2),
            DotEnvEntry(key: "BACKSLASH", value: "C:\\Users\\bob", line: 3),
            DotEnvEntry(key: "HASH", value: "value #not-a-comment", line: 4),
            DotEnvEntry(key: "EMOJI", value: "rocket 🚀 ship", line: 5),
            DotEnvEntry(key: "EMPTY", value: "", line: 6),
            DotEnvEntry(key: "LEADING_SPACE", value: " starts with a space", line: 7),
            DotEnvEntry(key: "LOOKS_LIKE_INT", value: "5432", line: 8),
            DotEnvEntry(key: "LOOKS_LIKE_BOOL", value: "true", line: 9),
            DotEnvEntry(key: "CARRIAGE_RETURN", value: "a\rb", line: 10),
            DotEnvEntry(key: "TAB", value: "a\tb", line: 11),
            DotEnvEntry(key: "CONTROL", value: "bell\u{07}end", line: 12),
        ]

        let rows = try roundTrip(entries)

        // Catches a value that swallowed a following key (or vice versa) —
        // an eyeball comparison of the emitted YAML text would miss a bug
        // that merges two entries into one row.
        #expect(rows.count == entries.count)

        for entry in entries {
            let row = rows.first { $0.path == [entry.key] }
            #expect(row?.value == entry.value, "key \(entry.key)")
        }
    }

    @Test("a value that looks like a number or a bool still comes back typed .string")
    func numericAndBooleanLookingValuesStayStrings() throws {
        let entries = [
            DotEnvEntry(key: "PORT", value: "5432", line: 1),
            DotEnvEntry(key: "FLAG", value: "true", line: 2),
        ]

        let rows = try roundTrip(entries)

        let port = rows.first { $0.path == ["PORT"] }
        let flag = rows.first { $0.path == ["FLAG"] }
        #expect(port?.kind == .string)
        #expect(flag?.kind == .string)
    }

    @Test("every allowed dotenv key shape survives, quoted or not")
    func keyShapesSurviveRoundTrip() throws {
        let entries = [
            DotEnvEntry(key: "a.b-c", value: "dotted-dashed", line: 1),
            DotEnvEntry(key: "9KEY", value: "leading-digit", line: 2),
            DotEnvEntry(key: "-X", value: "leading-hyphen", line: 3),
            DotEnvEntry(key: "MY-KEY", value: "hyphenated", line: 4),
            DotEnvEntry(key: "PLAIN_KEY", value: "plain", line: 5),
        ]

        let rows = try roundTrip(entries)

        #expect(rows.count == entries.count)
        for entry in entries {
            let row = rows.first { $0.path == [entry.key] }
            #expect(row?.value == entry.value, "key \(entry.key)")
        }
    }

    @Test("an empty entry list emits a valid empty YAML map")
    func emptyEntryListEmitsEmptyMap() throws {
        #expect(FlatYAMLEmitter.emit([]) == "{}\n")

        let rows = try roundTrip([])
        #expect(rows.isEmpty)
    }

    /// `U+0085` (NEL) was, until this fix, the one escape-table gap the
    /// emitter's own doc comment admitted to: it fell through to the
    /// `default:` arm and was written literally, and sops's YAML layer reads
    /// a literal NEL back differently than it was written, so the value did
    /// not survive the round trip — `SecretFileCreatorTests` proved the
    /// safety net catches this as `roundTripMismatch` rather than silently
    /// corrupting the value. This test proves the actual fix: once `U+0085`
    /// is in the escape table, the value round-trips intact and no mismatch
    /// is ever raised.
    ///
    /// `U+2028` (LINE SEPARATOR) and `U+2029` (PARAGRAPH SEPARATOR) are
    /// included alongside it not because they showed the same defect — a
    /// direct probe of each (same shape as this test, run before this fix)
    /// showed both already round-tripped intact through the unescaped
    /// `default:` arm — but so a regression in either direction (escaping
    /// them when unnecessary, or a future change that breaks their
    /// round-trip) would be caught here rather than assumed to still hold.
    @Test("U+0085 (NEL), U+2028 (LS) and U+2029 (PS) all survive the round trip intact")
    func lineBreakLookalikesSurviveRoundTrip() throws {
        let entries = [
            DotEnvEntry(key: "NEL", value: "before\u{0085}after", line: 1),
            DotEnvEntry(key: "LINE_SEPARATOR", value: "before\u{2028}after", line: 2),
            DotEnvEntry(key: "PARAGRAPH_SEPARATOR", value: "before\u{2029}after", line: 3),
        ]

        let rows = try roundTrip(entries)

        #expect(rows.count == entries.count)
        for entry in entries {
            let row = rows.first { $0.path == [entry.key] }
            #expect(row?.value == entry.value, "key \(entry.key)")
        }
    }
}
