import Foundation

/// One place that knows what a line is.
///
/// Swift's `Character` is an extended grapheme cluster, and CRLF — `"\r\n"` —
/// is **one** such cluster, not two. Every idiom that reaches for the
/// `Character` `"\n"` is therefore a no-op on a CRLF document: it is not
/// present anywhere in the string, so
///
/// - `text.split(separator: "\n")` returns the whole file as a single "line",
/// - `text.contains("\nsops:")` never matches,
/// - `{ $0 == "\n" }` never fires.
///
/// This has now bitten the project four separate times — `contains("\nsops:")`
/// in Task 1b, `keys.txt` splitting in Task 6, `SopsMetadataShape` in Task 14
/// (caught in its own first draft), and
/// `EncryptedFileMetadata.sopsBlockLines` in Task 16, where the consequence
/// was a health report accusing a healthy file of not listing the user's own
/// key. Each fix was correct and local, and each left the next call site
/// exposed.
///
/// So the rule for this package is: **anything that reads a line out of text
/// that came from a file, a pipe, or a filename uses this type or
/// `Character.isNewline`, never a `"\n"` literal.** A helper alone would not
/// have prevented any of the four, because all four were written by someone
/// reaching for `"\n"` out of habit rather than looking for a helper, so the
/// rule is enforced by a guard: `CRLFToleranceTests.sourcesContainNoNewlineBlindIdioms`,
/// over every `.swift` file in `Sources/`, with no per-file exemption.
///
/// Byte-level searches (`Data("\nsops:".utf8)` in `ProjectScanner`) are
/// deliberately outside the rule and correct as they stand: over bytes, `\r\n`
/// genuinely is two of them, so an LF-anchored byte marker matches a CRLF
/// document. So is `joined(separator: "\n")`, which writes line endings rather
/// than reading them.
///
/// ## What the guard actually enforces, which is less than that sentence
///
/// The guard tokenises each file — comments dropped, string literals kept
/// whole, interpolations re-entered as code — and then matches against source
/// with all whitespace outside literals removed, so formatting cannot hide
/// anything from it. What it recognises is a *written* line-ending literal:
/// `"\n"`, `"\r"`, `"\r\n"` bound to a name or handed to a consuming API
/// (`split`, `components`, `contains`, `hasPrefix`/`hasSuffix`, `firstIndex`,
/// `lastIndex`, `range(of:)`, `==`/`!=`, a `case` label), plus
/// `components(separatedBy: .newlines)`, which is not blind but does insert a
/// phantom empty line after every CRLF-terminated one.
///
/// What it does not recognise is a line ending that is *constructed* rather
/// than written — `"\u{0A}"`, `Character(UnicodeScalar(10))` — because that
/// needs a real Swift parser with constant folding rather than a tokeniser.
/// Nor does it look at `Tests/`, where `"\n"` in a fixture is ordinary and
/// correct; two tests were nevertheless found asserting nothing under CRLF for
/// exactly this reason, and that stays a reviewer's job. `NewlineBlindness`'s
/// own header states the whole boundary, and `CRLFToleranceTests` pins both
/// sides of it — the evasions it catches and the ones it does not — as cases
/// in a test rather than as claims in a comment.
public enum LineEndings {

    /// `text` split into lines on any line ending — LF, CRLF, CR, and the
    /// Unicode line/paragraph separators `Character.isNewline` recognises —
    /// with empty lines **kept**.
    ///
    /// Empty subsequences are kept because the callers that scan an indented
    /// block (`EncryptedFileMetadata.sopsBlockLines`,
    /// `SopsMetadataShape.isYAMLMetadata`) decide where the block ends by
    /// looking at each line's indentation, and a blank line inside a block is
    /// a line they must see rather than a gap that silently closes it.
    /// Callers that want blank lines gone should filter, so that the choice
    /// is visible at the call site.
    public static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    }
}
