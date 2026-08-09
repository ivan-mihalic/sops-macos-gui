# M2 — Core Editing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user add a project, see its encrypted files, read their decrypted contents in a form, edit them, and save — producing files the standard `sops` CLI reads identically.

**Architecture:** Projects are persisted as a small JSON store in Application Support and exposed through the `ProjectSourceProviding` protocol M1 already defined, which lights up the project half of the health check as a side effect. File discovery is extracted out of `ProjectHealthCheck` into a shared scanner both the health check and the file list use. The age key lives in memory for the session only, behind a protocol shaped so M3's Keychain drops in without touching callers. **Document editing happens inside Go, using sops's own stores** — Swift never re-emits YAML, exactly as ADR 0002 established for `.sops.yaml`.

**Tech Stack:** Swift 6, SwiftUI, swift-testing, SwiftPM, XcodeGen, Go 1.26 (cgo `c-archive`), upstream `getsops/sops` v3.13.3.

## Global Constraints

- **arm64-only.** One slice, everywhere.
- **Deployment target is macOS 26.0**, declared in `Engine/build-xcframework.sh` (`MACOSX_DEPLOYMENT_TARGET`), `Packages/SopsGUIKit/Package.swift` (`platforms:`, string form `.macOS("26.0")` — the `.v26` enum case is unavailable at `swift-tools-version: 6.0`), `project.yml` (`deploymentTarget:` and `LSMinimumSystemVersion`). A mismatch produces a linker warning on every object file.
- **YAML only for v1.** Do not add dotenv or JSON handling anywhere, including "just in case" enum cases.
- **Key material never goes through the environment.** The bridge requires a caller-supplied identity and validates its `AGE-SECRET-KEY-1` prefix; it never falls back to `SOPS_AGE_KEY*` or `~/.config/sops/age/keys.txt`. (ADR 0001, and the C1 finding that proved the fallback executed `$SOPS_AGE_KEY_CMD`.)
- **We never reimplement a sops format** — neither the file format nor the configuration format. Where sops's own code can do the job, call it through the bridge. (ADR 0002.)
- **The app never mutates the system.** It writes only inside the user's chosen project directories and its own Application Support container.
- **No secret value in any log, error, crash report, or health finding.** Naming a file or a key name is fine; a value is not. This now extends to the editor: an error about a failed save may name the file, never its contents.
- **Nothing blocks.** A failed check or an unreadable file never prevents using the rest of the app.
- **Every user-facing string in `SopsUI` goes through `LocalizedKey`** with a matching `Localizable.xcstrings` entry. A SwiftUI view never takes a string literal. Findings produced by `SopsHealth` carry their own English text.
- Build artifacts are never committed.

## What M1 Learned That This Plan Is Built Around

Read these before starting. Every one cost multiple review rounds.

1. **A check that cannot prove something must say so.** M1's worst defects were all the app claiming more than it had established — "every file's key list matches" over zero files checked, a green all-clear over a live `sk_live_…`, an all-clear before the scan finished. The editor inherits this: a file it could not fully parse must not render as an empty-but-editable form.
2. **A test that cannot fail is worse than no test.** M1 shipped a tautological version test, a lexical copy guard defeated by ten paraphrases, and a PATH test satisfied by its own fallback constant. For every test in this plan, name the production change that breaks it — and for the critical ones, break it and watch it go red.
3. **Fixtures your own code accepts prove nothing.** Two M1 defects survived five review rounds because the fixtures were hand-written to match what the implementer believed sops emitted. Build fixtures with the real `sops` and `age` binaries, which are installed.
4. **`ProjectHealthCheck` is 853 lines and produced the most Criticals on the branch.** That is not a coincidence. Task 2 splits it before anything new is built on it.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Engine/gobridge/document.go` | Decrypt to an ordered row list, and apply edits + re-encrypt, using sops's own stores. |
| `Engine/cshim/main.go` | Two new C entry points for the above. |
| `Packages/SopsGUIKit/Sources/SopsEngine/SopsDocument.swift` | Swift side of the document API. |
| `Sources/SopsHealth/ProjectScanner.swift` | File discovery, extracted from `ProjectHealthCheck`. Bounded, with disclosure. |
| `Sources/SopsHealth/EncryptedFileMetadata.swift` | Extracted from `ProjectHealthCheck`. |
| `Sources/SopsProjects/ProjectStore.swift` | Persisted project list; conforms to `ProjectSourceProviding`. |
| `Sources/SopsProjects/WorktreeResolver.swift` | `.git` file/dir detection and worktree grouping. |
| `Sources/SopsProjects/SessionKeyStore.swift` | In-memory age key; conforms to `KeyStoreStatusProviding`. |
| `Sources/SopsUI/Projects/ProjectSidebar.swift` | Project and worktree list, add/remove. |
| `Sources/SopsUI/Projects/FileListView.swift` | Encrypted files in the selected project. |
| `Sources/SopsUI/Editor/SecretDocumentViewModel.swift` | Load, edit, save; unsaved-changes state. |
| `Sources/SopsUI/Editor/SecretEditorView.swift` | Form rows, masking, reveal, copy. |
| `Sources/SopsUI/Editor/KeyImportView.swift` | Paste or import the session key. |

A new `SopsProjects` target keeps the project model out of both `SopsHealth` (which only consumes it through a protocol) and `SopsUI`.

---

### Task 1: Bound the project scan

The blocker named in PROPOSAL §6 D. Today `scanTree` walks everything except `.git`; on a real repository that is 272,802 files and **170 seconds**, because `node_modules/.bun` and `.worktrees` dominate. Nobody sees it yet only because `NoProjects()` is injected — Task 5 changes that.

**Files:**
- Modify: `Packages/SopsGUIKit/Sources/SopsHealth/Checks/ProjectHealthCheck.swift` (`scanTree`, around line 656)
- Test: `Packages/SopsGUIKit/Tests/SopsHealthTests/ProjectScanBoundsTests.swift`

**Interfaces:**
- Consumes: `ProjectHealthCheck.ScannedTree`.
- Produces: `ScannedTree` gains `wasTruncated: Bool` and `skippedDirectoryNames: [String]`.

- [x] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import SopsHealth

@Suite("project scan bounds")
struct ProjectScanBoundsTests {

    /// Builds a tree with `count` files inside `dirName`, plus one real file at the root.
    private func makeTree(dirName: String, count: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-" + UUID().uuidString)
        let noise = root.appendingPathComponent(dirName)
        try FileManager.default.createDirectory(at: noise, withIntermediateDirectories: true)
        for i in 0..<count {
            try "x".write(to: noise.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8)
        }
        try "API_KEY=live".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
        return root
    }

    @Test("dependency directories are not walked", arguments: [
        "node_modules", ".build", ".worktrees", "target", "vendor", "Pods", ".venv", "dist",
    ])
    func skipsDependencyDirectories(dirName: String) throws {
        let root = try makeTree(dirName: dirName, count: 200)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = ProjectHealthCheck.scanTree(under: root)

        #expect(scanned.plaintextCandidates.contains { $0.hasSuffix(".env") },
                "the root .env must still be found")
        #expect(!scanned.wasTruncated, "200 files is nowhere near the budget")
        #expect(scanned.skippedDirectoryNames.contains(dirName))
    }

    // A budget that is silently hit is the same defect class as a check that
    // reports OK about something it never looked at.
    @Test("hitting the file budget is reported, not swallowed")
    func truncationIsDisclosed() throws {
        let root = try makeTree(dirName: "src", count: ProjectHealthCheck.maxScannedFiles + 50)
        defer { try? FileManager.default.removeItem(at: root) }

        let scanned = ProjectHealthCheck.scanTree(under: root)

        #expect(scanned.wasTruncated)
    }

    @Test("a truncated scan never lets the recipients finding report OK")
    func truncationBlocksOK() async throws {
        let root = try makeTree(dirName: "src", count: ProjectHealthCheck.maxScannedFiles + 50)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        creation_rules:
          - age: age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let check = ProjectHealthCheck(source: FixedProjects(projects: [
            InspectedProject(name: "big", rootPath: root.path)
        ]))
        let findings = await check.run()
        let recipients = findings.first { $0.id.hasSuffix("stale-recipients") }!

        #expect(recipients.status != .ok, "a partial scan cannot vouch for the whole project")
    }
}

private struct FixedProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectScanBounds
```

