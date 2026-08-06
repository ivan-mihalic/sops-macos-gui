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

**First implementation step is a spike of the Go bridge** — encrypt/decrypt round-trip
verified byte-compatible with the `sops` CLI. If the spike fails, fall back to subprocess.

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

## 6. Build, Signing & Release

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

## 7. DX Extras (proposed — beyond agreed scope)

Ranked by value/effort; ✦ = recommended for v1:

- ✦ **Encrypted-file diff view** — human-readable diff of two versions of an encrypted file (git HEAD vs working copy); solves the worst sops papercut
- ✦ **Health check per project** — MAC valid, every declared recipient can decrypt every file, `.sops.yaml` rules match actual files, warn on files encrypted to stale keys
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

## 8. Milestones

| # | Milestone | Content |
|---|---|---|
| M0 | **Spike** | Go xcframework bridge; CLI-compatibility round-trip proof. Go/no-go for in-process vs subprocess |
| M1 | Core editing | Project add (incl. worktrees), file list, form editor, encrypt/decrypt, atomic save |
| M2 | Keys & security | Keychain + Touch ID, session TTL, key generate/import/reveal, clipboard hygiene |
| M3 | Recipients & help | `.sops.yaml` editing, updatekeys, recipient add/remove + rotate reminder, Help section with snippets |
| M4 | Polish & release | Sidebar/About/Settings final, Liquid Glass pass, Sparkle, notarized release pipeline, first public release → **repo goes public** |
| M5 | DX extras | Items from §7 by priority |

---

## 9. Open Questions

1. App name (working title "SOPS GUI" — trademark-safe final name before going public)
2. v1 file formats: YAML only, or YAML + dotenv + JSON from the start?
3. Universal binary (arm64 + x86_64) or arm64-only for v1?
4. Minimum deployment target strictly macOS 26, or 15+ with graceful degradation of Liquid Glass?
