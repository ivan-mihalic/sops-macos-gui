# SOPS macOS GUI — Project Proposal

Native macOS application for pleasant management of SOPS + age encrypted secrets:
form-based editing, per-project organization, age key management, Touch ID protected —
producing files 100% compatible with the standard `sops` CLI (CI, servers, colleagues).

**Repo:** `ivan-mihalic/sops-macos-gui` — private during development, **goes public once a functional version exists**.
**License:** MIT (open source, fully auditable by the public).
**Monetization:** free + "Buy me a coffee" link. No App Store, no licensing code.

---

## 1. Goals & Non-Goals

### Goals
- Manage secrets per project (multiple projects, added by picking a path — incl. git worktrees)
- Form-based editing of encrypted files: add/remove/edit keys, readonly mode with copy-to-clipboard
- Automatic transparent encrypt/decrypt in the background (user never sees sops CLI)
- age key management: own private key (Touch ID protected), recipients (public keys) per project/environment/developer
- Never hold anyone else's private key — only public keys of colleagues and servers (native age model)
- Own private key: reveal in plaintext after Touch ID unlock, copy out (e.g. manual save into 1Password — no integration)
- Configurable unlock session TTL so Touch ID isn't required for every action
- Built-in help with copy-paste snippets (docker-compose workflows, key generation on all platforms)
- Re-runnable onboarding that verifies the machine's tooling, the embedded engine's freshness,
  the app's own security posture, and per-project health — and guides the user to fix what it finds (§6)

### Non-Goals (v1)
- Team sync server / hosted anything — `.sops.yaml` in the repo is the source of truth
- 1Password or other password-manager integration
- Cloud KMS backends (AWS KMS, GCP KMS, Vault) — age only in v1; architecture must not block adding them later
- iOS/iPadOS

---

## 2. Security & Encryption Model

### Trust model
```
Developer A:  private_A (only on A's machine)  →  public_A  ┐
Developer B:  private_B (only on B's machine)  →  public_B  ├─ public keys are NOT
Server:       private_S (only on the server)   →  public_S  ┘  sensitive → live in git
```
- `.sops.yaml` in each project repo holds **recipients (public keys only)** — the app reads/edits it
- SOPS generates a random data key per file, encrypts content with it, and wraps the data key for **each** recipient (X25519). Any single recipient decrypts with their own private key. Nobody ever holds anyone else's private key.
- Adding a colleague = paste their public key into GUI → app runs `updatekeys` (re-wrap) → commit
- Removing a colleague = remove public key + `updatekeys` + **the app reminds you to rotate the actual secret values** (the removed person may hold an old copy)

### Own key storage
- Private age key stored in **macOS Keychain** with `SecAccessControl(.userPresence)` → Touch ID / password gate
- Marketing-honest Secure Enclave usage: SE cannot hold X25519 keys (P-256 only), so an SE-backed key **wraps** the age key
- Unlock session: decrypted key held only in memory with a configurable TTL (Settings), zeroed after expiry
- Reveal own key: Touch ID → show `AGE-SECRET-KEY-1…` + copy button; clipboard auto-cleared after ~30 s; auto-hide after timeout
- Memory hygiene from day one: no swap-out of key material where possible, explicit zeroing, no key material in logs/crash reports
- Import of existing `~/.config/sops/age/keys.txt` (migration into Keychain)

### File compatibility (hard requirement)
Every file written by the app must round-trip with the standard `sops` CLI (MAC, key groups,
partial encryption / `encrypted_regex`). We **never reimplement** the SOPS format.

---

## 3. Architecture

| Layer | Technology |
|---|---|
| UI | SwiftUI, macOS 26+ |
| SOPS/age engine | Go: upstream `getsops/sops` + `filippo.io/age` compiled as **xcframework** (`c-archive`), called in-process from Swift |
| Engine fallback | Bundled `sops`/`age` binaries invoked as subprocess (no sandbox → allowed). Used if the c-archive bridge spike fails. |
| Key storage | Keychain + LocalAuthentication (Touch ID), SE-wrapped |
| Updates | Sparkle 2 (EdDSA-signed appcast) |
| i18n | String Catalogs (`.xcstrings`), English default and only language for now |

