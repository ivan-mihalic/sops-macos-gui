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

        // Only a pointer shaped like `<main>/.git/worktrees/<name>` is a
        // linked worktree. Anything else that still resolves to a real git
        // directory (a submodule's `<parent>/.git/modules/<name>`, or any
        // other custom `.git` file layout) is a real, standalone repository
        // at `path` — just not one grouped under another repository, since
        // we cannot honestly derive that relationship from this layout.
        let worktreesDir = resolvedGitDir.deletingLastPathComponent()
        let dotGitDir = worktreesDir.deletingLastPathComponent()
        guard worktreesDir.lastPathComponent == "worktrees",
              dotGitDir.lastPathComponent == ".git"
        else {
            return .mainRepository(root: path)
        }

        let mainRepositoryRoot = dotGitDir.deletingLastPathComponent().path
        return .worktree(root: path, mainRepository: mainRepositoryRoot)
    }
}
