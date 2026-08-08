import Foundation

/// A `HealthFinding` that has been through scope accounting.
///
/// The initializer is `fileprivate`, so the only way anywhere in this package
/// to obtain one is to ask a `ProjectScopeAccountant` — which appends the scope
/// disclosure and refuses to let an affirmative verdict stand over a walk that
/// did not cover the tree. `ProjectHealthCheck.findings(for:)` returns
/// `[ScopedFinding]`, so a project finding that skipped the accountant is not
/// merely discouraged, it does not typecheck.
///
/// This exists because the previous shape of the fix was correct and still
/// rotted. Disclosure was applied by calling a local `withScope(_:)` helper at
/// each of six `return` sites; a whole-branch review found that deleting all
/// six calls turned nothing red, and that four further branches had never
/// called it at all. A convention that every author must remember, and that no
/// test enforces, is not a fix — it is the same silent constant one layer up.
public struct ScopedFinding: Sendable, Equatable {
    public let finding: HealthFinding
    fileprivate init(_ finding: HealthFinding) { self.finding = finding }
}

/// Turns a raw verdict into a finding that accounts for what the walk behind it
/// did not reach: the scope paragraph, and the status floor.
///
/// One object per project per run, holding the `ScannedTree` the findings are
/// about, so no call site has to remember to pass the tree, look at
/// `limitations`, or decide again whether `.ok` is still available to it.
struct ProjectScopeAccountant {

    let tree: ScannedTree
    /// The project root, used only to shorten the paths named in the
    /// disclosure. Absolute paths in prose are unreadable and the user already
    /// knows which project this is.
    let rootPath: String

    /// The opening clause every scope disclosure starts with, and the only one.
    /// Factored out because it is the structural guarantee, not just a string:
    /// exactly one of these appears per finding, so every reason the walk fell
    /// short reads as one account of what was missed rather than as several
    /// paragraphs a reader has to reconcile.
    static let leadIn = "Not everything under this project was looked at"

    /// How many names a clause spells out before it switches to "and N more".
    ///
    /// `ProjectScanner.skippedDirectoryNames` has twenty entries, so an
    /// unsummarised worst case is a twenty-item comma list in the middle of a
    /// paragraph — a wall nobody reads, which is the same "the user cannot
    /// actually act on this" failure as saying nothing at all, dressed up as
    /// diligence. Eight covers every realistic project outright: this
    /// repository hits three, a JS monorepo four or five, and reaching nine
    /// means a tree that is simultaneously a JS, Swift, Rust, Go, Ruby, Python
    /// and Terraform project — at which point the individual names have stopped
    /// being the information and the *count* has started being it.
    ///
    /// What is never summarised away is the count itself: every clause states
    /// exactly how many names are not shown, so the size of what was missed is
    /// never hidden, only the tail of a sorted list.
    static let namesShown = 8

    /// What a finding is a verdict *about*, which decides whether the walk's
    /// shortfalls bear on it at all.
    ///
    /// Required at every call site, with no default, on the same principle as
    /// the exhaustive `switch` over `ScanLimitation`: the author of a new
    /// finding has to say which of these it is, and the answer is visible in
    /// one word at the call site rather than inferable only by reading the
    /// prose. A finding about the tree carries the tree's blind spots; a
    /// finding about one file the check opened by name does not, and hanging
    /// "this scan never enters .git" off "your .sops.yaml parses" would be
    /// noise that teaches users to skip the paragraph that matters.
    ///
    /// This is the one place a determined author could still route a tree-wide
    /// claim around the disclosure, by declaring it `.oneKnownPath`. That is as
    /// far as a type system reaches: the choice is forced, named, and sits in
    /// the diff.
    enum FindingSubject {
        /// A verdict whose coverage is exactly the walk's coverage.
        case theWholeTree
        /// A verdict about one path this check looked at directly, by name,
        /// without going through the walk.
        case oneKnownPath(String)
    }