**M0 spike done — verdict GO.** The in-process bridge is proven byte-compatible with the
`sops` CLI in both directions, including MAC and `encrypted_regex`; the subprocess fallback
is not needed. Reasoning, constraints and consequences: [ADR 0001](docs/adr/0001-in-process-go-bridge.md).
Two constraints from that ADR bind everything downstream:

- Key material is passed as function arguments through a custom `keyservice.KeyServiceServer`.
  Never switch to upstream's env-based key discovery (`SOPS_AGE_KEY`, `decrypt.File`).
- arm64-only for v1; the deployment target lives in one variable in the bridge build script.

### Project & worktree handling
- Add project by path (NSOpenPanel or drag & drop); no sandbox → free disk access
- Worktree detection: `.git` **file** (not dir) → parse `gitdir:` pointer → group worktrees under their main repo; edits possible in any worktree
- App discovers `.sops.yaml`, encrypted files (by sops metadata sniffing), and environments per project

---

## 4. UI / UX

- **Follow Apple HIG for macOS 26+ to the maximum, including Liquid Glass** design language
- **Sidebar layout** (NavigationSplitView): projects/environments in sidebar; pinned at the bottom: **About** and **Settings**
- **Settings** opens with the standard `⌘,` shortcut; contains: session TTL, clipboard clear delay, update channel/auto-update toggle, language (future), theme override
- **Theme:** light/dark following system (auto), manual override in Settings
- **About:** app version, check-for-updates button, auto-update toggle (Sparkle best practice: user consent on first launch, EdDSA signatures, delta updates later)
- **Multilanguage-ready:** all strings in String Catalogs from day one; English is the default and the only shipped language for now
- Editor: form rows (key / value / type), value masking with per-field reveal, readonly mode with one-click copy, add/remove rows, unsaved-changes indicator, atomic save (encrypt to temp → rename)

---

## 5. In-App Help (with copy-paste snippets)

A dedicated Help section with runnable snippets:

1. **With docker-compose**
   - `sops exec-env secrets/prod.yaml 'docker compose up -d'`
   - Makefile target generating `.env` from encrypted YAML: `sops -d secrets/prod.yaml | yq -o=props > .env`
   - Pattern: non-secret config in `compose.<env>.yaml` (`environment:` / `env_file:`), secrets injected via sops
2. **Without docker-compose**
   - `sops exec-env` for arbitrary processes, direnv integration, systemd `EnvironmentFile` generation
3. **Key generation on a server (Linux)**
   ```bash
   apt install age / dnf install age
   age-keygen -o /etc/age/server.key   # print public key, chmod 600, root-only
   ```
4. **Key generation for colleagues**
   - macOS: `brew install age && age-keygen` (or in-app generator)
   - Linux: distro package + `age-keygen`
   - Windows: `winget install FiloSottile.age` / scoop; WSL note
5. **`.sops.yaml` cookbook** — creation_rules, `encrypted_regex` partial encryption, per-environment key groups; plus a wizard in the app that generates it

---

## 6. Onboarding & Health Check

A **re-runnable** wizard that answers one question: *is this machine set up to work with
encrypted secrets safely, and is everything current?* It runs as a modal wizard on first
launch and is available afterwards as a **Health** panel in Settings.

### Principle: the app never mutates the system

Every finding that needs a system change is presented as an **explanation plus a copyable
command** (`brew upgrade sops`). The app does not run installers, does not escalate
privileges, and does not touch anything outside its own data. A security tool that silently
runs `brew install` is a security tool nobody can audit.

The exception is actions *inside the app's own domain* — generating an age key, adding a
line to `.gitignore`, running `updatekeys` — which the app already owns and may offer as a
one-click fix.

### What it checks

**A — External CLI tools** (none are required for the app to work; the engine is in-process).
They matter because the Help snippets in §5 run in the user's terminal and CI.