Expected: FAIL — `value of type 'ScannedTree' has no member 'wasTruncated'`.

- [x] **Step 3: Implement the bounds**

In `ProjectHealthCheck`, add above `scanTree`:

```swift
    /// Directories that hold dependencies or build output rather than the user's
    /// own files. Walking them is what turned a project scan into 170 seconds on
    /// a real repository — 272,802 files where 13,899 were the user's.
    static let skippedDirectoryNames: Set<String> = [
        ".git", ".hg", ".svn",
        "node_modules", ".build", ".swiftpm", ".worktrees",
        "target", "vendor", "Pods", "Carthage", "DerivedData",
        ".venv", "venv", "__pycache__", ".tox",
        "dist", "build", ".next", ".nuxt", ".gradle", ".terraform",
    ]

    /// A ceiling so an unknown huge directory cannot stall the UI. When it is
    /// hit the scan says so — see `ScannedTree.wasTruncated`. A budget that is
    /// silently exceeded would let the app report on a project it only partly read.
    static let maxScannedFiles = 20_000
```

Extend `ScannedTree` with `var wasTruncated: Bool` and `var skippedDirectoryNames: [String]`, both populated during the walk. In the enumerator loop, call `enumerator.skipDescendants()` when a directory's `lastPathComponent` is in `skippedDirectoryNames`, recording the name; stop and set `wasTruncated` once the file count reaches `maxScannedFiles`.

- [x] **Step 4: Make a truncated scan unable to report OK**

In `recipientFinding`, the `.ok` branch already guards on `verifiedFileCount > 0`. Add the truncation condition so a partial scan produces `.unknown` naming what was skipped, in the same shape as the existing non-age-backend hedge. Reuse that wording style — the user needs to know the app looked at part of the tree, and which part.

- [x] **Step 5: Run the tests and watch them pass**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectScanBounds
```

Expected: PASS, 10 tests (8 from the parameterised case plus 2).

- [x] **Step 6: Measure it on a real repository**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectHealthCheck 2>&1 | tail -3
```

Then write a throwaway timing test pointing `scanTree` at a large real checkout — this repository itself has `.worktrees` and `Packages/SopsGUIKit/.build`. Paste before/after wall-clock into your report. The prior measurement was 170s; anything above a second on a normal repo means the exclusion list is not doing its job. Delete the throwaway test afterwards.

- [x] **Step 7: Commit**

```bash
git add -A && git commit -m "M2: bound the project scan and disclose when it is truncated"
```

---

### Task 1b: Make the bounded scan affordable

Added after Task 1 measured the result. Task 1 brought a 272,802-file repository from 170s to
**8.6s** — but a reviewer instrumented where that time goes, and the answer changes what to do
about it: the directory walk is only ~1.0–1.3s. The remaining **85–88%** is the per-file tail
read across the 20,000-file budget.

**The obvious fix is closed.** Reading fewer files by filtering on extension — only tail-reading
`.yaml`, `.json`, `.env` — reopens exactly the blind spot that removing the hidden-file exclusion
was meant to close, keyed on extension instead of a leading dot. PROPOSAL §3 requires discovery
"by sops metadata sniffing" precisely so an encrypted file is found regardless of what it is
called. So coverage does not shrink; throughput has to improve.

Task 5 puts this behind a project picker, and §6 requires the report to be re-runnable on
demand, so the cost is paid again on every re-run and multiplies across projects.

**Files:**
- Modify: `Sources/SopsHealth/ProjectScanner.swift` (after Task 2 extracts it)
- Test: `Tests/SopsHealthTests/ProjectScanPerformanceTests.swift`

**Interfaces:** unchanged. `ProjectScanner.scan(root:)` keeps its signature and its results; only
how it reads changes. If it must become `async` to parallelise, update both call sites and say so.

- [x] **Step 1: Pin the current behaviour before changing it**

Write a test that scans a fixture tree containing an encrypted file, a plaintext candidate, a
file inside an excluded directory, and enough files to truncate — and asserts the exact
`ScannedTree` contents. This is the safety net: a throughput change that alters *what* is found
is a correctness regression, and this test is what catches it. Run it and see it pass against
the current implementation.

- [x] **Step 2: Measure, with a number in the report**

Time `scan(root:)` against a large real checkout. Record files visited and wall clock. Report it.

- [x] **Step 3: Parallelise the tail reads**

They are I/O-bound and mutually independent. Use a `TaskGroup` with a bounded width — unbounded
concurrency over 20,000 files will exhaust file descriptors, so pick a width, justify it, and
prove the bound holds. Keep the result deterministic: the returned arrays must not depend on
completion order, or every downstream test becomes flaky.

- [x] **Step 4: Re-run Step 1's test and the full suite**

Same results, faster. If anything found differs, stop — you changed behaviour, not throughput.

- [x] **Step 5: Measure again and decide whether to continue**

If parallelisation alone lands the large-repo scan comfortably under about two seconds, stop
there and say so. Only if it does not, take the next lever: replace `FileHandle`
(open + seekToEnd + seek + read + close, ObjC-bridged, five syscalls a file) with a `pread`-based
read. Measure again.

