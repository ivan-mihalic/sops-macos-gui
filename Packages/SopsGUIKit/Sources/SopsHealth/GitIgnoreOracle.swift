import Foundation

/// Answers "would git ignore this file?" by asking git.
///
/// The previous implementation read the project root's `.gitignore` and
/// compared each line to a filename with `==`. Verified against `git
/// check-ignore`, that was wrong in both directions at once:
///
/// - `.env` at the root with a `.gitignore` containing `.env*` was reported as
///   **not** gitignored, complete with an offer to append `.env` to a file that
///   already covers it.
/// - `services/api/.env` holding a live `sk_live_…`, in a project with no
///   `.gitignore` at all, was reported as `[OK] No unignored plaintext secret
///   files found.` — because the scan only ever looked at the project root.
///
/// Exact-line matching cannot see `*.env`, `.env*`, `/.env`, `**/.env`,
/// negations, directory patterns, a `.gitignore` in a parent directory, the
/// repository's own `info/exclude`, or the user's global `core.excludesFile`.
/// `git check-ignore` understands all of them, because it *is* the
/// implementation. `git` is already a required tool in `ExternalToolCheck`, so
/// depending on it here adds no new requirement.
///
/// Read-only throughout: `rev-parse`, `check-ignore` and `ls-files` inspect,
/// they do not write. Nothing here stages, creates or modifies a file.
enum GitIgnoreOracle {

    enum Verdict {
        /// git answered. `exposed` are the paths git does **not** ignore, and
        /// `tracked` are the subset of those already committed to the
        /// repository — for which adding a gitignore line changes nothing.
        case answered(exposed: [URL], tracked: Set<String>)
        /// git could not answer, and the reason is shown to the user verbatim.
        /// Never downgraded to a guess.
        case undetermined(reason: String)
    }

    /// The timeout for each git invocation. Generous: git is doing a pattern
    /// match over a handful of paths, not walking the repository.
    private static let timeout: TimeInterval = 10

    static func classify(candidates: [URL], root: URL, gitPath: String?) -> Verdict {
        guard let gitPath else {
            return .undetermined(reason: "git was not found on this machine, so this app could not ask it which files are ignored. It never guesses at gitignore rules itself.")
        }
        guard isInsideWorkTree(root: root, gitPath: gitPath) else {
            return .undetermined(reason: "This project is not inside a git repository, so there are no gitignore rules to check it against.")
        }
        guard let ignored = ignoredPaths(candidates: candidates, root: root, gitPath: gitPath) else {
            return .undetermined(reason: "git was found but `git check-ignore` did not complete, so this app could not tell which of these files are ignored.")
        }
        let exposed = candidates.filter { !ignored.contains($0.path) }
        return .answered(exposed: exposed, tracked: trackedPaths(exposed, root: root, gitPath: gitPath))
    }

    private static func isInsideWorkTree(root: URL, gitPath: String) -> Bool {
        guard let outcome = CommandRunner.run(
            gitPath, arguments: ["-C", root.path, "rev-parse", "--is-inside-work-tree"], timeout: timeout)
        else { return false }
        return outcome.terminationStatus == 0
            && outcome.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// The paths git reports as ignored, or nil if git failed outright.
    ///
    /// `--stdin -z` rather than passing paths as arguments: `-z` is only
    /// accepted together with `--stdin` (git refuses otherwise), and NUL
    /// separation is the only encoding that survives a filename containing a
    /// newline. git echoes back each *ignored* path exactly as it was fed in,
    /// so the returned set can be compared against the input strings directly.
    ///
    /// Exit codes, from git's own documentation: 0 means one or more of the
    /// given paths is ignored, 1 means none of them is, and anything else is a
    /// real error. 1 is therefore a successful answer, not a failure.
    ///
    /// One consequence worth stating, because it is the *correct* behaviour
    /// and looks like a bug: a file that is already tracked is reported as
    /// **not** ignored even when a matching pattern exists. That is what git
    /// means — the file is in the repository, so the pattern is moot. A
    /// committed `.env` therefore lands in `exposed`, which is exactly where a
    /// committed plaintext secret belongs.
    private static func ignoredPaths(candidates: [URL], root: URL, gitPath: String) -> Set<String>? {
        guard !candidates.isEmpty else { return [] }
        let input = Data(candidates.map { $0.path + "\0" }.joined().utf8)

        guard let outcome = CommandRunner.run(
            gitPath,
            arguments: ["-C", root.path, "check-ignore", "--stdin", "-z"],
            standardInput: input,
            timeout: timeout
        ), !outcome.timedOut else { return nil }

        switch outcome.terminationStatus {
        case 0, 1: break
        default: return nil
        }
        return Set(outcome.standardOutputText.split(separator: "\0").map(String.init))
    }

    /// Which of `paths` git already tracks. Best-effort: a failure here only
    /// costs a sentence of extra advice, never the verdict itself.
    private static func trackedPaths(_ paths: [URL], root: URL, gitPath: String) -> Set<String> {
        guard !paths.isEmpty else { return [] }
        guard let outcome = CommandRunner.run(
            gitPath,
            arguments: ["-C", root.path, "ls-files", "-z", "--"] + paths.map(\.path),
            timeout: timeout
        ), outcome.terminationStatus == 0, !outcome.timedOut else { return [] }

        // ls-files prints paths relative to the repository root, so match on
        // the trailing component rather than the absolute string.
        let relative = Set(outcome.standardOutputText.split(separator: "\0").map(String.init))
        return Set(paths.map(\.path).filter { path in
            relative.contains { path.hasSuffix("/" + $0) || path == $0 }
        })
    }
}
