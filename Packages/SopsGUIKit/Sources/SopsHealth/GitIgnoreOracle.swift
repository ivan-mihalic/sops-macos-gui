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
///
/// **But read-only is not the same as harmless**, and that distinction cost
/// this app an arbitrary-code-execution hole. See `safeArguments`.
enum GitIgnoreOracle {

    /// Every `git` invocation here starts with these, and none may be called
    /// without them.
    ///
    /// ## What this closes
    ///
    /// `core.fsmonitor` is a **repository-local** config key whose value git
    /// executes. A repository the user merely cloned or unpacked can set it in
    /// its own `.git/config`, and then any git command that consults the index
    /// runs that program. This oracle runs on every project scan, so the
    /// sequence was: add a project → the scan finds a file named `.env` → the
    /// attacker's script runs as the user.
    ///
    /// Verified, not theorised — git 2.54.0, a hook that touched a marker
    /// file, driven through the same `check-ignore --stdin -z` call below:
    /// the marker appeared. With `-c core.fsmonitor=` prepended it did not.
    ///
    /// `safe.directory` does not help: the user owns the directory they just
    /// cloned into, which is exactly the case that check is designed to allow.
    ///
    /// This also breached the app's own hardest rule — "the app never mutates
    /// the system" — by handing a third party the ability to do so. A
    /// read-only *git subcommand* is not a read-only *operation* when git's
    /// configuration can name a program to run.
    ///
    /// ## Why not `-c protocol.*` and friends too
    ///
    /// Nothing here fetches, so no transport config is reachable. If a
    /// subcommand that touches the network is ever added, this list needs
    /// revisiting — which is the other reason it is one constant rather than
    /// three call sites.
    private static let safeArguments = ["-c", "core.fsmonitor="]

    /// **The only place in this app that runs git.**
    ///
    /// A single chokepoint rather than a helper the three call sites politely
    /// agree to use. The earlier shape — each site assembling its own argument
    /// list through `gitArguments` — was guarded by a test that counted string
    /// matches, and a review walked past it five ways: rename the local
    /// holding the executable, write `self.gitPath`, put the guarded token in
    /// a comment, or delete `safeArguments` from the helper while leaving
    /// every call site untouched.
    ///
    /// Counting call sites was the wrong idea. With one function there is
    /// nothing to count: a new git invocation either goes through here and is
    /// protected, or is a visibly separate `Process`/`CommandRunner.run` that
    /// no longer looks like the rest of the file.
    ///
    /// `-c` must precede the subcommand, which is why the config goes in front
    /// of `-C` rather than being appended.
    private static func runGit(
        _ gitPath: String,
        in root: URL,
        _ subcommand: [String],
        standardInput: Data? = nil
    ) -> CommandOutcome? {
        CommandRunner.run(
            gitPath,
            arguments: safeArguments + ["-C", root.path] + subcommand,
            standardInput: standardInput,
            timeout: timeout)
    }

    enum Verdict {
        /// git answered. `exposed` are the paths git does **not** ignore, and
        /// `tracked` are the subset of those already committed to the
        /// repository — for which adding a gitignore line changes nothing.
        case answered(exposed: [URL], tracked: Set<String>)
        /// `root` is not inside a git repository at all — searched upward the
        /// same way git itself does, and there is no `.git` anywhere above
        /// it. This is a *definite fact* about the project, not a missing
        /// answer: ticket #8, claim 2, found that the previous code
        /// collapsed this into `.undetermined`, so a project with no git at
        /// all could never reach a verdict about its plaintext secrets — only
        /// ever "unknown", forever. Kept distinct from `.undetermined` so
        /// `ProjectHealthCheck.gitignoreFinding` can say the more useful,
        /// still-honest thing: nothing here can be committed to a repository
        /// by accident, because there is no repository.
        case noRepository
        /// git could not answer, and the reason is shown to the user verbatim.
        /// Never downgraded to a guess.
        case undetermined(reason: String)
    }

    /// The timeout for each git invocation. Generous: git is doing a pattern
    /// match over a handful of paths, not walking the repository.
    private static let timeout: TimeInterval = 10

    static func classify(candidates: [URL], root: URL, gitPath: String?) -> Verdict {
        guard let gitPath else {
            // No git binary still leaves one honest question answerable
            // without it: whether a `.git` exists at `root` or above at all.
            // That is a plain filesystem check — see `hasGitDirectoryAtOrAbove`
            // — and finding none is the same `.noRepository` fact the
            // `.outside` branch below reaches through git itself. Only when a
            // `.git` *does* exist (so answering further needs git) does the
            // missing binary actually block a verdict.
            guard Self.hasGitDirectoryAtOrAbove(root) else { return .noRepository }
            return .undetermined(reason: "git was not found on this machine, so this app could not ask it which files are ignored. It never guesses at gitignore rules itself.")
        }
        switch workTreeVerdict(root: root, gitPath: gitPath) {
        case .inside:
            break
        case .outside:
            return .noRepository
        case .unreadable:
            return .undetermined(reason: "git did not finish answering whether this project is inside a repository, so this app could not check its gitignore rules. It never guesses.")
        }
        guard let ignored = ignoredPaths(candidates: candidates, root: root, gitPath: gitPath) else {
            return .undetermined(reason: "git was found but `git check-ignore` did not complete, so this app could not tell which of these files are ignored.")
        }
        let exposed = candidates.filter { !ignored.contains($0.path) }
        return .answered(exposed: exposed, tracked: trackedPaths(exposed, root: root, gitPath: gitPath))
    }