An mtime-keyed cache so a re-run does not re-pay the full cost is a third lever. **Do not build
it unless the first two leave the number unacceptable** — it adds invalidation state, and a stale
cache entry would make the app report on a file as it used to be, which is this project's
defining failure mode wearing a different hat.

- [x] **Step 6: Report the final numbers and commit**

State plainly what the large-repo scan now costs and whether you consider it acceptable behind a
project picker. If it is still not, say what you would do next rather than declaring victory.

---

### Task 2: Extract the scanner out of ProjectHealthCheck

853 lines, four concerns, and the most reproduced Criticals of any file on the M1 branch. M2's file list needs the same discovery logic; duplicating it would be the worst available outcome.

**Files:**
- Create: `Sources/SopsHealth/ProjectScanner.swift`
- Create: `Sources/SopsHealth/EncryptedFileMetadata.swift`
- Modify: `Sources/SopsHealth/Checks/ProjectHealthCheck.swift`
- Modify/Create: the corresponding test files

**Interfaces:**
- Produces: `public struct ProjectScanner` with `public static func scan(root: URL) -> ScannedTree`, and `public struct ScannedTree { public let encryptedFiles: [URL]; public let plaintextCandidates: [URL]; public let wasTruncated: Bool; public let skippedDirectoryNames: [String] }`. `EncryptedFileMetadata` moves verbatim with its existing API.

- [x] **Step 1: Move, do not rewrite**

`git mv` is not available for a partial file, so move the code by cut-and-paste and verify with `git diff` that the moved bodies are unchanged. Make `ProjectScanner` and `ScannedTree` `public` — `SopsUI` needs them for the file list. Everything else stays internal.

- [x] **Step 2: Point `ProjectHealthCheck` at the new type**

It should now call `ProjectScanner.scan(root:)` and own none of the walking code.

- [x] **Step 3: Run the whole suite**

```bash
cd Packages/SopsGUIKit && swift test
```

Expected: the same count as before this task, all passing. **A behavioural change here is a bug, not an improvement** — if a test fails, you changed something while moving it.

- [x] **Step 4: Confirm the split actually happened**

```bash
wc -l Packages/SopsGUIKit/Sources/SopsHealth/Checks/ProjectHealthCheck.swift
```

Expected: substantially under 853. Report the number.

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "M2: extract ProjectScanner and EncryptedFileMetadata from ProjectHealthCheck"
```

---

### Task 3: The project store

**Files:**
- Modify: `Packages/SopsGUIKit/Package.swift` (new `SopsProjects` target)
- Create: `Sources/SopsProjects/ProjectStore.swift`
- Create: `Tests/SopsProjectsTests/ProjectStoreTests.swift`

**Interfaces:**
- Produces: `public struct StoredProject: Codable, Identifiable, Equatable, Sendable { public let id: UUID; public var displayName: String; public var rootPath: String; public var addedAt: Date }`; `@MainActor @Observable public final class ProjectStore` with `init(fileURL: URL)`, `projects: [StoredProject]`, `func add(path: String) throws -> StoredProject`, `func remove(id: UUID)`, and a nested `ProjectStore.HealthSource: ProjectSourceProviding` adapter.
- `ProjectStore.Error` cases: `.notADirectory`, `.alreadyAdded(existing: StoredProject)`, `.unreadable`.

- [x] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import SopsProjects

@Suite("ProjectStore")
@MainActor
struct ProjectStoreTests {

    private func makeStore() -> (ProjectStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString).json")
        return (ProjectStore(fileURL: url), url)
    }

    private func makeDirectory() throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("adding a directory persists it across instances")
    func addPersists() throws {
        let (store, url) = makeStore()
        let path = try makeDirectory()

        _ = try store.add(path: path)

        let reloaded = ProjectStore(fileURL: url)
        #expect(reloaded.projects.map(\.rootPath) == [path])
    }

    @Test("adding the same path twice reports the existing entry instead of duplicating")
    func rejectsDuplicates() throws {
        let (store, _) = makeStore()
        let path = try makeDirectory()
        let first = try store.add(path: path)

        #expect(throws: ProjectStore.Error.self) { try store.add(path: path) }
        #expect(store.projects.count == 1)
        #expect(store.projects.first?.id == first.id)
    }

    @Test("a file, not a directory, is refused")
    func rejectsFiles() throws {
        let (store, _) = makeStore()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("f-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)

        #expect(throws: ProjectStore.Error.self) { try store.add(path: file.path) }
    }

    // A project directory the user deleted or unmounted must not crash the app
    // or vanish silently — the user needs to be told which one is gone.
    @Test("a project whose directory disappeared is kept and marked, not dropped")
    func survivesMissingDirectory() throws {
        let (store, url) = makeStore()
        let path = try makeDirectory()
        _ = try store.add(path: path)
        try FileManager.default.removeItem(atPath: path)

        let reloaded = ProjectStore(fileURL: url)
        #expect(reloaded.projects.count == 1)
        #expect(reloaded.isMissing(reloaded.projects[0]))
    }

    @Test("a corrupt store file yields an empty list rather than throwing at launch")
    func toleratesCorruptFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("projects-\(UUID().uuidString).json")
        try "not json at all".write(to: url, atomically: true, encoding: .utf8)

        #expect(ProjectStore(fileURL: url).projects.isEmpty)
    }

    @Test("removing leaves the rest intact and persists")
    func removePersists() throws {
        let (store, url) = makeStore()
        let a = try store.add(path: try makeDirectory())
        _ = try store.add(path: try makeDirectory())

        store.remove(id: a.id)

        #expect(ProjectStore(fileURL: url).projects.count == 1)
    }

    @Test("the health-source adapter exposes exactly the stored projects")
    func healthSourceMatches() throws {
        let (store, _) = makeStore()
        let p = try store.add(path: try makeDirectory())

        let source = store.healthSource
        #expect(source.projects.map(\.rootPath) == [p.rootPath])
    }
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectStore
```

Expected: FAIL — `no such module 'SopsProjects'`.

- [x] **Step 3: Add the target**

In `Package.swift`, add the library product and:

```swift
        .target(name: "SopsProjects", dependencies: ["SopsHealth"]),
        .testTarget(name: "SopsProjectsTests", dependencies: ["SopsProjects"]),
```

- [x] **Step 4: Implement**

Persist as JSON. Writes go through a temp file plus `replaceItemAt` so a crash mid-write cannot leave a truncated store. `isMissing(_:)` stats the path rather than caching, so an unmounted volume reappearing fixes itself. The default location is `~/Library/Application Support/cz.mihalic.SopsGUI/projects.json`, but the initialiser takes the URL so tests never touch it.

