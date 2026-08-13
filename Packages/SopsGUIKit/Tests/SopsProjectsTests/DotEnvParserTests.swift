import Foundation
import Testing

@testable import SopsProjects

/// Every case here is transcribed by hand from spec.md §3.2, not from
/// memory. That table is not derived from dotenv's documentation — it is
/// **measured**: `npm install dotenv` (motdotla/dotenv 17.4.2), each row run
/// through it and its real output recorded, on 2026-08-12. Where a row
/// contradicts intuition (a bare `#` ending a value with no space before it,
/// a backtick acting as a third quote character, `:` as a valid separator),
/// the row wins — that surprise is the entire reason the table was measured
/// instead of designed.
@Suite("DotEnvParser")
struct DotEnvParserTests {

    // MARK: - Helpers

    private struct UnexpectedEntryCount: Error {
        let count: Int
    }

    private func parse(_ text: String) throws -> ParsedDotEnv {
        try DotEnvParser.parse(Data(text.utf8))
    }

    /// Parses `line` and returns the value of its single entry. Fails loudly
    /// (throws) rather than silently returning "" when the line did not
    /// produce exactly one entry, so a grammar regression shows up as a
    /// thrown error pointing at the right expectation, not a false match.
    private func value(_ line: String) throws -> String {
        let parsed = try parse(line)
        guard parsed.entries.count == 1 else {
            throw UnexpectedEntryCount(count: parsed.entries.count)
        }
        return parsed.entries[0].value
    }

    private func keys(_ text: String) throws -> [String] {
        try parse(text).entries.map(\.key)
    }

    // MARK: - §3.2 grammar table — single-assignment value cases

    @Test(
        "value grammar (spec.md §3.2)",
        arguments: [
            // `#` ends an unquoted value even with no whitespace before it.
            ("PASS=abc#123", "abc"),
            ("PASS=abc # x", "abc"),
            ("PASS=#123", ""),
            // `#` inside a quote is just a character.
            ("A='v # inside'", "v # inside"),
            // Backtick is a third quote character.
            ("A=`v # inside`", "v # inside"),
            // `:` followed by whitespace is a valid separator, same as `=`.
            ("KEY: hodnota", "hodnota"),
            // Whitespace around `=` is trimmed.
            ("A = 1", "1"),
            // One assignment per line — the rest of the line is the value.
            ("A=1 B=2", "1 B=2"),
            // `export` is ignored.
            ("export A=1", "1"),
            // Empty value.
            ("A=", ""),
            // Escapes \n \r \t \\ \" only inside double quotes.
            ("A=\"x\\ny\"", "x\ny"),
            // Single quotes never escape — the backslash and `n` survive as
            // two literal characters, not a newline.
            ("A='x\\ny'", "x\\ny"),
            // A later `=` is just part of the value.
            ("A=x=y", "x=y"),
            // `${…}` never expands.
            ("A=${B}", "${B}"),
            // A quote character mid-value (not the first character) is
            // just a character, not the start of a quoted value.
            ("A=he said \"hi\"", "he said \"hi\""),
            // A trailing backslash is a literal character outside quotes.
            ("A=x\\", "x\\"),
            // Unicode in the *value* is fine — only the key charset is
            // ASCII-only.
            ("A=🔐secret", "🔐secret"),
        ]
    )
    func valueGrammar(_ input: String, _ expected: String) throws {
        #expect(try value(input) == expected)
    }

    // MARK: - Key charset: `[\w.-]+`, ASCII-only — not a POSIX name

    @Test("dot and hyphen are valid key characters, alongside a leading digit")
    func keyCharsetAllowsDotHyphenAndLeadingDigit() throws {
        #expect(try keys("a.b-c=1") == ["a.b-c"])
        #expect(try keys("9KEY=v") == ["9KEY"])
        #expect(try keys("MY-KEY=v") == ["MY-KEY"])
    }

    @Test("a Unicode key does not match — dotenv's \\w is ASCII-only")
    func unicodeKeyIsSkippedNotAccepted() throws {
        let parsed = try parse("KLÍČ=1")
        #expect(parsed.entries.isEmpty)
        #expect(parsed.skipped.map(\.text) == ["KLÍČ=1"])
    }

    // MARK: - Lines that are not assignments at all

    @Test("lines that don't match the grammar are recorded as skipped, verbatim")
    func nonAssignmentLinesAreSkipped() throws {
        let text = "MY KEY=v\n!x=1\nJUST_TEXT\n"
        let parsed = try parse(text)
        #expect(parsed.entries.isEmpty)
        #expect(parsed.skipped.map(\.text) == ["MY KEY=v", "!x=1", "JUST_TEXT"])
        #expect(parsed.skipped.map(\.line) == [1, 2, 3])
    }

    @Test("blank lines and comment-only lines are not a finding at all")
    func blankAndCommentLinesAreSilentlyDropped() throws {
        let text = "# a comment\n\nA=1\n   \n  # indented comment\nB=2\n"
        let parsed = try parse(text)
        #expect(parsed.skipped.isEmpty)
        #expect(parsed.entries.map(\.key) == ["A", "B"])
    }

    // MARK: - Multi-line quoted values, `=` after separator, CRLF/CR

