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
/// `Character.isNewline`, never a `"\n"` literal.** The guard that enforces it
/// is `CRLFToleranceTests.sourcesContainNoNewlineBlindIdioms`, which greps
/// `Sources/` for the banned idioms — a helper alone would not have prevented
/// any of the four, because all four were written by someone reaching for
/// `"\n"` out of habit rather than looking for a helper. Byte-level searches
/// (`Data("\nsops:".utf8)` in `ProjectScanner`) are deliberately exempt and
/// correct as they stand: over bytes, `\r\n` genuinely is two of them, so an
/// LF-anchored byte marker matches a CRLF document.
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