- [x] **Step 5: Run the tests and watch them pass**

```bash
cd Packages/SopsGUIKit && swift test --filter ProjectStore
```

Expected: PASS, 7 tests.

- [x] **Step 6: Commit**

```bash
git add -A && git commit -m "M2: persisted project store"
```

---

### Task 4: Worktree detection and grouping

PROPOSAL §3: a worktree's `.git` is a **file** containing a `gitdir:` pointer, not a directory. Worktrees group under their main repository, and editing is allowed in any of them.

**Files:**
- Create: `Sources/SopsProjects/WorktreeResolver.swift`
- Create: `Tests/SopsProjectsTests/WorktreeResolverTests.swift`

**Interfaces:**
- Produces: `public enum RepositoryKind: Equatable, Sendable { case mainRepository(root: String); case worktree(root: String, mainRepository: String); case notAGitRepository }` and `public enum WorktreeResolver { public static func kind(of path: String) -> RepositoryKind }`.

- [x] **Step 1: Write the failing test, using real git**

Build the fixtures with the real `git` binary — a hand-written `.git` file is exactly the kind of fixture that proves nothing.

```swift
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
```

- [x] **Step 2: Run it and watch it fail**

```bash
cd Packages/SopsGUIKit && swift test --filter WorktreeResolver
```

Expected: FAIL — `cannot find 'WorktreeResolver' in scope`.

- [x] **Step 3: Implement**

Read `<path>/.git`. If it is a directory, this is a main repository. If it is a file, parse the `gitdir: ` prefix, resolve the pointed-at path, and walk up from `…/.git/worktrees/<name>` to the main repository root. Verify the resolved directory actually exists before reporting `.worktree` — a dangling pointer is `.notAGitRepository`, not a worktree of nowhere. Do not shell out to `git`; the file format is stable and documented, and reading it is cheaper than a process spawn per project.

- [x] **Step 4: Run the tests and watch them pass**

```bash
cd Packages/SopsGUIKit && swift test --filter WorktreeResolver
```

Expected: PASS, 4 tests.

- [x] **Step 5: Commit**

```bash
git add -A && git commit -m "M2: worktree detection via the .git pointer file"
```

---

### Task 5: Project sidebar, and the health check finally sees projects

**Files:**
- Create: `Sources/SopsUI/Projects/ProjectSidebar.swift`
- Modify: `Sources/SopsUI/AppShell.swift`
- Modify: `App/SopsGUIApp.swift`
- Modify: `Sources/SopsUI/LocalizedKey.swift` and `Resources/Localizable.xcstrings`
- Create: `Tests/SopsUITests/ProjectSidebarModelTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class ProjectSidebarModel` with `groups: [ProjectGroup]`, `selection: StoredProject.ID?`, `func addProject(path: String)`, `func remove(_:)`, `var lastError: String?`; and `public struct ProjectGroup: Identifiable { let mainRepositoryPath: String; let members: [StoredProject] }`.

- [x] **Step 1: Write the failing test**

Cover grouping and error surfacing at model level — the view is not unit-testable here.

```swift
@Test("worktrees are grouped under their main repository")
@Test("a project that is not a git repository forms its own group")
@Test("adding a duplicate surfaces an error instead of throwing into the view")
@Test("removing the selected project clears the selection")
```

Write these out fully in the style of Task 3's suite, using real git fixtures as in Task 4.

- [x] **Step 2: Run and watch fail, then implement**

The sidebar lists groups with worktree members indented under their main repository. Add via `NSOpenPanel` (directories only) and drag-and-drop of folder URLs. Removal asks for confirmation and never touches the directory on disk — removal means "stop tracking this", and the copy must say so.

- [x] **Step 3: Wire the store into the health report**

In `App/SopsGUIApp.swift`, pass `projectStore.healthSource` to `HealthReport.standard(projects:)`. The `project.none` finding will stop appearing and real per-project findings will take its place — that is the whole point of M1's protocol seam.

- [x] **Step 4: Verify the health check lights up**

Add a project, open Settings › Health, and confirm the projects section now reports on it. Capture a screenshot and read it. If a project with no `.sops.yaml` produces something confusing, fix the copy — this is the first time these findings are seen with a real project behind them.

- [x] **Step 5: Confirm the scan is fast with a real project**

Add this repository itself as a project and time the health refresh. Task 1's bounds should keep it under a second. If it does not, stop and report — Task 1 did not do its job.

- [x] **Step 6: Commit**

---

### Task 6: The session key store

Per the decision recorded for this milestone: the key lives in memory for the session only. M3 replaces the storage without touching callers.

**Files:**
- Create: `Sources/SopsProjects/SessionKeyStore.swift`
- Create: `Sources/SopsUI/Editor/KeyImportView.swift`
- Create: `Tests/SopsProjectsTests/SessionKeyStoreTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class SessionKeyStore` with `var state: KeyStoreState { get }`, `func importKey(_ text: String) throws`, `func forget()`, and `func withKey<R>(_ body: (String) throws -> R) rethrows -> R?`. Conforms to `KeyStoreStatusProviding`.
- `SessionKeyStore.Error`: `.notAnAgeKey`, `.empty`.

- [x] **Step 1: Write the failing test**

The properties that matter:

```swift
@Test("a valid AGE-SECRET-KEY-1 key is accepted and reports configured")
@Test("anything without the AGE-SECRET-KEY-1 prefix is refused")   // incl. AGE-PLUGIN-…
@Test("an empty or whitespace-only string is refused")
@Test("forget() returns the store to empty")
@Test("the key is never written to disk")   // scan the app support dir after import
@Test("no error message contains any part of the supplied key")
```

That last one matters: M1's rule is that no secret value reaches a log or an error, and a key-import error is the most tempting place to echo the input. Assert it with a distinctive key body.

- [x] **Step 2: Implement**

Validate the prefix — the bridge does too, but failing here gives a better message and keeps a bad key from ever reaching Go. Hold the key in a single `private var`. `withKey` exists so callers borrow it for the duration of a call rather than copying it around; document that Swift `String` cannot be reliably zeroed and that M3's Keychain path is what actually fixes that.

- [x] **Step 3: Wire it into the health report**

Pass the store as `keyStore:` to `HealthReport.standard`. `security.keystore` stops being `.skipped` and starts reporting `.configured` or `.empty` for real.

- [x] **Step 4: Build the import view**

Paste field, plus an "Import from `~/.config/sops/age/keys.txt`" button that is **explicit user action, not automatic**. After a successful import from that file, point the user at the existing `security.legacy-key-file` finding — the app has been telling them that file is a risk, and now it can offer the next step.

- [x] **Step 5: Commit**

---

### Task 7: The document API in Go

