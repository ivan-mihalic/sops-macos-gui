import Foundation

/// The engine behind `CRLFToleranceTests.sourcesContainNoNewlineBlindIdioms`.
///
/// # Why this is not a grep
///
/// It used to be one: a list of nine literal substrings, matched line by line
/// against each source file. That guard was live — deleting `Sources/` reddened
/// it, and an injected `split(separator: "\n")` was caught with file and line —
/// but live is not the same as thorough. Thirteen ways of writing the same bug
/// were injected into a copy of the package and **twelve of them passed**:
///
/// - `components(separatedBy: .newlines)`, which is not even a no-op — it turns
///   `"a\r\nb"` into `["a", "", "b"]`, inventing a blank line;
/// - the same call broken across two lines, which `swift-format` alone is
///   enough to produce, because the old guard matched within a single line;
/// - `components(separatedBy:"\n")`, differing from the banned string only by
///   the space after the label;
/// - `let sep: Character = "\n"` and then `split(separator: sep)`, which never
///   spells the banned pattern at all;
/// - `firstIndex(of:)`, `lastIndex(of:)`, `range(of:)`, `!= "\n"`,
///   `hasSuffix("\r\n")` — consumers nobody had thought to list;
/// - and a file called `LineEndings.swift` anywhere in the tree, because the
///   exemption keyed on the basename rather than on the path.
///
/// A guard that a reformatter can defeat is not a guard. The failure mode is
/// specifically that a line-oriented substring match sees *text*, and the rule
/// is about *code*.
///
/// # What replaced it, and what it costs
///
/// The honest instrument here would be a Swift AST — `Engine/cshim/exports_test.go`
/// went exactly that way in Task 17, replacing a `strings.Contains` that a
/// comment could satisfy with a `go/ast` walk. Go ships its own parser in the
/// standard library, so that cost nothing. Swift's does not: parsing Swift means
/// taking `swift-syntax` as a package dependency, which is a large remote
/// checkout and a multi-minute build added to a package that today resolves and
/// builds entirely offline (`Scripts/test-network-denied.sh` depends on that).
/// That is a real price for a test-only guard, and it was not paid.
///
/// What is here instead is the step between a grep and a parser: the source is
/// **tokenised** — comments removed, string literals kept whole, interpolations
/// re-entered as code — and then all whitespace outside literals is deleted, so
/// that every way of spacing and line-breaking one expression collapses onto a
/// single normalised form. Patterns are matched against *that*. It is not a
/// parser and does not know a type from a variable; it is, however, immune to
/// the formatting, spacing and comment tricks that defeated the grep, which is
/// where the twelve escapes came from.
///
/// Raw string literals are normalised to the same shape as ordinary ones (the
/// `#` delimiters are not part of what is matched), so `#"\n"#` is caught in a
/// separator position too — a different bug from the CRLF one, since raw
/// `#"\n"#` is a backslash followed by an `n`, but not one worth letting past.
///
/// Its remaining blind spots are named in `CRLFToleranceTests`'s
/// `guardStillMissesTheseAndWeKnowIt`, as executable cases rather than as prose,
/// so that a future reader can see the edge of the guarantee instead of assuming
/// there isn't one.
enum NewlineBlindness {

    struct Offence: CustomStringConvertible, Sendable {
        let file: String
        let line: Int
        let rule: String
        let snippet: String

        var description: String { "\(file):\(line): \(rule) — \(snippet)" }
    }

    // MARK: - The rules

    /// Positions in which a newline literal is being *consumed* — asked a
    /// question about text that came from a file, a pipe or a filename. Every
    /// one of these is newline-blind on a CRLF document, because Swift's
    /// `Character` is a grapheme cluster and `"\r\n"` is one of them: the
    /// `Character` `"\n"` is not present in such a document at all.
    ///
    /// Matched as suffixes of the normalised (whitespace-free) code
    /// immediately preceding the literal, which is why `split(separator:"\n")`,
    /// `split(separator: "\n")` and a version broken over three lines are all
    /// the same string here.
    ///
    /// `replacingOccurrences(of:` is deliberately absent. It is not a line
    /// read, and the one shape that matters —
    /// `replacingOccurrences(of: "\r\n", with: "\n")` — is CRLF *normalisation*,
    /// the correct thing rather than the bug.
    static let consumers = [
        "separator:",           // split(separator:), split(maxSplits:separator:)
        "separatedBy:",         // components(separatedBy:)
        "contains(",
        "hasPrefix(",
        "hasSuffix(",
        "starts(with:",
        "firstIndex(of:",
        "lastIndex(of:",
        "index(of:",
        "range(of:",
        "firstRange(of:",
        "ranges(of:",
        "trimmingPrefix(",
        "trimmingSuffix(",
        "Character(",
        "==",
        "!=",
        "case",
    ]

