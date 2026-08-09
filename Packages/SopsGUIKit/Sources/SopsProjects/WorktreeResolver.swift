import Foundation

/// What a directory is, relationship-wise, to a git repository.
///
/// `mainRepository` covers both an ordinary checkout (`.git` is a directory)
/// and a repository whose `.git` is a file that does not follow the linked-
/// worktree layout — a submodule checkout, for instance. Both are real,
/// independently usable git repositories; neither is grouped under anything
/// else, so there is nothing more specific and true to say about them.
public enum RepositoryKind: Equatable, Sendable {
    case mainRepository(root: String)
    case worktree(root: String, mainRepository: String)
    case notAGitRepository
}

/// Detects whether a directory is a git repository and, if it is a linked
/// worktree, which repository it belongs to — so the project sidebar can
/// group a repository's worktrees together instead of listing them as
/// unrelated projects.
///
/// Reads the `.git` entry directly rather than shelling out to `git`: the
/// format is stable and documented (`gitrepository-layout(5)`), and reading
/// a small file is cheaper than spawning a process per project. This never
/// writes anything and never touches file contents beyond `.git` itself, so
/// there is nothing here that could leak a secret value.
public enum WorktreeResolver {

    /// Classifies `path`. `path` is used verbatim in any `root`/
    /// `mainRepository` value returned — it is not normalized or symlink-
    /// resolved here, so a caller that wants a canonical path must normalize
    /// before calling (as `ProjectStore` does).
    public static func kind(of path: String) -> RepositoryKind {
        let fileManager = FileManager.default
        let gitPath = (path as NSString).appendingPathComponent(".git")

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitPath, isDirectory: &isDirectory) else {
            return .notAGitRepository
        }

        if isDirectory.boolValue {
            return .mainRepository(root: path)
        }

        // `.git` is a file: it must contain a `gitdir: <path>` pointer.
        // Real git always writes exactly this, terminated by a newline;
        // anything else (empty, missing prefix, garbage) is corrupt or
        // hand-authored and is treated as "not a repository" rather than
        // guessed at.
        guard let contents = try? String(contentsOfFile: gitPath, encoding: .utf8) else {
            return .notAGitRepository
        }

        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "gitdir:"
        guard trimmed.hasPrefix(prefix) else {
            return .notAGitRepository
        }

        let pointerText = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespaces)
        guard !pointerText.isEmpty else {
            return .notAGitRepository
        }

        // git resolves a relative pointer relative to the directory the
        // `.git` file lives in (i.e. `path` itself) — that is how a
        // submodule's `gitdir: ../.git/modules/<name>` resolves correctly.
        let pointerURL: URL
        if pointerText.hasPrefix("/") {
            pointerURL = URL(fileURLWithPath: pointerText)
        } else {
            pointerURL = URL(fileURLWithPath: path).appendingPathComponent(pointerText)
        }
        let resolvedGitDir = pointerURL.standardizedFileURL

        // The pointed-at directory must actually exist. A `gitdir:` pointer
        // whose target is gone is not a worktree of nowhere — it is not a
        // usable repository at all.
        var pointedIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedGitDir.path, isDirectory: &pointedIsDirectory),
              pointedIsDirectory.boolValue
        else {
            return .notAGitRepository
        }

        // A pointer shaped like `<main>/.git/worktrees/<name>` is what a
        // linked worktree looks like — but the shape check alone is purely
        // lexical (path component names via `standardizedFileURL`, which
        // does not follow a symlink to its target — though it is *not* the
        // pure string operation this comment used to claim: measured,
        // `URL(fileURLWithPath: "/private/tmp").standardizedFileURL.path` is
        // `/tmp`, so it does rewrite the macOS `/private` prefix. Worse for
        // anything that compares URLs, the standardized `/private/tmp` and
        // `/tmp` URLs are **not `==`** despite both reporting `/tmp` as their
        // path. Compare `.path`, never the URLs, and see `CanonicalPath` for
        // the type that exists to make that unnecessary — it is not used here
        // yet, which is recorded as M3 work rather than fixed mid-review).
        // A directory that merely has the right
        // names in its path — by corruption, by a stale pointer left behind
        // by tooling, or via a symlink standing in for one of those path
        // components — is not a worktree just because its path looks like
        // one. Only trust the shape once the target also contains what git
        // actually writes into a worktree's private git dir: `HEAD` and
        // `commondir` (`gitrepository-layout(5)`). `fileExists` resolves
        // symlinks transparently, so this same check rejects the symlink
        // variant of the attack too — a hollow directory stays hollow no
        // matter how it was reached.
        let worktreesDir = resolvedGitDir.deletingLastPathComponent()
        let dotGitDir = worktreesDir.deletingLastPathComponent()
        let looksLikeWorktreePath = worktreesDir.lastPathComponent == "worktrees"
            && dotGitDir.lastPathComponent == ".git"

        if looksLikeWorktreePath, looksLikeWorktreeAdminDirectory(at: resolvedGitDir) {
            let mainRepositoryRoot = dotGitDir.deletingLastPathComponent().path
            return .worktree(root: path, mainRepository: mainRepositoryRoot)
        }

        // Anything else that resolves to a real *git* directory (a
        // submodule's `<parent>/.git/modules/<name>`, or any other custom
        // `.git` file layout) is a real, standalone repository at `path` —
        // just not one grouped under another repository, since we cannot
        // honestly derive that relationship from this layout. But the
        // target must actually look like a git admin directory first:
        // `HEAD`, `objects`, and `config` together are the conventional
        // signature of one. Without that, a `.git` file can point at *any*
        // existing directory — a corrupted pointer, or a stale one left
        // behind by SPM- or CocoaPods-style checkouts — and an ordinary
        // empty folder would otherwise be reported as a real repository,
        // indistinguishable from a genuine submodule.
        guard looksLikeGitAdminDirectory(at: resolvedGitDir) else {
            return .notAGitRepository
        }
        return .mainRepository(root: path)
    }

    /// `HEAD` and `commondir` are the two files git always writes into a
    /// linked worktree's private git directory (`<main>/.git/worktrees/<name>`).
    /// Both together are unlikely to appear by accident, and cheap to check.
    private static func looksLikeWorktreeAdminDirectory(at url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: url.appendingPathComponent("HEAD").path)
            && fileManager.fileExists(atPath: url.appendingPathComponent("commondir").path)
    }

    /// `HEAD`, `objects`, and `config` together are the conventional
    /// signature of a git admin directory — present in an ordinary `.git`
    /// directory and in a submodule's `.git/modules/<name>` gitdir alike.
    /// Requiring all three (with `objects` specifically a directory, since
    /// that is what git creates) rejects an arbitrary directory a corrupted
    /// or stale pointer might point at, while still accepting a real
    /// submodule — verified against a `git submodule add` fixture.
    private static func looksLikeGitAdminDirectory(at url: URL) -> Bool {
        let fileManager = FileManager.default
        var objectsIsDirectory: ObjCBool = false
        let hasObjectsDirectory = fileManager.fileExists(
            atPath: url.appendingPathComponent("objects").path, isDirectory: &objectsIsDirectory)
            && objectsIsDirectory.boolValue
        return fileManager.fileExists(atPath: url.appendingPathComponent("HEAD").path)
            && hasObjectsDirectory
            && fileManager.fileExists(atPath: url.appendingPathComponent("config").path)
    }
}