**The most important design decision in M2.** Swift must never parse and re-emit the user's YAML: doing so would silently drop comments, reorder keys, and change scalar quoting. sops's own stores round-trip what sops preserves, and ADR 0002 already established the rule — where we link the authoritative implementation, we use it.

So the document lives in Go: decrypt to an ordered row list, apply edits, re-encrypt. Swift holds values only to display them.

**Files:**
- Create: `Engine/gobridge/document.go`
- Create: `Engine/gobridge/document_test.go`
- Modify: `Engine/cshim/main.go`
- Create: `Packages/SopsGUIKit/Sources/SopsEngine/SopsDocument.swift`
- Create: `Packages/SopsGUIKit/Tests/SopsEngineTests/SopsDocumentTests.swift`

**Interfaces:**
- Go: `DecryptToRows(encrypted []byte, ageKey string) ([]Row, error)` where `Row{Path []string; Value string; Kind string}`, and `ApplyEditsAndEncrypt(encrypted []byte, edits []Edit, ageKey string) ([]byte, error)`.
- Swift: `public struct SecretRow: Identifiable, Equatable, Sendable { public let path: [String]; public var value: String; public let kind: SecretRow.Kind }`, `SopsBridge.decryptToRows(_:agePrivateKey:) throws -> [SecretRow]`, `SopsBridge.applyEdits(_:edits:agePrivateKey:) throws -> String`.

**The rule that governs re-encryption:** when saving an existing file, preserve **that file's own metadata** — its recipients, `encrypted_regex`, MAC settings, `shamir_threshold`. Do **not** re-derive them from `.sops.yaml`. A file whose rules have drifted from the config must not be silently rewritten to match the config; that is a different operation (`updatekeys`, which is M4) and doing it invisibly during a save would change who can read the file without telling anyone.

- [x] **Step 1: Write the failing Go test, with fixtures from the real binary**

```go
// Round-tripping a file through decrypt→edit→encrypt must leave everything
// the user did not touch byte-identical after the CLI decrypts it — comments,
// key order, and scalar style included. A YAML re-emitter that "cleans up" the
// file is silently rewriting the user's document.
func TestEditPreservesCommentsAndOrder(t *testing.T) { /* … */ }

func TestEditedFileDecryptsWithTheSopsCLI(t *testing.T) { /* … */ }

func TestSavePreservesTheFilesOwnRecipientsNotTheConfigs(t *testing.T) { /* … */ }

func TestDecryptToRowsRejectsAnEmptyKey(t *testing.T) { /* … */ }
```

Build every fixture by running the real `sops` and `age` binaries, as the existing `gobridge` tests already do — reuse their helpers.

- [x] **Step 2: Run and watch fail, then implement**

Use `common.LoadEncryptedFileWithBugFixes` / `common.DecryptTree` to get the tree, walk `sops.TreeBranches` to produce rows, apply edits to the tree in place, then `common.EncryptTree` and `store.EmitEncryptedFile` — the same path `Encrypt` already uses. The metadata comes from the loaded tree, which is what makes the preservation rule fall out naturally rather than needing to be enforced.

- [x] **Step 3: Cross the C boundary**

Two entry points following the existing convention exactly: 0 on success, out-parameter carries the result or the error, freed with `sops_free`. JSON for the row list. Rebuild the xcframework.

- [x] **Step 4: Swift side and its tests**

The Swift tests must include a full round trip through the real CLI: edit via the bridge, then `sops --decrypt` the result and compare.

- [x] **Step 5: Commit**

---

### Task 8: The document view model

**Files:**
- Create: `Sources/SopsUI/Editor/SecretDocumentViewModel.swift`
- Create: `Tests/SopsUITests/SecretDocumentViewModelTests.swift`

**Interfaces:**
- Produces: `@MainActor @Observable public final class SecretDocumentViewModel` with `rows: [SecretRow]`, `isDirty: Bool`, `loadState: LoadState`, `func load() async`, `func update(rowID:to:)`, `func addRow(path:)`, `func removeRow(id:)`, `func save() async -> SaveOutcome`.
- `LoadState`: `.idle`, `.loading`, `.loaded`, `.needsKey`, `.failed(String)`.

- [x] **Step 1: Write the failing test**

The properties that matter, each with a named regression:

```swift
@Test("loading without a key reports needsKey rather than an empty editable form")
@Test("a file that fails to decrypt reports failed and renders nothing editable")
@Test("editing a value sets isDirty; setting it back to the original clears it")
@Test("save writes and clears isDirty")
@Test("a failed save leaves isDirty set and the rows untouched")
@Test("no error string contains any row value")
```

The first is the M1 lesson applied to the editor: a document the app could not decrypt must not present as an empty form the user might "save" over their file.

- [x] **Step 2: Implement, run, commit**

---

### Task 9: The editor view

**Files:**
- Create: `Sources/SopsUI/Editor/SecretEditorView.swift`
- Create: `Sources/SopsUI/Projects/FileListView.swift`
- Modify: `AppShell.swift`, `LocalizedKey.swift`, `Localizable.xcstrings`

Per PROPOSAL §4: form rows (key / value / type), value masking with per-field reveal, readonly mode with one-click copy, add/remove rows, unsaved-changes indicator.

- [x] **Step 1: File list**

Encrypted files for the selected project, from `ProjectScanner`. Show the path relative to the project root. If the scan was truncated, say so here too — the file list is where the user would otherwise assume they are seeing everything.

- [x] **Step 2: The editor, with masking on by default**

Values are masked until revealed per field. Reveal is per row and does not persist across file switches. Copy puts the value on the pasteboard and clears it after the interval PROPOSAL §2 specifies — reuse whatever the Settings panel exposes, or add it there.

- [x] **Step 3: Unsaved changes must be impossible to lose silently**

Switching files or quitting with `isDirty` prompts. This is the one place in the app where a mistake destroys the user's data.

- [x] **Step 4: Every string through `LocalizedKey`**

- [x] **Step 5: Commit**

---

### Task 10: Atomic save

**Files:**
- Create: `Sources/SopsProjects/AtomicFileWriter.swift`
- Create: `Tests/SopsProjectsTests/AtomicFileWriterTests.swift`

- [x] **Step 1: Write the failing test**

```swift
@Test("the file is replaced atomically — no partial content is ever observable")
@Test("the original file's POSIX permissions are preserved")
@Test("a symlinked path writes through to the target, not over the link")
@Test("a failed write leaves the original file byte-identical")
@Test("the temp file is created in the same directory so the rename is atomic")
```

The last one matters: a temp file in `/tmp` and a cross-device rename is a copy, not an atomic replace, and can leave a half-written secrets file.

- [x] **Step 2: Implement, run, commit**

Encrypt to a temp file beside the target, `fsync`, then `replaceItemAt`. Preserve permissions explicitly.

