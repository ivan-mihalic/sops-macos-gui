# SOPS GUI

A native macOS application for managing [SOPS](https://github.com/getsops/sops) +
[age](https://github.com/FiloSottile/age) encrypted secrets — form-based editing,
per-project organization, Touch ID protected age keys, producing files 100%
compatible with the standard `sops` CLI. Working title; see
[`PROPOSAL.md`](PROPOSAL.md) for the full spec, non-goals, and open questions.

**Current state (M2 — core editing, complete):** the app has a sidebar shell with About and
Settings pinned at the bottom, and a re-runnable health check / onboarding wizard
(PROPOSAL.md §6) that verifies the machine's tooling, the embedded engine's
freshness, the app's own security posture, and per-project health. On top of that,
M2 added the editor: add a project by path, drag & drop or `NSOpenPanel` (git
worktrees are detected and grouped under their main repository), browse the
encrypted files it finds, open one into a form of key / value / type rows with
every value masked and a per-row reveal and copy, add and remove keys, and save
atomically. Every file the editor writes is round-tripped against the real `sops`
CLI in `EditorCompatibilityTests` — comments, key order, recipients and
`encrypted_regex` all survive, and untouched values keep their exact ciphertext.

Both items that blocked M2 at final verification are closed. A file declaring
`type:bytes` used to panic vendored sops v3.13.3 and take the whole process
down; every one of the nine cgo entry points now recovers and returns a
described error, and no panic payload reaches the message. And the project scan
states its own scope: it skips dependency and build directories
(`node_modules`, `.build`, `.worktrees`, …), and now says which ones in the
finding itself rather than only when it also exhausts its file budget — PROPOSAL.md
§6 D forbids reporting OK about files the check did not look at.

The age key lives in memory for the session only; Keychain and Touch ID are M3.
YAML is the only format this build opens (PROPOSAL.md §10).

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
  [ADR 0001](docs/adr/0001-in-process-go-bridge.md). No secret values in logs,
  errors, or crash reports; naming a file or a key is fine, printing a value
  is not.

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
| `docs/adr/` | Architecture decisions, numbered. Read before re-litigating anything. |
| `docs/superpowers/plans/` | Implementation plans. |
| `Engine/` | The Go SOPS bridge (cgo `c-archive` → xcframework). See `Engine/README.md`. |
| `Packages/SopsGUIKit/` | All app logic, split into `SopsEngine` (Swift wrapper over the C API), `SopsHealth` (the onboarding/health-check model), and `SopsUI` (SwiftUI views). `swift test` here is the fast loop. |
| `App/` | Thin Xcode app target — `SopsGUIApp.swift` wires the shell, onboarding sheet, and Settings scene; exists for archiving and notarization. |

The SOPS/age engine (upstream `getsops/sops` + `filippo.io/age`, compiled as a
static `c-archive`) runs **in-process** — the app never shells out to a `sops` or
`age` binary. That decision, and what the M0 spike proved to justify it, is
recorded in [ADR 0001](docs/adr/0001-in-process-go-bridge.md). `.sops.yaml` is
parsed by sops's own `config` package through the same bridge rather than a
hand-rolled parser, for reasons recorded in
[ADR 0002](docs/adr/0002-parse-sops-yaml-with-sops-own-parser.md).

## Running the test suites

Three independent suites, all expected green on a clean checkout:

```bash
# Go engine
cd Engine && go vet ./... && go test ./...

# Swift package (SopsEngine, SopsHealth, SopsUI)
cd Packages/SopsGUIKit && swift test

# Network-denial check for the health check's one network call
# (GitHubReleaseSource, consent-gated engine-freshness lookup)
./Scripts/test-network-denied.sh
```

For a fully clean run (as CI or a fresh clone would see it):

```bash
rm -rf Engine/build Packages/SopsGUIKit/.build SopsGUI.xcodeproj
./Scripts/bootstrap.sh
cd Engine && go vet ./... && go test ./...
cd ../Packages/SopsGUIKit && swift test
cd ../.. && xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Release build
```

## License

MIT — see [`LICENSE`](LICENSE).
