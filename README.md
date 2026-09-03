# SOPS GUI

A native macOS application for managing [SOPS](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age) encrypted secrets — form-based editing,
per-project organization, and files that stay 100% compatible with the standard
`sops` CLI. Working title; see [`PROPOSAL.md`](PROPOSAL.md) for the full spec,
non-goals, and open questions.

**New here?** [`docs/GUIDE.md`](docs/GUIDE.md) walks every screen and control in
order, with a picture of each and a copy-pasteable demo project to follow along
with.

## What it does today (0.5.0)

- **Projects.** Add one by path, drag & drop, or `NSOpenPanel`. Git worktrees are
  detected and grouped under their main repository. The sidebar is a tree:
  project → its encrypted files → that project's Access page.
- **Editing.** A table of key / value / type rows with every value masked, a
  per-row reveal, copy by clicking the value, add and remove rows, and an
  inspector for the selected row. Saves are atomic and refuse to overwrite a file
  something else changed underneath them.
- **Formats.** YAML, `.env` (dotenv), JSON and INI. A file whose recipients do
  not include your key opens read-only, showing its ciphertext rather than an
  error.
- **Access.** Who can read a file, and who can read everything a project's
  `.sops.yaml` governs — named recipients, the rules that anchor them, drift
  between a rule and the files it should govern, and rewrapping to apply a
  change. `.sops.yaml` is edited through sops's own YAML AST, never string
  surgery.
- **Keys.** Import an age identity by paste or from an existing key file, or
  generate a new one in the app. Optionally remember it in the Keychain behind
  Touch ID — see the caveat below. The key is cleared from memory when this Mac
  sleeps and after an inactivity period you set.
- **Health check.** A re-runnable wizard (PROPOSAL.md §6) over the machine's
  tooling, the embedded engine's freshness against upstream, the app's own
  security posture, and per-project health. Every finding that needs a system
  change is an explanation plus a command to copy.
- **Setup guide.** Copy-pasteable recipes for putting SOPS into a project, onto a
  server, and into a colleague's hands on any of the three platforms.
- **Updates.** Sparkle 2 with an EdDSA-signed appcast, off by default, and off
  means no request is made at all.

> ⚠️ **Building the `.app` now needs a provisioning profile.** Keychain storage
> uses the restricted `keychain-access-groups` entitlement, and a binary carrying
> it without an embedded profile is killed at launch. `Scripts/bootstrap.sh`
> installs the profile from `~/Development/_apple-developer-id/`, and
> `xcodebuild` fails loudly without it. **The Swift test suite and the snapshot
> tools are unaffected** — only building the app bundle needs this.
>
> Whether the Keychain write itself succeeds has **not** been verified end to
> end: every headless probe hit `errSecInteractionNotAllowed`, which may be a
> property of how a probe is launched rather than a real obstacle. If it does
> fail, the import still works and the app says the key was not saved for next
> time. The decision, the measurements, and what this does **not** buy are in
> [ADR 0006](docs/adr/0006-age-key-in-the-keychain.md).

## Constraints

- **arm64-only.** No x86_64 slice, in the app or the embedded engine.
- **Deployment target macOS 26.0**, defined once in `Engine/build-xcframework.sh`
  and mirrored in `Packages/SopsGUIKit/Package.swift` and `project.yml`. A
  mismatch between the three shows up as a linker warning on every object file.
- **The app never mutates the system.** No installers, no package managers, no
  `sudo`. Every health check that finds a problem offers an explanation and a
  command to copy, never a one-click fix outside the app's own data (see
  PROPOSAL.md §6).
- **Key material never touches the environment or the process `PATH`.** The Go
  engine injects age identities via its own `keyservice.KeyServiceServer` rather
  than upstream's `SOPS_AGE_KEY`/`decrypt.File` path — see
  [ADR 0001](docs/adr/0001-in-process-go-bridge.md) and
  [ADR 0004](docs/adr/0004-never-read-sops-age-key-from-the-environment.md). No
  secret values in logs, errors, or crash reports; naming a file or a key is
  fine, printing a value is not.