---

### Task 11: CLI compatibility of everything the editor writes

The hard requirement from PROPOSAL §2, applied to the new write path. This task exists as its own gate because it is what makes the app safe to use on a real repository.

**Files:**
- Create: `Tests/SopsEngineTests/EditorCompatibilityTests.swift`

- [x] **Step 1: Write the round-trip matrix**

For each of: a plain file; a file with `encrypted_regex`; a file with multiple recipients; a file with comments and nested maps; a file with a list value —

1. encrypt with the real `sops` CLI
2. edit one value through the bridge
3. `sops --decrypt` the result and confirm the edit landed and nothing else changed
4. re-encrypt with the CLI and confirm our bridge still reads it

Every fixture built with the real binaries. Assert the MAC verifies at every step.

- [x] **Step 2: Assert what must not change**

Comments preserved. Key order preserved. Recipients unchanged. `encrypted_regex` unchanged. Values the user did not touch decrypt to exactly what they were.

- [x] **Step 3: Commit**

---

### Task 12: Final verification

- [x] **Step 1: Clean-state build and every suite**

```bash
rm -rf Engine/build Packages/SopsGUIKit/.build SopsGUI.xcodeproj
./Scripts/bootstrap.sh
cd Engine && go vet ./... && go test ./...
cd ../Packages/SopsGUIKit && swift test
cd ../.. && xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Release build
```

Grep for `was built for newer`; expect nothing.

- [x] **Step 2: The GUI pass M1 could not do** — done by snapshot, not by launching the app (CLAUDE.md). Two of the seven items could not be reached at all; both are named in `.superpowers/sdd/2026-08-07-m2-core-editing/task-12-report.md` rather than glossed.

M1 shipped with the UI never visually verified beyond a few static screens, because there was no project to populate it. Now there is. With the screen unlocked and Accessibility granted:

- Add this repository as a project. Confirm the scan is fast and the health check reports on it.
- **Open a secrets file with a long recipients finding and confirm the text does not clip or overflow** — `HealthFindingRow` has no `.lineLimit` inside a fixed 640×520 sheet, and this was M1's top unverified risk.
- Walk the wizard's six steps at speed and confirm no premature all-clear.
- Compare the wizard's category steps against Settings › Health for parity.
- Confirm the Copy button's label resets between rows.
- Edit a value, switch files without saving, and confirm the prompt appears.
- VoiceOver over one row of each status.

Screenshot each and read the images. Report honestly what you could not reach.

- [x] **Step 3: Leak greps**

```bash
grep -rniE 'AGE-SECRET-KEY|print\(.*value|print\(.*secret' Packages/SopsGUIKit/Sources App Engine --include='*.swift' --include='*.go'
git ls-files | grep -iE '\.xcodeproj|\.xcframework|\.a$|keys\.txt'
```

Both must come back empty apart from test fixtures.

- [x] **Step 4: Update the docs** — with one deliberate exception: **M2 is not marked done.** Two things it undertook did not land (`recover()` at the C boundary, and the §6 D exclusion disclosure), so §9 records it as feature-complete-not-closed and names both. See the Task 12 report.

Mark M2 done in PROPOSAL §9. Update the README's current-state paragraph — it currently says the app does not open or edit any encrypted files, which will no longer be true. Add an ADR for the in-Go document editing decision if Task 7 turned up anything worth recording.

- [x] **Step 5: Commit**

---

## Self-Review

**Spec coverage against PROPOSAL §9 M2 and §3/§4:**

| Requirement | Task |
|---|---|
| Tree-walk cost constraint (§6 D, the stated M2 blocker) | 1 |
| Project add by path, NSOpenPanel and drag & drop (§3) | 5 |
| Worktree detection via the `.git` pointer file, grouped (§3) | 4, 5 |
| Encrypted-file discovery by metadata sniffing (§3) | 2, 9 |
| Form editor: key / value / type rows (§4) | 8, 9 |
| Value masking with per-field reveal (§4) | 9 |
| Readonly mode with one-click copy (§4) | 9 |
| Add/remove rows, unsaved-changes indicator (§4) | 8, 9 |
| Atomic save, encrypt to temp then rename (§4) | 10 |
| CLI byte-compatibility (§2, hard requirement) | 7, 11 |
| Key available to decrypt (milestone decision) | 6 |
| String Catalogs from day one (§4) | 5, 6, 9 |

**Deliberate deferrals:**

- Keychain, Touch ID and session TTL remain M3. Task 6's `SessionKeyStore` is shaped so M3 replaces the storage behind the same protocol.
- `.sops.yaml` editing, `updatekeys` and recipient management remain M4. Task 7's preservation rule exists precisely so a save never does M4's job by accident.
- Localizing `SopsHealth`'s finding strings is still open from M1 and out of scope here.
- The durable fix for tool probes phoning home — running them under the deny-network profile — remains M5.

**Known risk this plan does not eliminate:** Task 7 assumes sops's stores round-trip a YAML document losslessly for the fields we do not touch. That is the same assumption the M0 spike validated for whole-file encrypt/decrypt, but not for the edit path. Task 7 Step 1 tests it directly, and if it turns out sops's YAML store normalises something, **that finding changes the design** — say so and stop rather than shipping an editor that quietly reformats the user's file.

---

## Carried forward out of M2 (Task 12, 2026-08-08)

Written here rather than only in the SDD ledger because `.superpowers/` is
gitignored — this file is the milestone's durable record. Full evidence for each
item is in `.superpowers/sdd/2026-08-07-m2-core-editing/task-12-report.md`.

> **Resolved the same day by Tasks 13–16.** Items 1–3 and 6–9 below are **closed**;
> what remains open out of M2 is items 4 and 5, plus the two entries in
> "Still open after the fix wave" at the end of this section. The list is kept
> as written so the milestone's honest state at final verification stays legible
> — Task 12 withheld the ✅ deliberately, and that judgement is the record worth
> keeping, not a tidied-up version of it.

**Blocking M2's ✅ — both inherited by M3:** ~~both closed, Tasks 13 and 14~~

1. **`recover()` at the C boundary.** Vendored sops v3.13.3 panics (`hash of
   unhashable type []uint8`) on any value declaring `type:bytes`, and
   `grep -rn 'recover()' Engine/` comes back empty — a hand-crafted or
   foreign-tool file **crashes the whole process** instead of returning an
   error. Filed during Task 7 as "required before M2 closes, fold into Task 11";
   Task 11 turned out to be a test-only gate and never touched `Engine/`.
