import Foundation
import Testing
@testable import SopsProjects

@Suite("WorktreeResolver")
struct WorktreeResolverTests {

    /// Creates a real repository with one real linked worktree.
    private func makeRepoWithWorktree() throws -> (main: String, worktree: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let main = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)

        try git(["init", "-q"], in: main)
        try "x".write(to: main.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: main)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: main)

        let wt = base.appendingPathComponent("wt")
        try git(["worktree", "add", "-q", wt.path, "-b", "feature"], in: main)
        return (main.path, wt.path)
    }

    @Test("a main repository is recognised")
    func mainRepository() throws {
        let (main, _) = try makeRepoWithWorktree()
        #expect(WorktreeResolver.kind(of: main) == .mainRepository(root: main))
    }

    @Test("a linked worktree resolves to its main repository")
    func worktreeResolvesToMain() throws {
        let (main, wt) = try makeRepoWithWorktree()
        guard case .worktree(let root, let mainRepo) = WorktreeResolver.kind(of: wt) else {
            Issue.record("expected .worktree, got \(WorktreeResolver.kind(of: wt))")
            return
        }
        #expect(root == wt)
        #expect(mainRepo == main)
    }

    @Test("a plain directory is not a repository")
    func plainDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect(WorktreeResolver.kind(of: dir.path) == .notAGitRepository)
    }

    // A .git file whose gitdir: pointer is dangling must not be reported as a
    // healthy worktree — that would group it under a repository that isn't there.
    @Test("a dangling gitdir pointer is not reported as a worktree")
    func danglingPointer() throws {
        let (_, wt) = try makeRepoWithWorktree()
        try "gitdir: /nonexistent/path/.git/worktrees/gone"
            .write(toFile: wt + "/.git", atomically: true, encoding: .utf8)
        #expect(WorktreeResolver.kind(of: wt) == .notAGitRepository)
    }

    // MARK: - Extra cases

    // This project's own convention (see repo-root CLAUDE.md): worktrees live
    // in `.worktrees/<branch>` *inside* the main checkout. That means a
    // directory scan rooted at the main repository will walk straight into
    // another repository's .git file while still under the first repository's
    // tree. Prove the resolver still reports the nested worktree correctly —
    // pointing at the true main repository, not at the folder that merely
    // contains it — using the exact real git binary, real layout this repo
    // uses.
    @Test("a worktree nested inside its own main checkout still resolves correctly")
    func nestedWorktreeInsideMainCheckout() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let main = base.appendingPathComponent("main")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)

        try git(["init", "-q"], in: main)
        try "x".write(to: main.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: main)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "init"], in: main)

        let nested = main.appendingPathComponent(".worktrees/branch-name")
        try git(["worktree", "add", "-q", nested.path, "-b", "branch-name"], in: main)

        guard case .worktree(let root, let mainRepo) = WorktreeResolver.kind(of: nested.path) else {
            Issue.record("expected .worktree, got \(WorktreeResolver.kind(of: nested.path))")
            return
        }
        #expect(root == nested.path)
        #expect(mainRepo == main.path)

        // The outer directory the nested worktree lives in is not itself a
        // repository — it must not be misreported as one.
        #expect(WorktreeResolver.kind(of: main.appendingPathComponent(".worktrees").path) == .notAGitRepository)
    }

    // A bare repository has no working tree and therefore no `.git` entry at
    // all — the repository's own root directory *is* what would otherwise be
    // the `.git` directory. There is nothing to check out or edit secrets in,
    // so the honest answer for this app's purposes is "not a repository we
    // can do anything with here", not a fabricated main-repository root.
    @Test("a bare repository is not reported as a working repository")
    func bareRepository() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bare-" + UUID().uuidString + ".git")
        try git(["init", "-q", "--bare", dir.path], in: FileManager.default.temporaryDirectory)
        #expect(WorktreeResolver.kind(of: dir.path) == .notAGitRepository)
    }

    // A submodule's checkout also has a `.git` *file* with a `gitdir:`
    // pointer (relative, per real git), but it points into
    // `<parent>/.git/modules/<name>`, not `<repo>/.git/worktrees/<name>`.
    // Reporting it as a worktree would group a submodule's independent
    // history under its parent as if they were the same repository, which
    // they are not — a submodule has its own commits and branches. It *is*
    // however a real, independently usable git repository at that path, so
    // `.mainRepository(root:)` — not grouped with anything — is the honest
    // answer, not `.notAGitRepository`.
    @Test("a submodule is not reported as a worktree")
    func submoduleIsNotAWorktree() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("repo-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let sub = base.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try git(["init", "-q"], in: sub)
        try "y".write(to: sub.appendingPathComponent("g.txt"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: sub)
        try git(["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "sub init"], in: sub)

        let parent = base.appendingPathComponent("parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try git(["init", "-q"], in: parent)
        try git(
            ["-c", "protocol.file.allow=always", "-c", "user.email=t@t", "-c", "user.name=t",
             "submodule", "add", "-q", sub.path, "subdir"],
            in: parent
        )

        let subdir = parent.appendingPathComponent("subdir")
        #expect(WorktreeResolver.kind(of: subdir.path) == .mainRepository(root: subdir.path))
    }

    @Test("a path that is not a directory at all is not a repository")
    func notADirectory() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("notadir-" + UUID().uuidString + ".txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        #expect(WorktreeResolver.kind(of: file.path) == .notAGitRepository)
    }

    @Test("an empty .git file is not a repository")
    func emptyGitFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("emptygit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "".write(toFile: dir.appendingPathComponent(".git").path, atomically: true, encoding: .utf8)
        #expect(WorktreeResolver.kind(of: dir.path) == .notAGitRepository)
    }

    @Test(".git file content without a gitdir: prefix is not a repository")
    func noGitdirPrefix() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("badgit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "this is not a pointer\n".write(
            toFile: dir.appendingPathComponent(".git").path, atomically: true, encoding: .utf8)
        #expect(WorktreeResolver.kind(of: dir.path) == .notAGitRepository)
    }

    // git always terminates the .git pointer file with a trailing newline;
    // the parser must not choke on (or be fooled by) surrounding whitespace.
    @Test("trailing whitespace around the gitdir pointer is tolerated")
    func trailingWhitespaceTolerated() throws {
        let (main, wt) = try makeRepoWithWorktree()
        let worktreeGitDir = main + "/.git/worktrees/wt"
        try "gitdir:   \(worktreeGitDir)   \n\n".write(
            toFile: wt + "/.git", atomically: true, encoding: .utf8)

        guard case .worktree(let root, let mainRepo) = WorktreeResolver.kind(of: wt) else {
            Issue.record("expected .worktree, got \(WorktreeResolver.kind(of: wt))")
            return
        }
        #expect(root == wt)
        #expect(mainRepo == main)
    }

    // A `.git` file may point at *any* existing directory — a corrupted
    // pointer, or a stale one left behind by tooling (SPM- and CocoaPods-
    // style checkouts have been observed doing this) can point at a
    // directory that is not a git admin directory at all: no HEAD, no
    // objects, no config. Reporting that as `.mainRepository` would be
    // indistinguishable from a genuine submodule while being nothing of the
    // kind. This is the review round-2 finding: the shape-mismatch fallback
    // must additionally verify the target actually looks like a git admin
    // directory before trusting it.
    @Test("a .git file pointing at an ordinary empty directory is not a repository")
    func gitdirPointsAtEmptyDirectory() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("emptytarget-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        let repo = base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)

        let target = base.appendingPathComponent("just-an-empty-folder")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)

        try "gitdir: \(target.path)"
            .write(toFile: repo.appendingPathComponent(".git").path, atomically: true, encoding: .utf8)

        #expect(WorktreeResolver.kind(of: repo.path) == .notAGitRepository)
    }

    // The shape check for a worktree gitdir (`…/.git/worktrees/<name>`) is
    // purely lexical, on path component names — it does not by itself prove
    // the target directory is a genuine worktree admin directory. Build a
    // directory that *lexically* matches that shape (literal path
    // components `.git`, `worktrees`, `<name>`) but is hollow — no HEAD, no
    // commondir, none of what git actually writes there — and confirm it is
    // rejected rather than trusted on shape alone. `FileManager` resolves
    // symlinks transparently for existence checks, so this also covers the
    // symlink variant of the same attack (a `worktrees` or `<name>`
    // component that is a symlink to a hollow directory rather than a real
    // one): the content check applies identically either way.
    @Test("a directory that merely looks like a worktree admin dir by name is not a worktree")
    func hollowDirectoryShapedLikeAWorktreeIsRejected() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("shapeattack-" + UUID().uuidString)
        let hollowWorktreeDir = base
            .appendingPathComponent("fake-main/.git/worktrees/fake-name")
        try FileManager.default.createDirectory(at: hollowWorktreeDir, withIntermediateDirectories: true)
        // Deliberately nothing inside hollowWorktreeDir: no HEAD, no commondir.

        let victim = base.appendingPathComponent("victim")
        try FileManager.default.createDirectory(at: victim, withIntermediateDirectories: true)
        try "gitdir: \(hollowWorktreeDir.path)"
            .write(toFile: victim.appendingPathComponent(".git").path, atomically: true, encoding: .utf8)

        #expect(WorktreeResolver.kind(of: victim.path) == .notAGitRepository)
    }
}

private func git(_ args: [String], in dir: URL) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = args
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}