    /// Three answers, not two.
    ///
    /// This returned `Bool`, which collapsed "git says no" and "we could not
    /// read git's answer" into the same value — and `classify` turned that
    /// into the sentence *"This project is not inside a git repository"* about
    /// a directory that is one. Same family as every other finding in this
    /// milestone: a confident claim standing in for a missing one.
    ///
    /// It reaches `outputComplete` for the same reason `ignoredPaths` does. A
    /// truncated `rev-parse` gives `tru`, which is not `true`, which read as
    /// "not a repository". The comment on `ignoredPaths` claiming this was
    /// needed "here and nowhere else in this file" was wrong when written.
    private enum WorkTreeVerdict {
        case inside
        case outside
        /// git did not answer, or its answer was cut short.
        case unreadable
    }

    private static func workTreeVerdict(root: URL, gitPath: String) -> WorkTreeVerdict {
        guard let outcome = runGit(gitPath, in: root, ["rev-parse", "--is-inside-work-tree"]),
              !outcome.timedOut, outcome.standardOutputComplete
        else { return .unreadable }

        let answer = outcome.standardOutputText.trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome.terminationStatus == 0 && answer == "true" { return .inside }
        if answer == "false" { return .outside }

        // Iteration 8 said "git's silence is not git saying no" and then
        // treated **any** non-zero exit as `.outside`, which is the other half
        // of the same mistake: git's *failure* is not git saying no either.
        // Measured against git 2.54.0, all three of these exited non-zero and
        // were reported as "not inside a git repository":
        //
        //   - an unreadable directory        → 128, "cannot change to …: Permission denied"
        //   - the root removed or unmounted  → 128, "cannot change to …: No such file or directory"
        //   - a broken git (xcrun shim)      →   1, "invalid active developer path"
        //
        // The last is the canonical macOS "Command Line Tools are missing"
        // state and is fully reachable, because `ToolLocator.locate` returns a
        // tool even when its version probe produced nothing.
        //
        // So a non-zero exit only means "outside" when git says that is what
        // it means. Everything else is an absence of an answer.
        // Matching on git's wording is the only signal available, and the
        // previous attempt at it had the two branches the wrong way round.
        //
        // Measured, git 2.54.0, `rev-parse --is-inside-work-tree`:
        //
        //   - a directory outside any repository:
        //     `fatal: not a git repository (or any of the parent directories): .git`
        //   - a repository whose `.git` is damaged: **the same message**
        //   - a linked worktree whose main clone is gone:
        //     `fatal: not a git repository: (null)`
        //
        // So the parent-directories wording is the *canonical* "you are not in
        // a repository" — iteration 10 classified it as unreadable, which made
        // `.outside` unreachable through a real git and told users with an
        // ordinary non-repository project that git "did not finish answering".
        // For a secrets GUI, a project outside a repository is a common case,
        // not an error state.
        //
        // The message alone cannot separate "outside" from "damaged", so the
        // filesystem answers: an existing `.git` means the message is about a
        // repository that is broken, not absent.
        //
        // **Searched upward, not just at the root**, and the first version of
        // this looked only at `root`. Git says "or any of the parent
        // directories" because that is exactly what it searched, and it prints
        // the same sentence from anywhere inside a repository whose `.git` is
        // damaged. A project is very often a subdirectory of its repository, so
        // looking only at `root` sent every such user back to the confident,
        // false "this project is not inside a git repository" — the very claim
        // the round before had just fixed, moved down one directory level. The
        // round's own tests could not see it: both built `.git` in `root`.
        //
        // If a healthy `.git` existed anywhere above, git would have found it
        // and never printed this message, so reaching here with one present
        // means it is damaged.
        guard outcome.standardErrorComplete else { return .unreadable }
        let complaint = outcome.standardErrorText.lowercased()

        // An orphaned worktree names no path at all.
        if complaint.contains("(null)") { return .unreadable }

        if complaint.contains("not a git repository") {
            return Self.hasGitDirectoryAtOrAbove(root) ? .unreadable : .outside
        }
        return .unreadable
    }

    /// Whether a `.git` entry exists at `directory` or at any ancestor of it,
    /// the same search git itself performs before printing "or any of the
    /// parent directories".
    ///
    /// Bounded by walking until the path stops shortening, so a symlink loop or
    /// an unusual root cannot spin here. `.git` is a directory in an ordinary
    /// checkout and a file in a linked worktree or submodule — either counts,
    /// which is why this asks about existence rather than type.
    private static func hasGitDirectoryAtOrAbove(_ directory: URL) -> Bool {
        var current = directory.standardizedFileURL
        while true {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return false }
            current = parent
        }
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

        // A short ignore list silently promotes every missing entry to
        // "not ignored", which surfaces as a confident plaintext-leak report
        // about files git is ignoring perfectly well — hence `outputComplete`.
        guard let outcome = runGit(
            gitPath, in: root, ["check-ignore", "--stdin", "-z"], standardInput: input),
            !outcome.timedOut, outcome.standardOutputComplete
        else { return nil }

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
        guard let outcome = runGit(
            gitPath, in: root, ["ls-files", "-z", "--"] + paths.map(\.path)),
            outcome.terminationStatus == 0, !outcome.timedOut, outcome.standardOutputComplete
        else { return [] }

        // ls-files prints paths relative to the repository root, so match on
        // the trailing component rather than the absolute string.
        let relative = Set(outcome.standardOutputText.split(separator: "\0").map(String.init))
        return Set(paths.map(\.path).filter { path in
            relative.contains { path.hasSuffix("/" + $0) || path == $0 }
        })
    }
}