2. **The §6 D exclusion is not stated in the finding unless the scan *also*
   exhausts its file budget.** `ProjectHealthCheck.recipientFinding` appends the
   "this walk also skipped …" note inside `if tree.wasTruncated`. Measured on
   this repository: `.build` and `.swiftpm` skipped, budget not hit, and the
   plaintext-leak check reported `.ok` — "Looked through &lt;root&gt; … and found
   none" — naming no exclusion. PROPOSAL §6 D requires the exclusion to be
   "stated in the finding, not buried in a constant", and forbids reporting OK
   about files the check did not look at.
   The performance half of §6 D *is* solved: **170 s → 0.126 s** on this
   repository, measured through the real check.

**Not blocking, but not true yet either:**

3. `ProjectSidebar` has no `scrollOverflowFade()`. `FileListView`,
   `HealthPanel`, `OnboardingWizard` (twice) and `SecretEditorView` all do.
   Same overflow shape, same withholding.
4. `SopsHealth`'s finding strings are still unlocalized (I9, open since M1).
5. The reserved-key list is **empirical** against sops 3.13.2 / go-yaml v3.0.4,
   not derived from a specification. A dependency bump can silently invalidate
   it.
6. `ProjectHealthCheckLargeFileTests.swift:85` and `:126` (`elapsed <
   .seconds(3)`) fail in roughly half of bare `swift test` runs on this machine
   — never under `xcrun swift test`, which runs each target in its own process.
   Measured with and without Task 12's own additions; unaffected by them.
7. **The unsaved-changes-on-file-switch decision is untested.**
   `requestFileSwitch`/`requestProjectSwitch` live in a `private struct
   ProjectWorkspaceView` and the prompt is a `.confirmationDialog`, so neither a
   unit test nor a headless snapshot can reach it. `isDirty` itself is well
   covered; the gate between it and the dialog is verified by reading only.
   Making this testable means lifting the decision out of the view.
8. **The Copy button's label reset between rows is unverified** — `didCopy` is
   `@State private` in `HealthFindingRow` and only changes on a click. Per-row
   isolation follows from unique finding ids, which *are* tested. Separately:
   `didCopy` never returns to "Copy" for a row that has been copied once.
9. Masked-value accessibility exposes a secret's **length** — the mask is one
   bullet per character, and that reaches the accessibility tree.
   `AccessibilityTreeTests` proves no *value* leaks; length is not covered.

**Found in Task 12, recorded rather than fixed:** metadata sniffing classifies
11 of this repository's own files as sops-encrypted — one `.md` report quoting a
`sops:` block becomes an openable row in the file list, and ten sources or diffs
containing `sops_mac=`/`sops_version=` are counted as "a format this app does
not read". That follows from PROPOSAL §3's metadata sniffing plus the deliberate
extension blindness, both of which are right; it is what the app looks like
pointed at a repository *about* sops.

> **Fixed after all (Task 14).** The discriminator turned out cheap: `SopsMetadataShape`
> now requires the *structure* sops actually emits, verified against real-binary
> output in YAML / dotenv / JSON / INI, behind the existing byte prefilter.
> `encrypted(2)`/`otherFormat(9)` → **0 / 0**. The fix's own first draft made its
> doc comment the twelfth false positive; a standing `ownSourceTreeIsNotEncrypted`
> test now scans the package's own `Sources/`.

---

## Still open after the fix wave (Tasks 13–16, 2026-08-08)

Everything below is genuinely carried into M3. Items 4 and 5 above are unchanged
and still open; these are the two additions the fix wave itself surfaced.

10. **`ClipboardClearingTests.laterCopySurvivesEarlierClear` is vacuous under
    load.** Task 16's sabotage exposed it: with the clearing timer removed
    entirely, the test still passed. Establishing non-vacuity needs an
    observable signal that the stale timer ran, which `ClipboardClearing` does
    not expose. Pre-existing, not introduced by the fix wave — recorded so
    nobody rediscovers it as a *passing* test.
11. **The CRLF guard scans `Sources/` only.** Test helpers such as
    `ProjectFixture.ageKeyPair` still split on `"\n"`. Extending
    `sourcesContainNoNewlineBlindIdioms` to `Tests/` needs a sizeable allow-list,
    because fixtures legitimately pin exact LF-only bytes, and no test helper
    reads a file whose line endings the app does not control.

---

## Still open after the second review (Tasks 22, 2026-08-08)

The second whole-branch review's three blocking findings are closed — the outer
sidebar exit, `TestResultRecoversToo`'s substring check, and a ThreadSanitizer-
confirmed race in `ProjectScanner.concurrentMap` — plus the two overclaiming
comments and both AST-rule gaps. What it found and judged legitimate M3 work:

12. **A transiently unreadable `projects.json` is quarantined and the app then
    cannot say so.** `ProjectStore.load(from:)` cannot tell "corrupt" from
    "temporarily unreadable" — mode 000, an ACL, an unmounted volume, a file
    held open by a sync client all take the quarantine branch and **move the
    user's real project list**. The damage is permanent; the disclosure is not:
    the second launch shows zero projects with `loadError == nil`, and the
    sidebar renders "no projects" as a fact.
13. **`ProjectStore.persist` bypasses `AtomicFileWriter` and re-creates the
    defect that type documents.** It calls `replaceItemAt` directly, without
    `resolvingSymlinksInPath()`, so a symlinked
    `~/Library/Application Support/cz.mihalic.SopsGUI` (a dotfiles repo, another
    volume) makes **every add and remove fail permanently**, reported through an
    internal `Error.unreadable` whose name means the opposite. It also writes
    `projects.json` at the umask default — mode 644, so every local account can
    read the absolute path of every project. No secret values, but
    `AtomicFileWriter:152` guards exactly this for its own files.
14. **A clipboard manager that *normalises* the copied entry still gets a
    permanent stay.** It moves `changeCount` *and* breaks the digest, so neither
    branch fires, and `pending` is already `nil` by then so `clearOnTermination`
    cannot catch it either. Narrower than the pre-fix behaviour, which refused
    to clear on *any* change of count — but Task 21's commit message reads as
    though the hole is closed, and it is only smaller. Related: `clearContents()`
    destroys the whole pasteboard item, so a later copy of the same string from
    another app loses its other flavours too.
15. **No timeout on the deferred quit, and ⌘Q during a save is entirely
    silent.** `.waitForSaveInFlight` → `.terminateCancel` with no dialog and no
    retry: ⌘Q simply does nothing, and a logout or shutdown is cancelled without
    explanation. `isSaving` clears only in `save()`'s `defer`, which blocks on a
    raw `Thread` into Go, so a wedged engine makes the app unquittable except by
    Force Quit — which skips `applicationWillTerminate`, so the copied secret
    stays on the pasteboard.
16. **`rowIdentityGeneration` is invalidated on every save**, including
    value-only saves where no path can have moved, so revealing a row, editing
    an unrelated key and saving silently re-masks it. Fails safe (it hides more,
    never less) — a usability regression, not a safety one.
