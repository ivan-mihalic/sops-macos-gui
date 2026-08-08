import Foundation

/// One place a walk of a project tree did not reach, and why.
///
/// ## Why this is a closed enum and not a handful of booleans
///
/// PROPOSAL.md §6 D requires an exclusion to be *"stated in the finding, not
/// buried in a constant"*, and forbids the check from *"report[ing] OK about
/// files it did not look at"*. That requirement has now been missed twice, in
/// two separate rounds, and both times for the same structural reason: the
/// scanner grew a *new* way of not looking at something, and nothing forced
/// anyone to notice. The first round found three (hidden files, a root-only
/// plaintext scan, an unmatched creation rule). A whole-branch review then
/// found five more that the first round's fix had not touched — a second
/// exclusion mechanism (`.skipsPackageDescendants`) sitting silently beside the
/// disclosed one, an unreadable file, an unreadable directory, an unfollowed
/// directory symlink, and an unreadable project root — plus a tail-read cap
/// whose doc comment overstated its own reach.
///
/// Every one of those was expressible only as "the scanner quietly does not do
/// this". None of them had anywhere to be recorded, so no finding could admit
/// to them even in principle. Adding a sixth boolean to `ScannedTree` would
/// have produced a seventh omission next time.
///
/// So: every way this walk falls short of the whole tree is a case of this
/// enum, and `ProjectScopeAccountant` switches over it **exhaustively** — no
/// `default`, deliberately. A new way of not looking at something cannot
/// compile until someone has written the sentence that admits to it and decided
/// whether it may still be reported as OK. That is the property that was
/// missing, and it is the only kind of guarantee that survives a third round.
public enum ScanLimitation: Sendable, Hashable {
    /// A directory this app always declines to enter, by name, anywhere in the
    /// tree — see `ProjectScanner.skippedDirectoryNames`.
    case excludedDirectoryName(String)
    /// The walk stopped at `ProjectScanner.maxScannedFiles`.
    case budgetExhausted
    /// A directory whose contents could not be listed (permissions, most
    /// often). Its children were never enumerated.
    case unreadableDirectory(path: String)
    /// A file that could not be opened or read, or whose type could not even
    /// be determined. Its *name* was seen; its contents were not.
    case unreadableFile(path: String)
    /// A symbolic link pointing at a directory. Deliberately not followed —
    /// see `ProjectScanner.walk` — and therefore named.
    case directorySymlinkNotFollowed(path: String)
    /// A file that carries what looks like sops metadata whose block is larger
    /// than even the escalated tail read reaches, so its recipient list could
    /// not be read.
    case metadataBlockTooLarge(path: String)

    /// Whether a finding produced over a walk carrying this limitation may
    /// still claim `.ok` (or `.skipped`, which is just as affirmative about
    /// absence).
    ///
    /// Exactly one case says yes, and it is the one PROPOSAL.md §6 D blesses in
    /// as many words: the dependency/build-directory exclusion route, whose
    /// cost is paid by *stating* the exclusion rather than by demoting the
    /// status. That carve-out is bounded, permanent, named, and identical on
    /// every walk — `.git` alone guarantees it fires on every real repository,
    /// so demoting for it would make every project finding in this app
    /// permanently `.unknown`, and a status that is always on carries no
    /// information at all.
    ///
    /// Everything else is a fact about *this* tree that the app cannot bound:
    /// it does not know what was inside the directory it could not list, the
    /// file it could not read, or the link it did not follow. That is precisely
    /// "files it did not look at", so no affirmative verdict may stand over it.
    ///
    /// Spelled case by case with no `default`, for the reason in the type-level
    /// comment: the next case added has to make this decision too.
    var blocksAffirmativeVerdict: Bool {
        switch self {
        case .excludedDirectoryName: false
        case .budgetExhausted: true
        case .unreadableDirectory: true
        case .unreadableFile: true
        case .directorySymlinkNotFollowed: true
        case .metadataBlockTooLarge: true
        }
    }
}
