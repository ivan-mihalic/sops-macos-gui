import Foundation

/// One spelling for a filesystem path, so two strings naming the same file
/// compare equal.
///
/// Two things get in the way on macOS, and both bite this package repeatedly.
/// `FileManager.temporaryDirectory` hands back `/var/folders/…`, while a
/// directory enumeration of that same root yields its children as
/// `/private/var/folders/…` — `/var` is a symlink to `/private/var`. And
/// Foundation's own asymmetry: `resolvingSymlinksInPath()` *removes* a leading
/// `/private`, it does not add one, so it alone does not reconcile the two.
/// Resolving and then dropping a leading `/private` does.
///
/// This used to exist three times over — in `ProjectHealthCheck`, in
/// `TailReadLedger.Reading`, and (as a fourth would-be copy) wherever the next
/// caller needed it. Three copies of a normalisation rule is three chances for
/// one of them to drift, and the failure mode when they do is silent: a
/// comparison that never matches, an assertion that passes vacuously against
/// zero bytes, a scope disclosure that fails to recognise its own root.
enum CanonicalPath {
    static func of(_ path: String) -> String {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return resolved.hasPrefix("/private/") ? String(resolved.dropFirst("/private".count)) : resolved
    }

    /// The same normalisation applied to a path's *containing directory*, with
    /// its final component left exactly as it was written.
    ///
    /// This is the right form for anything a finding names, and `of(_:)` is
    /// not, because `of(_:)` resolves symbolic links all the way through. A
    /// project containing `linked -> /elsewhere` had its disclosure print
    /// `/elsewhere` — the target — where the user needed to read `linked`, the
    /// name they created and the only one they can act on. Same for a `.env`
    /// reachable through a link: the finding named a path outside the project
    /// instead of the one inside it.
    ///
    /// The containing directory is still resolved, because that is what
    /// reconciles `/var/folders/…` against `/private/var/folders/…` and lets a
    /// path be recognised as being under the project root at all.
    static func ofLeaf(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent().path
        guard !parent.isEmpty, parent != path else { return of(path) }
        let base = of(parent)
        return base.hasSuffix("/") ? base + url.lastPathComponent
            : base + "/" + url.lastPathComponent
    }
}