| Tool | Why | Rule |
|---|---|---|
| `sops` | terminal/CI decryption of files this app writes | warn if older than the embedded engine |
| `age` / `age-keygen` | key generation outside the app | warn if outdated |
| `git` | worktree detection, commit hygiene | warn below 2.30 |
| `yq` | the `.env` generation snippet uses **v4** syntax (`-o=props`) | fail on v3, which would silently produce wrong output |
| `docker` | compose snippets only | informational; absence is not a problem |

Tool discovery must **not** rely on the process `PATH` — a GUI app launched from Finder does
not inherit the login shell's `PATH`, so Homebrew tools appear missing. Discovery reads the
login shell's `PATH` and probes known locations.

**B — Embedded engine vs upstream.** The version of `sops`/`age` compiled into the bridge,
compared against the latest upstream release, with a link to the release notes and the
project's security advisories. This is a **version comparison, not CVE matching** — the app
must not claim to know whether a given version is vulnerable. Requires network; gated behind
the same user consent as app update checks, and fully functional offline (reports "unknown").

**C — App security posture.** macOS version; Touch ID available and enrolled; own age key
present in the Keychain; a plaintext `~/.config/sops/age/keys.txt` still lying on disk
(offer import, then explain why deleting it is an improvement); session TTL sanity; app
itself up to date.

**D — Project health** (per project; this absorbs the "Health check per project" item
formerly listed in §8). `.sops.yaml` parses; every encrypted file's recipient list matches
the creation rule that governs it; files still encrypted to recipients that were removed
from `.sops.yaml`; plaintext secret files inside the repo that are not gitignored.

> Honesty constraint: the app can verify *structurally* that a recipient's public key is in
> a file's key list. It cannot verify that the holder of that key can actually decrypt —
> that would require their private key. The wording in the UI must say so.

> `.sops.yaml` is parsed by sops's own `config` package through the bridge, never by our own
> YAML code — [ADR 0002](docs/adr/0002-parse-sops-yaml-with-sops-own-parser.md). This extends
> §2's "we never reimplement the SOPS format" from the file format to the configuration
> format. A rule using a backend the app cannot evaluate (pgp, KMS, Vault) reports *Unknown*
> naming that backend — the check ran and does have a verdict on the age recipients, it simply
> cannot vouch for the rest. The invariant that matters: **it must never report OK about a
> configuration it cannot read**, including a rule no file matches yet.

> **Constraint on the milestone that ships the project picker (M2).** This check walks the
> whole project tree, and as of M1 it excludes only `.git`, `.hg` and `.svn`. The hidden-file
> exclusion was deliberately removed — a sops-encrypted `.env` is ordinary, and an exclusion
> the user cannot see and the copy does not admit is the same failure class as a vacuous OK.
> That decision is right and stands; its cost has not been paid yet. Measured on a real
> repository: **272,802 files walked against 13,899 before, a 19.6× blowup costing ~170
> seconds**, driven by `node_modules/.bun` and `.worktrees`, to find one additional `.env`.
> On this repository the same count is 5,347 against 30, because `CLAUDE.md` mandates
> `.worktrees/<branch>` at the repository root — so the app would be slow on its own repo.
>
> This is invisible today only because `HealthReport.standard` injects `NoProjects()`. It
> goes live the moment a real project source exists, as a multi-minute freeze on first
> launch. **A project picker may not ship until this is solved**, and neither of the two
> honest solutions is free:
>
> - a dependency/build-directory exclusion (`node_modules`, `.build`, `target`, `vendor`,
>   `.worktrees`, …) — which reintroduces "places this app promises not to look", so it must
>   be *stated in the finding*, not buried in a constant; or
> - a file-count or wall-clock budget, with the finding degrading to *Unknown* and naming
>   what it did not reach when the budget is hit.
>
> "Being slow is better than being silent" is the rule the current code follows, and it is
> the right rule — but it stops holding when slow means a three-minute modal on first launch.
> A user who force-quits the wizard learns nothing at all, which is strictly worse than a
> disclosed exclusion. Whichever route is taken, the honesty invariant above is unchanged:
> the check may not report OK about files it did not look at.

### Behaviour