- **Hardened runtime with no exceptions, and no sandbox.**

## Quick start

```bash
./Scripts/bootstrap.sh
```

This builds the Go SOPS engine into an xcframework and generates
`SopsGUI.xcodeproj` via [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew
install xcodegen` first if you don't have it). Then either open
`SopsGUI.xcodeproj` in Xcode and run, or build from the command line:

```bash
xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Release build
```

`SopsGUI.xcodeproj` is generated, not checked in — re-run `bootstrap.sh` (or just
`xcodegen generate`) any time `project.yml` changes.

## Where things live

| Path | What |
|---|---|
| `PROPOSAL.md` | The spec. Single source of truth for scope and decisions. |
| `docs/GUIDE.md` | The user-facing walkthrough. Images are `docs/images/`, regenerated by `Scripts/guide-snapshots.sh`. |
| `docs/adr/` | Architecture decisions, numbered. Read before re-litigating anything. |
| `Engine/` | The Go SOPS bridge (cgo `c-archive` → xcframework). See `Engine/README.md`. |
| `Packages/SopsGUIKit/` | All app logic: `SopsEngine` (Swift wrapper over the C API), `SopsHealth` (health checks and `.sops.yaml` inspection), `SopsProjects` (project store, key store, file writing), `SopsUI` (SwiftUI views), plus `SnapshotTool`, a dev-only headless renderer. |
| `App/` | Thin Xcode app target — `SopsGUIApp.swift` wires the shell, onboarding sheet, and Settings scene; exists for archiving and notarization. |
| `Scripts/` | `test.sh` (the suite), `snapshots.sh` / `guide-snapshots.sh` (headless renders), `bootstrap.sh`, `clean-test-temp.sh`, `embed-provisioning-profile.sh`. |

Implementation plans, specs and per-ticket documents live **outside this
repository**, in `_ai-memory/projects/sops-macos-gui/tickets/`. What stays here
is what the code needs: the proposal, the ADRs, the guide.

The SOPS/age engine (upstream `getsops/sops` + `filippo.io/age`, compiled as a
static `c-archive`) runs **in-process** — the app never shells out to a `sops` or
`age` binary. That decision, and what the M0 spike proved to justify it, is
recorded in [ADR 0001](docs/adr/0001-in-process-go-bridge.md). `.sops.yaml` is
parsed by sops's own `config` package through the same bridge rather than a
hand-rolled parser, for reasons recorded in
[ADR 0002](docs/adr/0002-parse-sops-yaml-with-sops-own-parser.md).

## Running the test suites

```bash
# Swift package — use this, not bare `swift test`
./Scripts/test.sh

# Go engine
cd Engine && go vet ./... && go test ./...

# Network-denial check for the health check's one network call
# (GitHubReleaseSource, consent-gated engine-freshness lookup)
./Scripts/test-network-denied.sh
```

⚠️ **Do not run bare `swift test`.** SwiftPM's default build system copies
`Localizable.xcstrings` uncompiled, so every localized string resolves to its own
raw key: the two localization guards skip silently and one UI test fails for a
reason unrelated to the code under test. `./Scripts/test.sh` passes
`--build-system swiftbuild`, builds the xcframework if it is missing, and prints
any skipped tests at the end. Extra arguments go straight through
(`./Scripts/test.sh --filter SomeSuite`). The UI suite wants `--no-parallel`.

This machine has more than one Swift toolchain, and they disagree. "The suite is
green" is only meaningful with the compiler named — see `CLAUDE.md`.

Test fixtures build scratch trees in `$TMPDIR`, which macOS does not reap while
you are logged in. After a run:

```bash
./Scripts/clean-test-temp.sh            # dry run: count + reclaimable size
./Scripts/clean-test-temp.sh --apply
```

## License

MIT — see [`LICENSE`](LICENSE).
