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
| `Packages/SopsGUIKit/` | All app logic. `swift test` here is the fast loop. |
| `App/` | Thin Xcode app target; exists for archiving and notarization. |

## Toolchains — this machine has three Swift compilers

`swift build` / `swift test` resolve through `PATH` to a **swiftly-managed open-source
toolchain**, which is *not* the one `xcodebuild` uses. They disagree: source that compiles
under Xcode's bundled compiler can fail under the open-source one, and vice versa. A defect
present since M1 (`HealthFindingRow`'s synthesized init being private) surfaced only after a
restart changed which compiler `PATH` found first.

So "the suite is green" is only meaningful with the compiler named. Run both before believing
a build result, and say which one produced a number you are reporting.

Related: SwiftPM's native build system **copies `Localizable.xcstrings` uncompiled** — it never
produces `en.lproj/Localizable.strings`, so under `swift test` every `LocalizedKey` resolves to
its own raw key. `xcodebuild` compiles it correctly and the shipped app is fine. The catalog
guard therefore reads the `.xcstrings` JSON directly rather than the bundle; the bundle-based
assertions are gated with `.enabled(if:)` and skip with a stated reason where they cannot pass.

`swift run` does **not** have this problem, checked directly: this toolchain's `swift build`/
`swift run` now default to the newer Swift Build engine (`--build-system swiftbuild`, not the
llbuild-based native one `swift test` still defaults to), and that engine compiles the string
catalog correctly. Confirmed by reading the snapshot tool's own PNG output — real English text
throughout, never a raw key like `sidebar.projects`.

## Visual verification — headless snapshots

- **Screenshotting the running app on this machine is not reliable.** The agent shell runs in a
  `Background` launchd session (`launchctl managername`), not `Aqua`, even when a real, logged-in
  `Aqua` session exists on the same machine — so bringing up a real window and grabbing it steals
  focus on the machine owner's desktop at best, and at worst `screencapture` just returns black or
  a bare desktop because the window is registered with the window server but never composited.
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
