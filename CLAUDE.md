# sops-macos-gui — working conventions

## Worktrees

Git worktrees live in **`.worktrees/<branch-name>`** at the repository root.
The directory is gitignored. Create them there and nowhere else:

```bash
git worktree add .worktrees/<branch-name> -b <branch-name>
```

Do not use a harness-native worktree tool that picks its own location — it puts
the worktree outside the repo where it is easy to lose track of.

## Where things live

| Path | What |
|---|---|
| `PROPOSAL.md` | The spec. Single source of truth for scope and decisions. |
| `docs/adr/` | Architecture decisions, numbered. Read before re-litigating anything. |
| `docs/superpowers/plans/` | Implementation plans. |
| `Engine/` | The Go SOPS bridge (cgo `c-archive` → xcframework). |
| `Packages/SopsGUIKit/` | All app logic. `./Scripts/test.sh` is the fast loop. |
| `App/` | Thin Xcode app target; exists for archiving and notarization. |

## Toolchains — this machine has three Swift compilers

`swift build` / `swift test` resolve through `PATH` to a **swiftly-managed open-source
toolchain**, which is *not* the one `xcodebuild` uses. They disagree: source that compiles
under Xcode's bundled compiler can fail under the open-source one, and vice versa. A defect
present since M1 (`HealthFindingRow`'s synthesized init being private) surfaced only after a
restart changed which compiler `PATH` found first.

So "the suite is green" is only meaningful with the compiler named. Run both before believing
a build result, and say which one produced a number you are reporting.

### Run the suite with `./Scripts/test.sh`, not with bare `swift test`

The disagreement that matters most here is not between the three compilers — it is between
two **build systems**, and bare `swift test` picks the wrong one.

SwiftPM's llbuild-based native build system, which `swift test` still defaults to, **copies
`Localizable.xcstrings` uncompiled**. It never produces `en.lproj/Localizable.strings`, so
every `LocalizedKey` resolves to its own raw key. The newer Swift Build engine
(`--build-system swiftbuild`, already the default for `swift build`/`swift run`) compiles the
catalog properly, and so does `xcodebuild`.

Measured at `89795b0` on 2026-08-14, same filter, same machine, same compiler:

| | llbuild (bare `swift test`) | swiftbuild |
|---|---|---|
| `catalogIsBundled`, `everyKeyResolves` | **skipped** — assert nothing | **307 cases, passed** |
| `FirstRunWindowAndSummaryTests` "the Add Project control fills the sidebar footer" | **fails** | **passes** |

So bare `swift test` silently disables both localization guards *and* fails one real test for
a reason that has nothing to do with the code under test. That second row was carried as a
"flake" for a while — ⚠️ **it is not a flake and never was.** A deterministically failing
test filed as flaky is exactly how a real regression gets waved through next time.

`./Scripts/test.sh` passes `--build-system swiftbuild`, builds the xcframework if it is
missing, and prints any skipped tests in a block at the end — a skipped test asserted
nothing, and that belongs where it cannot be scrolled past. Extra arguments go straight
through: `./Scripts/test.sh --filter SomeSuite`.

`xcrun swift test` (Xcode's toolchain) is equally correct and is what release verification
uses. Either is a real answer; bare `swift test` is not. And "the suite is green" still
means nothing without naming which of them produced it.

## Visual verification — headless snapshots

- **Screenshotting the running app on this machine is not reliable.** The agent shell runs in a
  `Background` launchd session (`launchctl managername`), not `Aqua`, even when a real, logged-in
  `Aqua` session exists on the same machine — so bringing up a real window and grabbing it steals
  focus on the machine owner's desktop at best, and at worst `screencapture` just returns black or
  a bare desktop because the window is registered with the window server but never composited.
- Two renderers, opposite lifecycles: **`./Scripts/snapshots.sh`** writes the review
  set to gitignored `.snapshots/`, **`./Scripts/guide-snapshots.sh`** writes only the
  `guide-` entries to **committed** `docs/images/` for `docs/GUIDE.md`. Guide entries
  live in `SnapshotTool/Guide.swift` and mirror the walkthrough project the guide has
  the reader build; `Catalog.swift`'s fixtures are layout stress cases and make poor
  instructional images. Do not merge the two entry points.
- Instead: **`./Scripts/snapshots.sh`** — renders a catalog of views to PNG
  (`Packages/SopsGUIKit/.snapshots/`, gitignored, never committed). No window server, no display,
  no permissions prompt; deterministic enough to diff between commits.
- Add a view to the catalog = add one `Snapshot` to
  `Packages/SopsGUIKit/Sources/SnapshotTool/Catalog.swift`. Fixtures live in `Fixtures.swift` —
  in-memory or throwaway-temp-directory only, never `UserDefaults.standard`, never a real project.
- Uses `xcrun swift run`, never bare `swift run` — same toolchain hazard as above.
- **What it renders through a real (never-shown) `NSHostingView`/`NSWindow`, not `ImageRenderer`:**
  `ImageRenderer` was tried first and rejected — verified empirically that it cannot draw `List`,
  a styled `Form`, or `Link` at all (each came back as a large "unsupported content" glyph, or
  blank), and this app leans on all three throughout. See `Snapshot.swift`'s header comment for
  the full account and the technique that replaced it.
- **What it still cannot see:** `NSViewRepresentable` content wrapping something genuinely
  dynamic; a `ScrollView`'s interior past what's laid out in its own frame (a `List` is a
  `ScrollView` internally — a long list only shows its unscrolled top); anything that only exists
  after user interaction (a focused text field's cursor, a hovered button's highlight). And one
  found-not-designed-around gap: `NavigationSplitView`'s own `sidebar:` column does not populate
  under this technique — both `AppShell` snapshots show blank sidebars for exactly this reason,
  most likely because this tool's own `Background`-session process never gets the real
  window-occlusion signal `NavigationSplitView`'s sidebar item apparently waits for. A bare `List`
  outside of that specific slot is unaffected — see `Snapshot.swift`'s header for what was tried.
  Use the standalone `ProjectSidebar`/`HealthPanel` snapshots to actually check sidebar content.

## Test fixtures fill the disk — clean up before you finish

The suite builds its scratch trees as `$TMPDIR/<label>-<UUID>`. macOS does not
reap `$TMPDIR` while the login session is alive, so anything a run leaves behind
is a permanent deposit — nothing in the working tree grows, `git status` stays
clean, and the disk fills anyway.

**Fixed on 2026-08-10, but not completely.** Every scratch builder now registers
what it creates with `ScratchCleanup.ScratchDirectoryRegistry`, which deletes
the lot when the test process exits. Measured across a full run before and
after: **450 leftover entries per run → 12**, and of those twelve, ten are
macOS's own (`TemporaryDirectory.*`, `xcrun_db`, `TemporaryItems`) and two are
quarantine files written by `ProjectStore` itself, whose names cannot be known
in advance. `atexit` does not run when a process is killed or crashes — and
`swift test` here does occasionally hang at exit — so the script below is still
the backstop, not a formality.

Measured on 2026-08-10, after three days of iterating here: **244 376 leftover
entries, 117 GB.** The bulk was `ProjectHealthCheckLargeFileTests` — 2 529
`large-*` directories holding 506 copies of a 200 MB `huge-asset.bin`, 113 GB by
itself. The rest came from `project-*`, `vm-fixture-*`, `sops-spike-*` (101 246
of those alone), `repo-*`, `atomicwriter-*`, `shell-harness-*`, `cli-decrypt-*`
and ~70 other labels. The disk was down to 71 GB free on a 926 GB volume and the
cause was invisible from the repo — nothing in the working tree grows.

**Obligations, in order:**

1. **Ran the suite in this session? Run the cleanup before you report done.**
   ```bash
   ./Scripts/clean-test-temp.sh            # dry run: count + reclaimable size
   ./Scripts/clean-test-temp.sh --apply
   ```
   It removes `$TMPDIR` entries whose name ends in a UUID — the shape every
   fixture helper here produces — and only those older than 60 minutes, so a run
   in another terminal is never pulled out from under itself. Use
   `--min-age 0` only when you know nothing else is running.
2. **Writing a new test that touches the filesystem? Register what you create.**
   The existing helpers do it for you — `ProjectFixture.makeDirectory`,
   `makeProjectRoot`, `scratchDirectory` all register now, so using one is
   enough. Building a path yourself is the case to watch:
   ```swift
   let root = try ScratchDirectoryRegistry.shared.makeDirectory("thing")

   // or, for a path handed to a subprocess that creates the file itself:
   let log = FileManager.default.temporaryDirectory
       .appendingPathComponent("capture-\(UUID().uuidString).log")
       .registeredForCleanup()
   ```
   A `defer { try? FileManager.default.removeItem(at: root) }` is still better
   when the tree is large — it frees the space during the run rather than at the
   end of it. Registration is the floor, not the ceiling.

   Keep the `<label>-<UUID>` shape: `Scripts/clean-test-temp.sh` matches on it,
   and a fixture named otherwise is one the backstop cannot sweep.
3. **Anything writing hundreds of MB is a fixture that must die in the same
   test.** `huge-asset.bin` is 200 MB per invocation. A leaked one is not noise.

Quick check at any point: `du -sh "$TMPDIR"`. Healthy is under a gigabyte.

## Hard constraints

- **arm64-only.** One slice, everywhere.
- **Deployment target is one variable** — `MACOSX_DEPLOYMENT_TARGET` in
  `Engine/build-xcframework.sh`, mirrored in `Package.swift` and `project.yml`.
  A mismatch produces a linker warning on every object file.
- **Key material never goes through the environment.** The bridge injects age
  identities via its own `keyservice.KeyServiceServer`. Never call
  `decrypt.File`/`decrypt.Data`, never set `SOPS_AGE_KEY*` in app code. (ADR 0001.)
- **The app never mutates the system.** No installers, no package managers, no
  `sudo`. Remediation is an explanation plus a string the user can copy.
- **No secret values in logs, errors or crash reports.** Naming a file or a key
  is fine; printing a value is not.
- Apple signing credentials live in `~/Development/_apple-developer-id/mac_studio/`
  and never enter this repo.
