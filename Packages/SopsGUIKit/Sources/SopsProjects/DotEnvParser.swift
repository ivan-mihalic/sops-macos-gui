import Foundation

/// One `KEY=value` assignment recovered from a `.env` file, keyed by the name
/// that will become a YAML map key once `FlatYAMLEmitter` (Task 4) serialises
/// `ParsedDotEnv.entries`.
///
/// `line` is where the `KEY` of this assignment was written — for a
/// duplicated key that is the *last* occurrence's key line (see
/// `ParsedDotEnv.entries`), because that is the occurrence whose value
/// actually won. Earlier, overridden occurrences are not lost — they surface
/// as `DotEnvSuspicion.Kind.duplicateKey(supersededLines:)` on this same key.
/// For a value whose closing quote lands on a later physical line than its
/// key, `line` still names the key's own line, not the closing quote's.
public struct DotEnvEntry: Equatable, Sendable {
    public let key: String
    public let value: String
    public let line: Int

    public init(key: String, value: String, line: Int) {
        self.key = key
        self.value = value
        self.line = line
    }
}

/// A line that is not blank, not a comment, and not an assignment the
/// reference parser recognises.
///
/// The single reason this exists — a line that does not match dotenv's
/// grammar — deliberately is not split into finer categories such as "missing
/// `=`" or "invalid key character". Doing that would mean asserting something
/// about the *author's intent* (typo? shell export left in? someone else's
/// config format pasted in?) that the parser has no way to know. `JUST_TEXT`,
/// `MY KEY=v`, `!x=1` and `KLÍČ=1` (dotenv's key charset is ASCII-only, so a
/// Unicode key never matches) all land here, undifferentiated.
///
/// `text` is the raw line, unmasked. That is intentional — see 4.1: the
/// preview masks it in the UI, because a rejected line can still contain a
/// secret value just as easily as an accepted one. Nothing outside the UI
/// layer may print, log, or otherwise surface it verbatim.
public struct DotEnvSkippedLine: Equatable, Sendable {
    public let line: Int
    public let text: String

    public init(line: Int, text: String) {
        self.line = line
        self.text = text
    }
}