    /// The one way to build a project finding.
    ///
    /// Two things happen here that no call site can skip:
    ///
    /// 1. **The status floor.** A walk carrying any limitation that
    ///    `blocksAffirmativeVerdict` cannot support `.ok`, and cannot support
    ///    `.skipped` either — "no encrypted files were found here" is just as
    ///    affirmative a claim about absence as "they all match", and it was one
    ///    of the reproduced falsehoods. Both become `.unknown` with a reason
    ///    naming the broadest thing missed. A `.warning` or `.problem` is left
    ///    exactly as it is: a real, actionable finding must never be buried
    ///    under a caveat.
    /// 2. **The disclosure.** The scope paragraph is appended to the detail,
    ///    on every branch, or omitted entirely when the walk did cover the
    ///    whole tree — the disclosure must not become boilerplate that appears
    ///    on findings it does not apply to.
    func finding(about subject: FindingSubject,
                 id: String, title: String, status: HealthStatus, detail: String,
                 remediation: Remediation? = nil) -> ScopedFinding {
        guard case .theWholeTree = subject else {
            return ScopedFinding(HealthFinding(id: id, title: title, status: status,
                                               detail: detail, remediation: remediation))
        }
        let blocking = tree.limitations.filter(\.blocksAffirmativeVerdict)
        var status = status
        if !blocking.isEmpty, Self.isAffirmative(status) {
            status = .unknown(reason: Self.blockedVerdictReason(blocking))
        }
        let detail = Self.scopeSentence(tree: tree, relativeTo: rootPath)
            .map { detail + "\n\n" + $0 } ?? detail
        return ScopedFinding(HealthFinding(id: id, title: title, status: status,
                                           detail: detail, remediation: remediation))
    }

    /// Statuses that assert something positive about the whole subject, and so
    /// cannot stand over a walk that did not see all of it. Spelled out rather
    /// than written as `status == .ok`, because `.skipped` is the sneakier of
    /// the two: it reads as informational while claiming the subject does not
    /// exist.
    private static func isAffirmative(_ status: HealthStatus) -> Bool {
        switch status {
        case .ok, .skipped: true
        case .warning, .problem, .unknown: false
        }
    }

    // MARK: - The sentence

    /// What this walk deliberately or unavoidably did not cover, as one
    /// paragraph — or `nil` when it covered the whole tree and there is nothing
    /// to disclose.
    ///
    /// Nothing is excused from disclosure, `.git` included. It is tempting to
    /// treat VCS internals as too obvious to mention, but a carve-out list of
    /// "exclusions that don't count" is the silent constant this whole type
    /// exists to abolish, re-created one level down — and `.git/config` holding
    /// a remote URL with an embedded token is an ordinary way to leak a
    /// credential, not a hypothetical.
    ///
    /// Directory exclusions are named, not pathed: `ProjectScanner` skips by
    /// directory *name* anywhere in the tree, so "this scan never enters
    /// `.build`" is the accurate statement and a list of the specific paths it
    /// declined would be both longer and less true. Everything else here *is* a
    /// specific place, so it is named by its path relative to the project root.
    static func scopeSentence(tree: ScannedTree, relativeTo rootPath: String?) -> String? {
        let clauses = Self.clauses(for: tree.limitations, relativeTo: rootPath)
        guard !clauses.isEmpty else { return nil }
        return "\(leadIn): " + clauses.joined(separator: "; ")
            + ". Nothing above is a statement about what it did not reach."
    }