    /// A literal that is *nothing but* a line ending exists to be compared
    /// against or split on. Binding one to a name — `let sep: Character = "\n"`
    /// — is how the guard was evaded without ever writing a banned call, so the
    /// literal itself is banned wherever it appears, not just where it is used.
    ///
    /// The single sanctioned exception is `joined(separator:)`, which *writes*
    /// line endings rather than reading them and is what several health
    /// findings use to assemble their multi-line detail text.
    static let bareLineEndingLiterals: Set<String> = [
        #""\n""#, #""\r""#, #""\r\n""#, #""\n\r""#,
    ]

    static let sanctionedWritePrefix = "joined(separator:"

    /// `components(separatedBy: .newlines)` deserves its own rule because it
    /// looks like the fix rather than the bug. It is not blind — `CharacterSet.newlines`
    /// contains CR and LF individually — but that is precisely the trouble: it
    /// splits `"a\r\nb"` into `["a", "", "b"]`, so every line of a CRLF
    /// document is followed by a phantom empty one. `LineEndings.lines(of:)`
    /// splits on `Character.isNewline`, for which `"\r\n"` is a single
    /// separator.
    static let characterSetPatterns = [
        "separatedBy:.newlines",
        "separatedBy:CharacterSet.newlines",
    ]

    // MARK: - Entry point

    /// Every way `source` departs from the rule. `file` is used only for
    /// reporting — there is **no** exemption keyed on it, by name or by path.
    /// The old guard exempted anything called `LineEndings.swift`, which meant
    /// the evasion was to add a second file with that name; the exemption is
    /// gone instead, and `LineEndings.swift` passes on its own merits because
    /// the `"\n"` literals in it are all inside doc comments, which this scanner
    /// removes before it looks at anything.
    static func offences(in source: String, named file: String) -> [Offence] {
        let scan = Tokenizer(source).run()
        let sourceLines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        func snippet(atLine line: Int) -> String {
            guard line >= 1, line <= sourceLines.count else { return "" }
            return sourceLines[line - 1].trimmingCharacters(in: .whitespaces)
        }

        var found: [Offence] = []

        for literal in scan.literals {
            let raw = String(scan.code[literal.start..<literal.end])
            let isBare = bareLineEndingLiterals.contains(raw)
            guard literal.containsLineEndingEscape || isBare else { continue }

            let prefixStart = max(0, literal.start - 64)
            let prefix = String(scan.code[prefixStart..<literal.start])
            if prefix.hasSuffix(sanctionedWritePrefix) { continue }

            let line = scan.line[literal.start]
            if let consumer = consumers.first(where: { prefix.hasSuffix($0) }) {
                found.append(Offence(
                    file: file, line: line,
                    rule: "a line-ending literal consumed by `\(consumer)`",
                    snippet: snippet(atLine: line)))
            } else if isBare {
                found.append(Offence(
                    file: file, line: line,
                    rule: "a bare line-ending literal \(raw)",
                    snippet: snippet(atLine: line)))
            }
        }

        let code = scan.code
        for pattern in characterSetPatterns {
            for start in occurrences(of: Array(pattern), in: code) {
                let line = scan.line[start]
                found.append(Offence(
                    file: file, line: line,
                    rule: "`\(pattern)` splits \"a\\r\\nb\" into three lines, not two",
                    snippet: snippet(atLine: line)))
            }
        }

        return found.sorted { ($0.line, $0.rule) < ($1.line, $1.rule) }
    }

    private static func occurrences(of pattern: [Character], in haystack: [Character]) -> [Int] {
        guard !pattern.isEmpty, haystack.count >= pattern.count else { return [] }
        var hits: [Int] = []
        for start in 0...(haystack.count - pattern.count)
        where Array(haystack[start..<(start + pattern.count)]) == pattern {
            hits.append(start)
        }
        return hits
    }

    // MARK: - Tokenisation

    struct Scan {
        /// The source with comments removed and every run of whitespace
        /// *outside* a string literal deleted. A call spread over four lines
        /// and the same call on one line normalise to identical text here.
        var code: [Character] = []
        /// `line[i]` is the 1-based source line character `code[i]` came from.
        var line: [Int] = []
        var literals: [Literal] = []
    }

    struct Literal {
        /// Index into `Scan.code` of the opening quote.
        let start: Int
        /// One past the closing quote.
        let end: Int
        /// Whether the literal's own text contains a `\n` or `\r` escape.
        /// Interpolated segments do not count towards this — the code inside
        /// an interpolation is scanned as code, and any literal it contains
        /// is recorded separately.
        let containsLineEndingEscape: Bool
    }

    /// A hand-written lexer for exactly as much of Swift's grammar as this
    /// guard needs to stop being fooled by formatting: line and (nested) block
    /// comments, single-line, multi-line and raw string literals, and string
    /// interpolation.
    private final class Tokenizer {
        private let chars: [Character]
        private var i = 0
        private var line = 1
        private var scan = Scan()