- Nothing blocks. A failed check never prevents using the app; it shows a badge and an explanation.
- Every check is independently re-runnable, and the whole report re-runs on demand.
- Results are categorised **OK / Warning / Problem / Skipped / Unknown**. The last two are
  distinct and both always state why: **Skipped** means the subject does not exist yet (a
  feature that ships in a later milestone); **Unknown** means the check ran but could not
  reach a verdict (offline, no consent, or a configuration it cannot read). Neither may
  outrank a real Warning or Problem in the headline status, and neither may be shown as OK.

---

## 7. Build, Signing & Release

Built **locally on the Mac Studio** (no CI build infra), released by uploading finished
artifacts to GitHub Releases — same process as the `engram` and `ui-tester` projects
(`Engram-x.y.z.dmg` + `.zip` assets, `gh release create`).

### Apple Developer ID (existing account)
Local credentials: `~/Development/_apple-developer-id/mac_studio/`
- `AuthKey_P7MSPCJRMF.p8` — App Store Connect API key (for `notarytool`)
- `DeveloperID.p12` + `developerID_application.cer` — Developer ID Application signing identity
- Issuer ID: `3c143dad-fa95-4b06-a92f-fbd2f832723f`
- Key ID: `P7MSPCJRMF`

> Note: the `.p8`/`.p12` files stay strictly outside the repo. The IDs above are moved into an
> untracked `release.local.env` before the repo goes public; the release script reads them from there.

### Release pipeline (script in repo, run on Mac Studio)
1. `xcodebuild archive` (Release, arm64; universal later if demand)
2. `codesign` with Developer ID Application + hardened runtime
3. `xcrun notarytool submit --key AuthKey_P7MSPCJRMF.p8 --key-id P7MSPCJRMF --issuer 3c143dad-…` → `stapler staple`
4. Create `.dmg` (create-dmg) + `.zip` (for Sparkle)
5. Sign Sparkle appcast, `gh release create vX.Y.Z *.dmg *.zip`
6. Later: Homebrew cask once public

---

## 8. DX Extras (proposed — beyond agreed scope)

Ranked by value/effort; ✦ = recommended for v1:

- ✦ **Encrypted-file diff view** — human-readable diff of two versions of an encrypted file (git HEAD vs working copy); solves the worst sops papercut
- ~~**Health check per project**~~ — promoted into agreed scope, see §6 D
- ✦ **`.env` import wizard** — take an existing plaintext `.env`, convert to encrypted sops YAML, offer to shred the original and add it to `.gitignore`
- ✦ **Plaintext-leak guard** — warn when a decrypted/temp file is inside the repo and not gitignored; optional pre-commit hook installer blocking accidental plaintext secret commits
- ✦ **Copy in target format** — copy a key as `KEY=value`, `export KEY=value`, `-e KEY=value` (docker), or YAML fragment
- **⌘K quick switcher** — jump to project/environment/secret by fuzzy search
- **Menu bar quick access** — copy a frequently used secret without opening the main window (respects session TTL)
- **Rotation tracking** — per-secret "last rotated" timestamp + reminders (esp. after recipient removal)
- **Git awareness** — badge for uncommitted secret changes, one-click commit of `updatekeys` result
- **CLI companion** — `sops-gui open .` deep link from terminal into the right project
- **Raycast extension** (post-v1)

---

## 9. Milestones

| # | Milestone | Content |
|---|---|---|
| M0 | **Spike** ✅ | Go xcframework bridge; CLI-compatibility round-trip proof. Verdict: in-process, [ADR 0001](docs/adr/0001-in-process-go-bridge.md) |
| M1 | **Shell & onboarding** ✅ | App scaffold (sidebar, About, Settings, String Catalogs), engine integration, the whole of §6 |
| M2 | **Core editing** ✅ | Project add (incl. worktrees), file list, form editor, encrypt/decrypt, atomic save all shipped and CLI-round-tripped. Plan: [2026-08-07](docs/superpowers/plans/2026-08-07-m2-core-editing.md). Task 6 holds the age key in memory for the session only, which M3 replaces with the Keychain behind the same protocol |
| M3 | Keys & security | Keychain + Touch ID, session TTL, key generate/import/reveal, clipboard hygiene |
| M4 | Recipients & help | `.sops.yaml` editing, updatekeys, recipient add/remove + rotate reminder, Help section with snippets |
| M5 | Polish & release | Liquid Glass pass, Sparkle, notarized release pipeline, first public release → **repo goes public** |
| M6 | DX extras | Items from §8 by priority |