    /// One clause per *kind* of limitation, in a fixed order — broadest first,
    /// so a reader who stops after the first clause has read the biggest gap.
    ///
    /// The `switch` is exhaustive with no `default` on purpose. See
    /// `ScanLimitation`'s type-level comment: this is the point at which a new
    /// way of not looking at something stops compiling until it has a sentence.
    private static func clauses(for limitations: [ScanLimitation],
                                relativeTo rootPath: String?) -> [String] {
        var excluded: [String] = []
        var truncated = false
        var unreadableDirectories: [String] = []
        var unreadableFiles: [String] = []
        var unfollowedLinks: [String] = []
        var oversizedMetadata: [String] = []

        for limitation in limitations {
            switch limitation {
            case .excludedDirectoryName(let name): excluded.append(name)
            case .budgetExhausted: truncated = true
            case .unreadableDirectory(let path):
                unreadableDirectories.append(Self.display(path, relativeTo: rootPath))
            case .unreadableFile(let path):
                unreadableFiles.append(Self.display(path, relativeTo: rootPath))
            case .directorySymlinkNotFollowed(let path):
                unfollowedLinks.append(Self.display(path, relativeTo: rootPath))
            case .metadataBlockTooLarge(let path):
                oversizedMetadata.append(Self.display(path, relativeTo: rootPath))
            }
        }

        var clauses: [String] = []
        if truncated {
            clauses.append("it stopped at its scan budget of \(ProjectScanner.maxScannedFiles) files, "
                + "so an unknown number of the files past that point were never opened")
        }
        if !excluded.isEmpty {
            let sorted = excluded.sorted()
            let plural = sorted.count > 1
            clauses.append("this scan never enters \(Self.summarised(sorted)), "
                + "\(plural ? "directory names" : "a directory name") this app always skips as "
                + "dependency, build or version-control output")
        }
        if !unreadableDirectories.isEmpty {
            clauses.append("it could not list \(Self.counted(unreadableDirectories, plural: "directories")), "
                + "so what is inside \(unreadableDirectories.count == 1 ? "it" : "them") was never seen")
        }
        if !unfollowedLinks.isEmpty {
            clauses.append("it did not follow \(Self.counted(unfollowedLinks, plural: "symbolic links")), "
                + "\(unfollowedLinks.count == 1 ? "a symbolic link" : "links") pointing at a directory, so what "
                + "\(unfollowedLinks.count == 1 ? "it points" : "they point") at was never walked")
        }
        if !unreadableFiles.isEmpty {
            clauses.append("it could not read \(Self.counted(unreadableFiles, plural: "files")), "
                + "so what \(unreadableFiles.count == 1 ? "it holds" : "they hold") was never seen")
        }
        if !oversizedMetadata.isEmpty {
            let sorted = oversizedMetadata.sorted()
            clauses.append(sorted.count == 1
                ? "\(sorted[0]) carries a sops metadata block larger than this app reads from a file's end, "
                    + "so its recipient list was never read"
                : "\(sorted.count) files (\(Self.summarised(sorted))) carry sops metadata blocks larger than "
                    + "this app reads from a file's end, so their recipient lists were never read")
        }
        return clauses
    }

    /// The reason attached to a status this accountant demoted. Broadest gap
    /// first, on the same principle as the clause order: a one-line status
    /// should carry the reason the user can least easily bound for themselves.
    ///
    /// Total by construction — the final fallback covers the case where the
    /// only limitations present are non-blocking ones, which this function is
    /// never called with today but which a future edit could produce.
    static func blockedVerdictReason(_ limitations: [ScanLimitation]) -> String {
        if limitations.contains(.budgetExhausted) {
            return "This project has more files than this app's scan budget, so part of the tree was never checked."
        }
        for limitation in limitations {
            switch limitation {
            case .unreadableDirectory:
                return "Part of this project could not be listed, so this app did not see everything under it."
            case .directorySymlinkNotFollowed:
                return "This project contains a symbolic link to a directory, which this scan does not follow, so what it points at was never looked at."
            case .unreadableFile:
                return "Part of this project could not be read, so this app did not see everything in it."
            case .metadataBlockTooLarge:
                return "An encrypted file here carries a sops metadata block larger than this app reads, so its recipient list was never checked."
            case .excludedDirectoryName, .budgetExhausted:
                continue
            }
        }
        return "Part of this project was not looked at, so this is not a verdict on the whole of it."
    }

    // MARK: - Formatting

    /// A path as the finding names it: relative to the project root when it is
    /// under it, absolute otherwise (a symlink target, or a root spelled
    /// differently than the walk enumerated it).
    private static func display(_ path: String, relativeTo rootPath: String?) -> String {
        let canonical = CanonicalPath.ofLeaf(path)
        guard let rootPath else { return canonical }
        let prefix = CanonicalPath.of(rootPath) + "/"
        return canonical.hasPrefix(prefix) ? String(canonical.dropFirst(prefix.count)) : canonical
    }

    /// "3 directories (a, b and c)", or just "a" when there is one of them —
    /// a count in front of a single name reads as bureaucracy, and the name on
    /// its own is the thing the user can act on.
    private static func counted(_ items: [String], plural: String) -> String {
        let sorted = items.sorted()
        guard sorted.count > 1 else { return sorted.first ?? "" }
        return "\(sorted.count) \(plural) (\(Self.summarised(sorted)))"
    }

    /// A sorted list as a sentence fragment, summarised past `namesShown` —
    /// see that constant for why, and for what is deliberately never summarised
    /// away.
    private static func summarised(_ sorted: [String]) -> String {
        guard sorted.count > namesShown else {
            guard let last = sorted.last else { return "" }
            guard sorted.count > 1 else { return last }
            return sorted.dropLast().joined(separator: ", ") + " and " + last
        }
        return sorted.prefix(namesShown).joined(separator: ", ")
            + " and \(sorted.count - namesShown) more"
    }
}