    @Test("a double-quoted value may span physical lines")
    func doubleQuotedValueSpansLines() throws {
        let text = "A=\"ř1\nř2\""
        let entries = try parse(text).entries
        #expect(entries.count == 1)
        #expect(entries[0].key == "A")
        #expect(entries[0].value == "ř1\nř2")
        #expect(entries[0].line == 1, "the key's own line, not the closing quote's")
    }

    @Test("CRLF and a lone CR both terminate a line")
    func crlfAndLoneCRAreLineTerminators() throws {
        let crlf = try parse("A=1\r\nB=2\r\n")
        #expect(crlf.entries == [
            DotEnvEntry(key: "A", value: "1", line: 1),
            DotEnvEntry(key: "B", value: "2", line: 2),
        ])

        let cr = try parse("A=1\rB=2\r")
        #expect(cr.entries == [
            DotEnvEntry(key: "A", value: "1", line: 1),
            DotEnvEntry(key: "B", value: "2", line: 2),
        ])
    }

    // MARK: - BOM

    @Test("a leading UTF-8 BOM is stripped, not treated as part of the first key")
    func bomIsStripped() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let data = Data(bom) + Data("A=1\n".utf8)
        let parsed = try DotEnvParser.parse(data)
        #expect(parsed.entries.map(\.key) == ["A"])
        #expect(parsed.skipped.isEmpty)
    }

    // MARK: - notUTF8: the only whole-file rejection

    @Test("invalid UTF-8 rejects the whole file")
    func invalidUTF8IsRejected() {
        // 0xC3 alone is the first byte of a two-byte sequence with no
        // continuation byte — invalid on its own.
        let invalid = Data([0x41, 0x3D, 0xC3])
        #expect(throws: DotEnvParseFailure.notUTF8) {
            try DotEnvParser.parse(invalid)
        }
    }

    @Test("an unterminated quote is NOT a whole-file rejection")
    func unterminatedQuoteDoesNotThrow() throws {
        // Deliberately the opposite of the previous test: this is the one
        // case the reference implementation tolerates by design (see
        // spec.md §3.2 "Co se označí") — it must never become a thrown
        // error, only a flagged suspicion.
        let parsed = try parse("A=\"nedokončené\nB=2\n")
        #expect(parsed.entries.map(\.key) == ["A", "B"])
    }

    // MARK: - The five DotEnvSuspicion kinds

    @Test("strayOpeningQuote: an unterminated quote reads as a literal value, quote included")
    func strayOpeningQuote() throws {
        let parsed = try parse("A=\"nedokončené\nB=2\n")
        #expect(parsed.entries.map(\.key) == ["A", "B"])
        #expect(parsed.entries.map(\.value) == ["\"nedokončené", "2"])
        #expect(parsed.suspicions.contains(DotEnvSuspicion(key: "A", kind: .strayOpeningQuote)))
        #expect(!parsed.suspicions.contains(DotEnvSuspicion(key: "B", kind: .strayOpeningQuote)))
    }

    @Test("notAPosixName: dotenv's key charset accepts more than a shell can export")
    func notAPosixName() throws {
        let parsed = try parse("a.b-c=1\n9KEY=v\nMY-KEY=v\nPLAIN=v\n")
        let flagged = Set(
            parsed.suspicions.compactMap { suspicion -> String? in
                if case .notAPosixName = suspicion.kind { return suspicion.key }
                return nil
            })
        #expect(flagged == ["a.b-c", "9KEY", "MY-KEY"])
        #expect(!flagged.contains("PLAIN"))
    }

    @Test("looksInterpolated: a literal ${…} in the value is flagged, never expanded")
    func looksInterpolated() throws {
        let parsed = try parse("A=${B}\n")
        #expect(parsed.entries.map(\.value) == ["${B}"])
        #expect(parsed.suspicions.contains(DotEnvSuspicion(key: "A", kind: .looksInterpolated)))
    }

    @Test("emptyValue: sops does not encrypt an empty string")
    func emptyValue() throws {
        let parsed = try parse("A=\n")
        #expect(parsed.entries.map(\.value) == [""])
        #expect(parsed.suspicions.contains(DotEnvSuspicion(key: "A", kind: .emptyValue)))
    }

    @Test("duplicateKey: last value wins; earlier occurrences are named as superseded")
    func duplicateKey() throws {
        let parsed = try parse("A=1\nB=x\nA=2\n")

        // Last value wins, at the position of the key's first occurrence.
        #expect(parsed.entries.map(\.key) == ["A", "B"])
        #expect(parsed.entries.first { $0.key == "A" }?.value == "2")
        #expect(parsed.entries.first { $0.key == "A" }?.line == 3, "the line of the value that won")

        #expect(
            parsed.suspicions.contains(
                DotEnvSuspicion(key: "A", kind: .duplicateKey(supersededLines: [1]))))
    }

    @Test("three occurrences: every losing line is named, not just the immediately-prior one")
    func duplicateKeyWithThreeOccurrences() throws {
        let parsed = try parse("A=1\nA=2\nA=3\n")
        #expect(parsed.entries.map(\.value) == ["3"])
        #expect(
            parsed.suspicions.contains(
                DotEnvSuspicion(key: "A", kind: .duplicateKey(supersededLines: [1, 2]))))
    }
}
