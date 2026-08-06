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
