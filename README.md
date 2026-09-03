# SOPS GUI

A native macOS app for editing [SOPS](https://github.com/getsops/sops)-encrypted
secrets with [age](https://github.com/FiloSottile/age) keys — a form instead of
`sops file.yaml` in `$EDITOR`, and files that stay byte-for-byte compatible with
the `sops` CLI.

**MIT licensed, and open source on purpose.** A tool that handles your private
keys should be one you can read. See [Auditing this yourself](#auditing-this-yourself).

![The editor](docs/images/guide-10-editor.png)

## Why

`sops` is excellent and its CLI is not the problem. What the CLI cannot do is
show you, at a glance, *which* files in a project are encrypted, *who* can read
each one, and *which* of them have drifted from the rule that is supposed to
govern them. That is the gap this fills — and it fills it without ever becoming
a second implementation of sops: the encryption, the `.sops.yaml` parsing and
the config rewriting are all done by upstream's own Go code, compiled into the
app.

Requires **macOS 26 or later** on **Apple silicon**.

## Install

Download the latest `.dmg` from
[**Releases**](https://github.com/ivan-mihalic/sops-macos-gui-releases/releases),
open it, drag the app to Applications.

The app is signed with a Developer ID certificate and notarized by Apple, so it
opens without a Gatekeeper warning. Updates are handled by
[Sparkle](https://sparkle-project.org) over an EdDSA-signed appcast, and are
**off until you turn them on** — with the switch off, the app makes no network
requests at all.

## What it does

- **Projects** — add by path, drag & drop, or a panel. Git worktrees are
  detected and grouped under their main repository. The sidebar is a tree:
  project → its encrypted files → that project's Access page.
- **Editing** — a table of key / value / type rows with every value masked, a
  per-row reveal, copy by clicking a value, add and remove rows, and an
  inspector for the selected row. Saves are atomic and refuse to overwrite a
  file that changed underneath them.
- **Formats** — YAML, `.env`, JSON and INI. A file your key cannot open shows
  its ciphertext read-only, along with who *can* read it, instead of an error.
- **Access** — who can read one file, and who can read everything a project's
  `.sops.yaml` governs: named recipients, the rules anchoring them, drift
  between a rule and the files it should cover, and rewrapping to apply a
  change.
- **Keys** — import an age identity by paste or from a key file, or generate a
  new one in the app. Optionally keep it in the Keychain behind Touch ID.
- **Health check** — a re-runnable review of your tooling, the embedded
  engine's freshness against upstream, this machine's security posture, and
  each project. Every finding that needs a change is an explanation plus a
  command you run yourself.
- **Setup guide** — copy-pasteable recipes for putting SOPS into a project, onto
  a server, and into a colleague's hands on macOS, Linux or Windows.

## Security model

This is the part worth reading before trusting the app with anything.

**The engine runs in-process.** Upstream `getsops/sops` and `filippo.io/age` are
compiled to a static Go archive and linked into the app. It never shells out to
a `sops` or `age` binary, so there is no subprocess to intercept, no argument
list carrying a key, and no dependency on what is installed on your `PATH`.
([ADR 0001](docs/adr/0001-in-process-go-bridge.md))

**Key material never touches the environment.** The bridge injects age
identities through sops's own `keyservice.KeyServiceServer` rather than
upstream's `SOPS_AGE_KEY` path, and the app never reads that variable — not even
to warn about it. ([ADR 0004](docs/adr/0004-never-read-sops-age-key-from-the-environment.md))

**A private key is held for a session, and optionally in your Keychain.** It is
cleared from memory when this Mac sleeps and after an inactivity period you
choose (5 minutes by default). If you ask it to be remembered, it goes into the
data-protection Keychain behind a user-presence check — this Mac only, never
synced to iCloud — and is unlocked once per launch with Touch ID.
([ADR 0006](docs/adr/0006-age-key-in-the-keychain.md), which also states plainly
what this does **not** buy.)

**No secret values in logs, errors or crash reports.** Naming a file or a key
path is fine; printing a value is not. Copied secrets are marked concealed so
clipboard managers do not archive them, and the clipboard is cleared on a timer.

**The app never mutates your system.** No installers, no package managers, no
`sudo`. Every health finding that needs a system change gives you an explanation
and a command to run yourself. A security tool that silently runs `brew install`
is a security tool nobody can audit.

**Hardened runtime with no exceptions.** No JIT, no unsigned executable memory,
no library validation opt-out. Not sandboxed, and that is a deliberate,
documented trade: you point this app at your own repositories anywhere on disk.

**Two entitlements, both explained.** `keychain-access-groups` and
`com.apple.application-identifier`, needed for the Keychain storage above, in
[`App/SopsGUI.entitlements`](App/SopsGUI.entitlements).

## Auditing this yourself

Open source here means "you can check", so here is where to look.

| Question | Where |
|---|---|
| Does it really not shell out to `sops`? | [`Engine/`](Engine/) — the whole bridge, and `Engine/README.md` |
| What can cross the Swift/Go boundary? | [`Engine/gobridge/bridge.go`](Engine/gobridge/bridge.go) — one text-in/text-out C surface |
| How is my key held in memory? | [`SessionKeyStore.swift`](Packages/SopsGUIKit/Sources/SopsProjects/SessionKeyStore.swift) — including a section on what it can **not** guarantee |
| How is it stored, if I let it? | [`KeychainAgeKeyVault.swift`](Packages/SopsGUIKit/Sources/SopsProjects/KeychainAgeKeyVault.swift) |
| Does it phone home? | [`UpstreamVersionSource.swift`](Packages/SopsGUIKit/Sources/SopsHealth/UpstreamVersionSource.swift) — the only network call in the app — and [`Scripts/test-network-denied.sh`](Scripts/test-network-denied.sh), a suite run with the network hard-denied |
| Why is anything the way it is? | [`docs/adr/`](docs/adr/) — numbered decisions, including the rejected alternatives |
| What was it meant to be? | [`PROPOSAL.md`](PROPOSAL.md) — the spec, kept current, non-goals included |

**Verify the binary you downloaded** rather than taking the signature on trust:

```bash
codesign --verify --deep --strict --verbose=2 /Applications/SopsGUI.app
spctl --assess --type execute --verbose /Applications/SopsGUI.app
codesign -d --entitlements - /Applications/SopsGUI.app
```

**Check the files it writes** against the CLI you already trust — this is the
guarantee the project treats as non-negotiable, and it has its own test suite
(`EditorCompatibilityTests`): comments, key order, recipients and
`encrypted_regex` all survive a round trip, and values you did not touch keep
their exact ciphertext.

```bash
sops --decrypt secrets.yaml     # before and after editing in the app
```

Found something wrong? Open an issue. For anything you believe is a security
vulnerability, please report it privately through GitHub's security advisories
rather than in a public issue.

## Building from source

```bash
./Scripts/bootstrap.sh
xcodebuild -project SopsGUI.xcodeproj -scheme SopsGUI -configuration Release build
```

`bootstrap.sh` builds the Go engine into an xcframework and generates
`SopsGUI.xcodeproj` with [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`). The `.xcodeproj` is generated, not committed — re-run
it whenever `project.yml` changes.

⚠️ **Building the `.app` needs an Apple Developer provisioning profile**, because
the Keychain storage uses a restricted entitlement and a binary carrying it
without an authorising profile is killed at launch. `bootstrap.sh` installs the
profile if it finds one and says so loudly if it does not. **Running the tests
does not need any of this.**

### Tests

```bash
./Scripts/test.sh                  # Swift package — NOT bare `swift test`
cd Engine && go vet ./... && go test ./...
./Scripts/test-network-denied.sh   # proves the one network call is the only one
```

⚠️ Bare `swift test` silently uses a build system that copies the string catalog
uncompiled: two localization guards skip, and one UI test fails for reasons
unrelated to your change. `./Scripts/test.sh` uses the right one, builds the
engine if missing, and prints skipped tests where they cannot be scrolled past.
The UI suite wants `--no-parallel`.

Fixtures build scratch trees in `$TMPDIR`, which macOS does not reap while you
are logged in — `./Scripts/clean-test-temp.sh --apply` after a run.

### Repository layout

| Path | What |
|---|---|
| `PROPOSAL.md` | The spec. Single source of truth for scope and decisions. |
| `docs/GUIDE.md` | User walkthrough, every screen with a picture. |
| `docs/adr/` | Architecture decisions, numbered. Read before re-litigating anything. |
| `Engine/` | The Go SOPS bridge (cgo `c-archive` → xcframework). |
| `Packages/SopsGUIKit/` | All app logic: `SopsEngine`, `SopsHealth`, `SopsProjects`, `SopsUI`, plus a headless snapshot renderer. |
| `App/` | Thin Xcode app target; exists for archiving and notarization. |
| `Scripts/` | `test.sh`, `bootstrap.sh`, snapshot renderers, `clean-test-temp.sh`. |

Implementation plans and per-ticket working documents live outside this
repository. What stays here is what the code needs: the proposal, the ADRs, the
guide.

## Contributing

Issues and pull requests are welcome. Two things to know before a larger change:

- **Decisions live in `docs/adr/`.** If a change contradicts one, the ADR is
  where to argue with it — that is what they are for.
- **Bugs get a failing test first.** The test proves the bug, then the fix makes
  it pass.

Code, identifiers and comments are in English.

## License

MIT — see [`LICENSE`](LICENSE). It bundles
[sops](https://github.com/getsops/sops) (MPL-2.0),
[age](https://github.com/FiloSottile/age) (BSD-3-Clause) and
[Sparkle](https://sparkle-project.org) (MIT); their licenses are their own.