> **How M2 got its ✅** (final verification 2026-08-08, then a four-task fix wave the same
> day). Final verification deliberately withheld the ✅ and named two blockers; both are now
> closed, each with a failing test written first and the fix proved against it.
>
> 1. **`recover()` at the C boundary** — closed (Task 13). Vendored sops v3.13.3 panics
>    (`hash of unhashable type []uint8`) on any value declaring `type:bytes`, and the `type:`
>    tag is *not* covered by the GCM additional data, so flipping one `type:str` leaves the
>    value authenticating perfectly and detonating on decryption — no key required. The
>    nastier sibling is `type:bytes` on the **MAC** itself, where every value looks sound.
>    All nine cgo entry points now recover and return the ordinary error contract; the
>    message carries only compile-time facts, never the panic payload, so a canary planted
>    in the file cannot escape through it. ~35 targeted malformations and 2.7M fuzz
>    executions found no other panic and **no wrong-output case**.
> 2. **The §6 D exclusion is now stated in the finding** — closed (Task 14), along with two
>    further instances of the same fault the sweep turned up: the plaintext finding ignored
>    `wasTruncated` entirely, and the recipients `.skipped` reason claimed "anywhere under
>    &lt;root&gt;". Exclusion is *stated*, budget exhaustion still *demotes* to Unknown —
>    `.git` is excluded on every real repository, so demoting on exclusion would make every
>    project finding permanently Unknown and bury the genuine ones.
>
> The tree-walk cost is solved twice over: 170s → **0.025s** on this repository, and 4.06s →
> 2.73s on a 272k-file tree.
>
> Two rounds of carried-forward debt were also cleared rather than inherited by M3 (Tasks 15
> and 16): masked values no longer leak a secret's **length** to the accessibility tree, the
> Copy label resets, the unsaved-changes decision is testable and tested, and a sweep for
> CRLF-blind line splitting found **four** live bugs — including a confident *false*
> "does not list … among its recipients" accusation, and a filename-derived shell command
> that could span two lines. A standing test now fails the build on the idiom.
>
> **460 Swift tests, zero failures under both compilers on this machine** (the long-standing
> pair of wall-clock flakes was fixed by measuring bytes read instead of seconds elapsed, not
> by loosening the threshold), 153 Go tests, clean Release build, and a five-fixture round
> trip against the real `sops` CLI in which untouched values keep their exact ciphertext.

Onboarding comes first because several of its checks (§6 D, §6 C) are the natural consumers of
the project model and the key store, and writing them first pins down those interfaces before
the editing UI is built on top of them. The checks that depend on features not yet built
(Keychain, Sparkle, projects) are written against injected protocols and report *Skipped*
with a reason until their milestone lands.

---

## 10. Open Questions

1. App name (working title "SOPS GUI" — trademark-safe final name before going public)

### Answered

- **Universal binary?** No — arm64-only for v1 (2026-08-06). Adding x86_64 later is a second
  `go build` plus `lipo` in `build-xcframework.sh`.
- **In-process engine or subprocess?** In-process (2026-08-06, [ADR 0001](docs/adr/0001-in-process-go-bridge.md)).
- **v1 file formats?** YAML only (2026-08-07). The bridge's YAML path is the one verified
  byte-compatible against the CLI in both directions. Adding dotenv or JSON later is a new
  `Format` case — sops ships a store for each — not a rewrite, but each needs its own
  round-trip tests against the real CLI, which is what took the longest in M0.
- **Minimum macOS?** 26.0 (2026-08-07), matching §3 and §4's "HIG for macOS 26+ including
  Liquid Glass". The build had sat at 14.0, which was chosen only to silence linker warnings
  and contradicted the spec.