17. **The CLI round-trip gate vanishes silently off this machine.**
    `EditorCompatibilityTests` hardcodes `/opt/homebrew/bin/sops` and
    `age-keygen` behind `.enabled(if:)`. It really runs here. On CI, an Intel Mac
    with `/usr/local`, or nix, the whole compatibility gate disappears and the
    suite still reports green. The app itself uses `ToolLocator`.

Also unverified rather than untrue: the `.confirmationDialog`'s three buttons
render nowhere a test or a headless snapshot can reach — the *decision* behind
them is now a pure function with 13 tests, but the buttons themselves are
verified by reading only. And `ScrollOverflowFadeCoverageTests` asserts that the
modifier is *called*, not that anything is drawn; the drawing was confirmed once,
by eye, from the PNGs.

---

## Third review (2026-08-09) — what it found and what remains

The third whole-branch review ran against the merge commit `dcd11c5` and again
returned **do not merge / no tick**. Its five blockers are closed on this
branch; two of them were new instances of failures the previous two rounds had
each declared finished.

**Closed:**

- **Arbitrary code execution from a scanned repository.** `core.fsmonitor` is a
  repository-local git config key whose value git executes, and
  `GitIgnoreOracle` shells out to git on every project scan. Clone a repo, add
  it as a project, and its script ran as the user the moment the scan reached a
  file named `.env`. Verified before and after with a real hook. Every git
  invocation now carries `-c core.fsmonitor=`, with a control test that runs the
  *unmitigated* call and asserts the hook does fire — otherwise the guard test
  would pass forever if git changed or the fixture rotted.
- **A new `//export` in a second file was invisible to the guard test**, which
  parsed `main.go` alone. An unguarded entry point really did reach
  `libprobe.h`. It now parses every non-test file in the directory.
- **`TestResultRecoversToo` had rules but no fixtures.** The shape nobody
  thought to try — `recover()` inside a nested goroutine, which returns nil and
  lets the panic kill the host — reported `ok`. Two more rules and seven
  fixtures.
- **⌘W and ⌘N were the fourth and fifth unguarded exits from a dirty
  document.** Closing the window destroyed the document *and* cleared the
  tracker, so the next ⌘Q answered `.terminateNow`; and two windows shared one
  `UnsavedChangesTracker`, so a second window opening a clean file disarmed the
  first window's warning. `windowShouldClose` now asks `QuitRequest`, and
  `.newItem` is removed so the single-document model the tracker documents is
  actually true.
- **Disconnecting the outer-sidebar guard reddens tests now.** It did not: the
  review reverted both `guardedSelection` uses to `$selection` and all 577 tests
  stayed green.

**Still open, carried to M3** — in addition to items 12–17 above:

18. **`!!binary` values are displayed wrong and can be destroyed by editing.**
    `DecryptToRows` returns the bytes correctly; the JSON transport to Swift
    replaces them with `�`, so the editor shows `��` for a value whose real
    content is binary. Echoing that row back writes the replacement characters
    to the file — a silent, permanent loss. `document.go:610` claims "the YAML
    store never produces it", which `Encrypt` disproves. The sops CLI
    round-trips these correctly, so this is ours. It is a core-honesty defect:
    the editor states something false about the file's contents.
19. **Rule 6 (`reboundAfterGuard`) only walks top-level statements.** `err = nil`
    nested in an `if`, a bare block, a `switch` or a `for` is invisible. Helper
    and named-return variants *are* caught.
20. **`ExternalToolCheck` keeps `.ok` when `softFloor == nil`**, disclosing only
    in prose, while its sibling `EngineFreshnessCheck` returns `.problem` on the
    same condition.
21. **`WorktreeResolver` uses `standardizedFileURL`, not `CanonicalPath`.**
    Measured: it rewrites `/private/tmp` to `/tmp`, and the two standardized
    URLs are not `==` despite reporting the same path — so worktree grouping can
    fail on a path that reaches the app through `/private`.

**Verified clean by the third review**, and worth keeping in view because they
are the properties most likely to be broken by future work: no secret value in
any of ten channels (including zero `fatalError`/`assert`/`precondition` in
`Sources/`, so the crash-report channel does not exist); the scanner never
quotes a secret it found; the accessibility mask is real and its tests are
non-vacuous; the pasteboard markers and SHA-256-gated clear; `AtomicFileWriter`'s
ordering; the ThreadSanitizer-clean scanner; the CLI round-trip actually running
rather than skipping; and ADR 0001 holding throughout.

---

## Iteration 4 (2026-08-09) — still open, carried to M3

Eight of the iteration's fourteen findings were fixed in `fa8dd85`; three of
those eight were defects in iteration 3's own fixes, including a window-close
guard that never ran. What remains:

22. **`HealthReport.standard()` runs two synchronous login-shell probes on the
    main actor** — `ToolLocator` shells out to `$SHELL -lc` twice per refresh,
    ~95 ms each, measured on the main thread. Not a hang, but it is UI-blocking
    work on every health run.
23. **Remove Project persists the deletion before the unsaved-changes guard
    asks.** `ProjectSidebar` → `ProjectStore.remove` writes `projects.json`
    first; the prompt then appears over a project that no longer exists, and
    Cancel cannot restore it — `cancelPendingSwitch()` sets `selection` to an id
    that is no longer in `groups`. The document stays open and saveable; the
    project registration is gone with no undo.
24. **Settings › Key › Forget orphans an open dirty document.** Settings is its
    own scene, outside `guardedSelection`, so nothing asks. Afterwards
    `SecretDocumentViewModel.save()` returns `.failed("no decryption key is
    configured")`, which means every "Save and …" button in all three prompts
    fails and only Discard can clear the dialog.
25. **`SopsBridge` truncates a payload at the first NUL.** `String(cString:)`
    stops there. Harmless today because JSON escapes U+0000, but `decryptYAML`
    returns raw plaintext. Worth noting: length-aware `sops_take_result` /
    `sops_result_len` already exist in `cshim/main.go` and nothing calls them.
26. **Go error text reaches the UI and health findings verbatim on the save
    path.** `decryptToRows` deliberately suppresses its own decode error because
    the payload is plaintext; the save path does not apply the same rule, so the
    never-log constraint rests entirely on the Go side never including document
    content in a message.

**Resolved rather than deferred:** the ACE mitigation test that a review saw red
1 of 5 runs. Not reproduced in 11 further runs (8 isolated, 3 full), so instead
of picking an explanation the suite is now `.serialized` — the control test
deliberately executes a hook — and the absence assertion settles for up to 1.5 s
first, because an immediate check would pass while an asynchronously-invoked
hook was still starting. Five further runs clean.