        init(_ source: String) { chars = Array(source) }

        func run() -> Scan {
            while i < chars.count { step() }
            return scan
        }

        private func peek(_ offset: Int) -> Character? {
            let index = i + offset
            return index < chars.count ? chars[index] : nil
        }

        private func emit(_ character: Character) {
            scan.code.append(character)
            scan.line.append(line)
        }

        /// Consumes the current character verbatim, keeping the line counter
        /// honest across the real newlines inside a multi-line literal.
        private func push() {
            let character = chars[i]
            emit(character)
            if character == "\n" { line += 1 }
            i += 1
        }

        private func step() {
            let character = chars[i]
            if character == "\n" { line += 1; i += 1; return }
            if character.isWhitespace { i += 1; return }
            if character == "/", peek(1) == "/" { skipLineComment(); return }
            if character == "/", peek(1) == "*" { skipBlockComment(); return }
            if character == "#", let hashes = rawStringHashes() { i += hashes; scanLiteral(hashes: hashes); return }
            if character == "\"" { scanLiteral(hashes: 0); return }
            emit(character)
            i += 1
        }

        /// The number of `#`s if the current `#` opens a raw string literal.
        private func rawStringHashes() -> Int? {
            var hashes = 0
            while peek(hashes) == "#" { hashes += 1 }
            return peek(hashes) == "\"" ? hashes : nil
        }

        private func skipLineComment() {
            while i < chars.count, chars[i] != "\n" { i += 1 }
        }

        private func skipBlockComment() {
            var depth = 0
            while i < chars.count {
                if chars[i] == "/", peek(1) == "*" { depth += 1; i += 2; continue }
                if chars[i] == "*", peek(1) == "/" {
                    depth -= 1; i += 2
                    if depth == 0 { return }
                    continue
                }
                if chars[i] == "\n" { line += 1 }
                i += 1
            }
        }

        /// At entry `chars[i]` is the opening `"`; any leading `#`s have been
        /// consumed by the caller.
        private func scanLiteral(hashes: Int) {
            let start = scan.code.count
            var containsLineEndingEscape = false

            let multiline = peek(1) == "\"" && peek(2) == "\""
            let delimiter = multiline ? 3 : 1
            for _ in 0..<delimiter where i < chars.count { push() }

            while i < chars.count {
                if isClosingDelimiter(length: delimiter, hashes: hashes) {
                    for _ in 0..<delimiter where i < chars.count { push() }
                    i += hashes
                    scan.literals.append(Literal(
                        start: start, end: scan.code.count,
                        containsLineEndingEscape: containsLineEndingEscape))
                    return
                }
                if isEscape(hashes: hashes) {
                    let escaped = peek(1 + hashes)
                    if escaped == "(" {
                        for _ in 0..<(2 + hashes) where i < chars.count { push() }
                        scanInterpolation()
                        continue
                    }
                    if escaped == "n" || escaped == "r" { containsLineEndingEscape = true }
                    for _ in 0..<(2 + hashes) where i < chars.count { push() }
                    continue
                }
                push()
            }

            // Unterminated literal — a file that would not compile anyway.
            scan.literals.append(Literal(
                start: start, end: scan.code.count,
                containsLineEndingEscape: containsLineEndingEscape))
        }

        private func isClosingDelimiter(length: Int, hashes: Int) -> Bool {
            for offset in 0..<length where peek(offset) != "\"" { return false }
            for offset in 0..<hashes where peek(length + offset) != "#" { return false }
            return true
        }

        private func isEscape(hashes: Int) -> Bool {
            guard chars[i] == "\\" else { return false }
            for offset in 0..<hashes where peek(1 + offset) != "#" { return false }
            return true
        }

        /// The `\(` has already been consumed. Scans the interpolated
        /// expression as ordinary code — so a `split(separator: "\n")` hidden
        /// inside a string is seen — up to and including the matching `)`.
        private func scanInterpolation() {
            var depth = 1
            while i < chars.count {
                let character = chars[i]
                if character == "\n" { line += 1; i += 1; continue }
                if character.isWhitespace { i += 1; continue }
                if character == "/", peek(1) == "/" { skipLineComment(); continue }
                if character == "/", peek(1) == "*" { skipBlockComment(); continue }
                if character == "#", let hashes = rawStringHashes() { i += hashes; scanLiteral(hashes: hashes); continue }
                if character == "\"" { scanLiteral(hashes: 0); continue }
                if character == "(" { depth += 1 }
                if character == ")" {
                    depth -= 1
                    emit(character)
                    i += 1
                    if depth == 0 { return }
                    continue
                }
                emit(character)
                i += 1
            }
        }
    }
}