/// Something that parsed without error but is unlikely to be what the
/// author intended. Purely advisory: producing a `DotEnvSuspicion` never
/// changes what ends up in `ParsedDotEnv.entries` — see
/// `DotEnvParser`'s file-level doc comment for why the parser is not allowed
/// to "improve" on the reference implementation's reading of a value.
public struct DotEnvSuspicion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The value begins with `'`, `"`, or `` ` `` — the symptom of a quote
        /// that was opened but never closed. The reference implementation
        /// does not treat this as an error: it falls back to reading the value
        /// as if it were unquoted, stray quote character included. This app
        /// matches that reading rather than inventing its own, and flags it
        /// here instead.
        case strayOpeningQuote
        /// The key passes dotenv's own charset (`[\w.-]+`) but is not a
        /// POSIX environment-variable name (`[A-Za-z_][A-Za-z0-9_]*`) — for
        /// example `a.b-c`, `9KEY`, or `MY-KEY`. Still a perfectly good YAML
        /// map key; just not one every shell can `export`.
        case notAPosixName
        /// The value contains `${…}`. dotenv never expands it — the literal
        /// text is what gets stored — but a value that *looks* like shell
        /// interpolation is worth a second glance before it is encrypted
        /// verbatim.
        case looksInterpolated
        /// The value is the empty string. sops does not encrypt an empty
        /// string (it stays a plaintext `""` in the ciphertext file), so an
        /// intentionally-empty secret would not actually be protected.
        case emptyValue
        /// The key was assigned more than once. `supersededLines` lists every
        /// occurrence's line *except* the one whose value survived into
        /// `ParsedDotEnv.entries` (that line is `DotEnvEntry.line`).
        case duplicateKey(supersededLines: [Int])
    }
    public let key: String
    public let kind: Kind

    public init(key: String, kind: Kind) {
        self.key = key
        self.kind = kind
    }
}

/// The result of reading a `.env` file the way `DotEnvParser` reads it.
public struct ParsedDotEnv: Equatable, Sendable {
    /// In order of each key's first occurrence in the file, after resolving
    /// duplicates (last value wins — see `DotEnvSuspicion.Kind.duplicateKey`).
    public let entries: [DotEnvEntry]
    /// In line order. Blank lines and comments are not in here — they are
    /// not a finding, they are what a `.env` file is supposed to contain.
    public let skipped: [DotEnvSkippedLine]
    /// Parsed without error but worth a second look. See `DotEnvSuspicion`.
    public let suspicions: [DotEnvSuspicion]

    public init(
        entries: [DotEnvEntry], skipped: [DotEnvSkippedLine],
        suspicions: [DotEnvSuspicion]
    ) {
        self.entries = entries
        self.skipped = skipped
        self.suspicions = suspicions
    }
}

/// The only reason `DotEnvParser.parse` rejects a file outright.
public enum DotEnvParseFailure: Error, Equatable, Sendable {
    /// The bytes are not valid UTF-8. An unterminated quote deliberately is
    /// **not** a member of this enum — see `DotEnvSuspicion.Kind.strayOpeningQuote`
    /// and the file-level doc comment below.
    case notUTF8
}

/// Reads a `.env` file exactly the way the user's runtime reads it — never
/// "more correctly".
///
/// ## Why matching a reference implementation, not a spec, is the point
///
/// This parser exists because the app is about to *replace* a `.env` file
/// with an encrypted sops document built from what it read here. If this
/// parser disagreed with, say, docker compose's own `.env` reader about even
/// one row of the table below, the app would silently encrypt a different
/// value than the one production loads today — and the break would surface
/// at the exact moment the user believed they had *improved* security by
/// encrypting their secrets. There is no room here for "that's not really
/// what `.env` files are supposed to allow": the grammar is whatever
/// motdotla/dotenv (the original implementation; every other language's
/// dotenv library is a port of it) actually does, not what a spec document
/// says it should do.
///
/// The grammar table lives in `spec.md` §3.2 and is not derived from
/// documentation or memory — it is **measured**: `npm install dotenv`
/// (17.4.2), every row run through it and its real output recorded, on
/// 2026-08-12. `DotEnvParserTests` transcribes that table row for row. If the
/// reference implementation's behaviour on some future version ever looks
/// wrong, the fix is to re-run the probe against the new version and update
/// the table — never to "correct" a row from first principles.
///
/// ## Why an explicit scanner instead of a ported regular expression
///
/// The reference implementation is a single JavaScript regular expression.
/// Transliterating it into `NSRegularExpression` was considered and
/// rejected: backreferences, greediness, and `.`'s treatment of line breaks
/// do not carry over between the two engines identically, and a regex that
/// *looks* like a faithful port while silently diverging on some input is
/// the worst outcome this file could produce — it would fail exactly the
/// invariant the whole file exists to uphold, and do it quietly. A scanner
/// that reads one line at a time, and knows explicitly when a quoted value
/// is allowed to keep reading across a line break, is longer than a regex
/// but every decision it makes is inspectable.
///
/// ## Why `Data`, not `String`
///
/// A Swift `String` is valid UTF-8 by construction, so a `parse(_:
/// String)` overload could never actually produce `DotEnvParseFailure
/// .notUTF8` — the case would be dead code that only ever looks tested.
/// This type owns the UTF-8 decode (and, since it is a byte-level concern,
/// stripping a leading UTF-8 BOM) so that `.notUTF8` is a real, reachable
/// outcome. Callers read the file themselves; this type does no I/O.
public enum DotEnvParser {

    // MARK: - Entry point

    public static func parse(_ data: Data) throws -> ParsedDotEnv {
        var bytes = data
        let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]
        if bytes.count >= 3, Array(bytes.prefix(3)) == utf8BOM {
            bytes = bytes.dropFirst(3)
        }
        guard let text = String(data: bytes, encoding: .utf8) else {
            throw DotEnvParseFailure.notUTF8
        }
        return scan(text)
    }

    // MARK: - Scanner

    /// One key's occurrences, in file order, gathered while scanning so that
    /// duplicate resolution can happen once at the end rather than mutating
    /// an already-emitted entry in place.
    private struct Occurrence {
        let line: Int
        let value: String
        let strayOpeningQuote: Bool
    }

    private static func scan(_ text: String) -> ParsedDotEnv {
        let chars = Array(text)
        let n = chars.count

        var order: [String] = []
        var occurrencesByKey: [String: [Occurrence]] = [:]
        var skipped: [DotEnvSkippedLine] = []

        var i = 0
        var lineNumber = 1

        while i < n {
            let lineStart = i
            let keyLine = lineNumber

            // End of this physical line (index of its terminator, or `n`).
            var lineEnd = i
            while lineEnd < n, !isLineTerminator(chars[lineEnd]) { lineEnd += 1 }

            /// Advances past this physical line's terminator (if any) and
            /// resumes the outer loop at the next line.
            func advancePastLine(to end: Int, endLine: Int) {
                i = end
                if i < n {
                    lineNumber = endLine + 1
                    i += 1
                } else {
                    lineNumber = endLine
                }
            }

            var pos = lineStart
            while pos < lineEnd, isHorizontalWhitespace(chars[pos]) { pos += 1 }

            if pos == lineEnd {
                // Blank line — not a finding.
                advancePastLine(to: lineEnd, endLine: keyLine)
                continue
            }
            if chars[pos] == "#" {
                // Comment-only line — not a finding.
                advancePastLine(to: lineEnd, endLine: keyLine)
                continue
            }

            if let afterExport = matchExportPrefix(chars, at: pos, limit: lineEnd) {
                pos = afterExport
            }

            var keyEnd = pos
            while keyEnd < lineEnd, isKeyChar(chars[keyEnd]) { keyEnd += 1 }

            guard keyEnd > pos else {
                skipped.append(
                    DotEnvSkippedLine(line: keyLine, text: String(chars[lineStart..<lineEnd])))
                advancePastLine(to: lineEnd, endLine: keyLine)
                continue
            }
            let key = String(chars[pos..<keyEnd])
            pos = keyEnd

            while pos < lineEnd, isHorizontalWhitespace(chars[pos]) { pos += 1 }

            var separatorMatched = false
            if pos < lineEnd, chars[pos] == "=" {
                pos += 1
                separatorMatched = true
            } else if pos < lineEnd, chars[pos] == ":" {
                let afterColon = pos + 1
                if afterColon < lineEnd, isHorizontalWhitespace(chars[afterColon]) {
                    pos = afterColon
                    separatorMatched = true
                }
            }

            guard separatorMatched else {
                skipped.append(
                    DotEnvSkippedLine(line: keyLine, text: String(chars[lineStart..<lineEnd])))
                advancePastLine(to: lineEnd, endLine: keyLine)
                continue
            }

            while pos < lineEnd, isHorizontalWhitespace(chars[pos]) { pos += 1 }

            let scanned = scanValue(chars, n: n, start: pos, lineEnd: lineEnd, startLine: keyLine)

            if occurrencesByKey[key] == nil {
                order.append(key)
                occurrencesByKey[key] = []
            }
            // `keyLine`, not `scanned.endLine`: an entry's line is where its
            // key was written, not wherever a multi-line quoted value's
            // closing quote happened to land.
            occurrencesByKey[key]?.append(
                Occurrence(
                    line: keyLine, value: scanned.value,
                    strayOpeningQuote: scanned.strayOpeningQuote))

            advancePastLine(to: scanned.endIndex, endLine: scanned.endLine)
        }

        var entries: [DotEnvEntry] = []
        var suspicions: [DotEnvSuspicion] = []
        entries.reserveCapacity(order.count)

        for key in order {
            guard let occurrences = occurrencesByKey[key], let winner = occurrences.last else {
                continue
            }
            entries.append(DotEnvEntry(key: key, value: winner.value, line: winner.line))

            if occurrences.count > 1 {
                let supersededLines = occurrences.dropLast().map(\.line)
                suspicions.append(
                    DotEnvSuspicion(key: key, kind: .duplicateKey(supersededLines: supersededLines))
                )
            }
            if winner.strayOpeningQuote {
                suspicions.append(DotEnvSuspicion(key: key, kind: .strayOpeningQuote))
            }
            if !isPosixName(key) {
                suspicions.append(DotEnvSuspicion(key: key, kind: .notAPosixName))
            }
            if looksInterpolated(winner.value) {
                suspicions.append(DotEnvSuspicion(key: key, kind: .looksInterpolated))
            }
            if winner.value.isEmpty {
                suspicions.append(DotEnvSuspicion(key: key, kind: .emptyValue))
            }
        }

        return ParsedDotEnv(entries: entries, skipped: skipped, suspicions: suspicions)
    }

    // MARK: - Value scanning

    private struct ScannedValue {
        let value: String
        /// Index of the line terminator that ends the physical line the
        /// value scan finished on, or `chars.count` at end of file.
        let endIndex: Int
        let endLine: Int
        let strayOpeningQuote: Bool
    }

    /// Scans a value starting at `start`. `lineEnd` is the terminator index
    /// (or end of file) of the *key's own* line — the boundary an unquoted
    /// value, or a stray-quote fallback, is never allowed to cross. A
    /// properly closed quoted value is the only thing allowed to read past
    /// it, because dotenv lets a quoted string span physical lines.
    private static func scanValue(
        _ chars: [Character], n: Int, start: Int, lineEnd: Int, startLine: Int
    ) -> ScannedValue {
        guard start < lineEnd else {
            return ScannedValue(value: "", endIndex: lineEnd, endLine: startLine, strayOpeningQuote: false)
        }

        let opening = chars[start]
        guard opening == "\"" || opening == "'" || opening == "`" else {
            let (value, end) = scanUnquoted(chars, from: start, to: lineEnd)
            return ScannedValue(value: value, endIndex: end, endLine: startLine, strayOpeningQuote: false)
        }

        var k = start + 1
        var line = startLine
        var result: [Character] = []
        var closed = false

        while k < n {
            let c = chars[k]
            if isLineTerminator(c) {
                line += 1
                result.append(c)
                k += 1
                continue
            }
            if c == opening {
                closed = true
                break
            }
            if opening == "\"", c == "\\", k + 1 < n {
                switch chars[k + 1] {
                case "n":
                    // `\u{0A}`, not the `"\n"` literal: this line
                    // *constructs* a newline as decoded escape output, it
                    // does not read one out of the file, so it falls outside
                    // the rule `LineEndings.swift`'s doc comment states
                    // (compare `isLineTerminator` below, which does read a
                    // line ending and uses `Character.isNewline`).
                    result.append("\u{0A}")
                    k += 2
                    continue
                case "r":
                    result.append("\u{0D}")
                    k += 2
                    continue
                case "t":
                    result.append("\t")
                    k += 2
                    continue
                case "\\":
                    result.append("\\")
                    k += 2
                    continue
                case "\"":
                    result.append("\"")
                    k += 2
                    continue
                default:
                    // Unrecognised escape: keep the backslash literally,
                    // same as the reference implementation does for
                    // anything outside \n \r \t \\ \".
                    result.append(c)
                    k += 1
                    continue
                }
            }
            result.append(c)
            k += 1
        }

        guard closed else {
            // Unterminated quote: fall back to reading the rest of *this*
            // physical line as an unquoted value, stray quote character and
            // all. See `DotEnvSuspicion.Kind.strayOpeningQuote`.
            let (value, end) = scanUnquoted(chars, from: start, to: lineEnd)
            return ScannedValue(value: value, endIndex: end, endLine: startLine, strayOpeningQuote: true)
        }

        // Closing quote found at `k`; ignore anything else on that final
        // line (trailing whitespace, a trailing comment) — it was already
        // captured inside the quotes if it belonged in the value.
        var end = k + 1
        while end < n, !isLineTerminator(chars[end]) { end += 1 }
        return ScannedValue(value: String(result), endIndex: end, endLine: line, strayOpeningQuote: false)
    }

    /// An unquoted value ends at the first `#` (even with no preceding
    /// whitespace — spec.md §3.2's `PASS=abc#123` row) or at end of line,
    /// whichever comes first, then has trailing horizontal whitespace
    /// trimmed. It never crosses a line.
    private static func scanUnquoted(_ chars: [Character], from start: Int, to lineEnd: Int) -> (
        String, Int
    ) {
        var contentEnd = start
        while contentEnd < lineEnd, chars[contentEnd] != "#" { contentEnd += 1 }
        var trimEnd = contentEnd
        while trimEnd > start, isHorizontalWhitespace(chars[trimEnd - 1]) { trimEnd -= 1 }
        return (String(chars[start..<trimEnd]), lineEnd)
    }

    // MARK: - Character classes

    private static func isHorizontalWhitespace(_ c: Character) -> Bool {
        c == " " || c == "\t"
    }

    /// A single Swift `Character` that ends a line — CRLF, lone LF, or lone
    /// CR (CRLF is itself one `Character`; Swift's grapheme breaking never
    /// splits a CRLF pair). Built on `Character.isNewline` rather than
    /// comparing against `"\n"`/`"\r"` literals directly, per this package's
    /// house rule — see `LineEndings.swift`'s doc comment for the four times
    /// a hand-rolled `"\n"` comparison silently did nothing on a CRLF
    /// document, and `CRLFToleranceTests.sourcesContainNoNewlineBlindIdioms`
    /// for the guard that now catches a fifth.
    private static func isLineTerminator(_ c: Character) -> Bool {
        c.isNewline
    }

    /// dotenv's key charset, `[\w.-]+`, transcribed: ASCII letters, digits,
    /// underscore, dot, hyphen. `\w` is ASCII-only in the reference
    /// implementation — a Unicode letter such as `Í` is not a key character,
    /// which is why `KLÍČ=1` fails to match at all (spec.md §3.2).
    private static func isKeyChar(_ c: Character) -> Bool {
        guard c.isASCII else { return false }
        return c.isLetter || c.isNumber || c == "_" || c == "." || c == "-"
    }

    /// Whether `key` is entirely made of dotenv's own key charset (`[\w.-]+`,
    /// ASCII-only) and non-empty — the single source of truth for what a key
    /// this package's own writer (`DotEnvEmitter`) can ever be handed safely.
    /// `DotEnvEmitter`'s doc comment already states the invariant it depends
    /// on ("every key already passed `DotEnvParser`'s own key grammar"); this
    /// is the function that lets a caller *check* that before constructing a
    /// `DotEnvEntry`, rather than only trusting it — the one place this app
    /// needs to (`SecretDocumentViewModel.refusalForAdding`, F1's editor
    /// "Add" sheet: a key the user just typed has never been through
    /// `DotEnvParser.parse` and so has no other guarantee it fits this
    /// charset). Reuses `isKeyChar` rather than a second, hand-copied
    /// character class — see this package's own rule against exactly that
    /// kind of drift (CLAUDE.md).
    public static func isValidKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy(isKeyChar)
    }

    /// `[A-Za-z_][A-Za-z0-9_]*` — the shell/POSIX name rule, stricter than
    /// dotenv's own key charset. Every character this is ever called with
    /// already passed `isKeyChar`, so only the leading digit/`.`/`-` and any
    /// interior `.`/`-` need checking.
    private static func isPosixName(_ key: String) -> Bool {
        guard let first = key.first, first.isASCII, first.isLetter || first == "_" else {
            return false
        }
        for c in key.dropFirst() where c == "." || c == "-" {
            return false
        }
        return true
    }

    private static func looksInterpolated(_ value: String) -> Bool {
        guard let start = value.range(of: "${") else { return false }
        return value[start.upperBound...].contains("}")
    }

    private static func matchExportPrefix(_ chars: [Character], at pos: Int, limit: Int) -> Int? {
        let word: [Character] = ["e", "x", "p", "o", "r", "t"]
        guard pos + word.count <= limit else { return nil }
        for offset in 0..<word.count where chars[pos + offset] != word[offset] {
            return nil
        }
        var p = pos + word.count
        guard p < limit, isHorizontalWhitespace(chars[p]) else { return nil }
        while p < limit, isHorizontalWhitespace(chars[p]) { p += 1 }
        return p
    }
}
