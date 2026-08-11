# Recipient Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Spravovat pojmenované age recipients a bezpečně synchronizovat SOPS access u souboru i projektu.

**Architecture:** Go bridge provede in-memory variantu SOPS `updatekeys`; Swift drží project-scoped registry a orchestruje atomické file/project writes. UI pouze připravuje změny, final apply vždy vyžaduje explicitní confirmation.

**Tech Stack:** Swift 6/SwiftUI, Go 1.26, getsops/sops v3.13.3, Swift Testing.

## Global Constraints

- Jen native `age1...` X25519; žádný CLI, environment, key files ani pluginy.
- Private identities ani plaintext hodnoty se nelogují, neukládají ani nevrací v errors.
- `.sops.yaml` je access/config autorita; `.sops-gui/recipients.json` je verzovaný adresář labels.
- Existing writes zůstávají atomické (staged file + `renameat`) a odmítnou zápis,
  pokud se cílový soubor od načtení změnil. Ochrana je best-effort — stejný
  kontrakt jako `AtomicFileWriter`: mezi fingerprint checkem a `renameat` je
  mikro-window, ve kterém ne-kooperující externí writer (`git`, `sops` CLI,
  druhá instance appky) může výsledek přepsat. macOS nenabízí CAS přes directory
  entry; advisory lock by nechránil `git` ani CLI, takže se nepřidává.

---

### Task 1: Bridge recipient metadata a rewrap

**Files:** `Engine/gobridge/recipients.go`, `Engine/gobridge/recipients_test.go`, `Engine/cshim/main.go`, `Engine/gobridge/bridge.go`, `Packages/SopsGUIKit/Sources/SopsEngine/SopsBridge.swift`.

**Produces:** `Recipients(encrypted) ([]string,error)` a `UpdateRecipients(encrypted, recipients, agePrivateKey) ([]byte,error)`; Swift `SopsBridge.recipients(in:)` a `updateRecipients(_:to:agePrivateKey:)`.

- [ ] Napiš failing Go test: dva validní recipients decryptnou rewrapped document, odebraný ne.
- [ ] Spusť `go test ./gobridge -run TestUpdateRecipients`; očekávej fail.
- [ ] Implementuj: `loadAndDecrypt`, replace jediného age `Metadata.KeyGroups`, `UpdateMasterKeysWithKeyServices(dataKey, ks.clients())`, `store.EmitEncryptedFile`.
- [ ] Odmítni prázdný set, private/plugin/invalid recipient; chyby jsou fixed text.
- [ ] Exportuj C entry points a Swift JSON/string boundary; proveď `go test ./...` a `swift test --filter SopsEngineTests`.
- [ ] Commit: `feat(engine): support explicit recipient rewrap`.

### Task 2: Project recipient registry

**Files:** `Packages/SopsGUIKit/Sources/SopsProjects/RecipientRegistry.swift`, `Packages/SopsGUIKit/Tests/SopsProjectsTests/RecipientRegistryTests.swift`.

**Produces:** `RecipientRecord(id: UUID, label: String, kind: RecipientKind, ageRecipient: String, note: String?)`, `RecipientRegistry.load/save/upsert/remove`.

- [ ] Napiš failing tests pro JSON round-trip, duplicate public key, invalid `age1...` a atomic save.
- [ ] Implementuj registry v `.sops-gui/recipients.json`; validuj label nonempty, registry nikdy neukládá private shape.
- [ ] Spusť `swift test --filter RecipientRegistryTests`; commit `feat(projects): add shared recipient registry`.

### Task 3: File access model a UI

**Files:** `Packages/SopsGUIKit/Sources/SopsUI/Editor/RecipientAccessModel.swift`, `RecipientAccessView.swift`, `SecretEditorView.swift`, `LocalizedKey.swift`, `Localizable.xcstrings`, `Tests/SopsUITests/RecipientAccessTests.swift`.

**Produces:** toolbar Access; staged add/remove, registry label fallback na public key, apply/cancel state.

- [ ] Napiš UI/model test: staged edit nic nezapisuje; Apply calls only `updateRecipients`.
- [ ] Implementuj async model přes `SessionKeyStore.withKey`; po success reload document, clear staged state.
- [ ] Přidej destructive dialog pro removals a error/progress accessibility labels.
- [ ] Spusť cílené UI tests; commit `feat(ui): manage recipients for open file`.

### Task 4: Config a project-wide apply

**Files:** `Engine/gobridge/configwrite.go`, `Packages/SopsGUIKit/Sources/SopsProjects/ProjectRecipientApplier.swift`, `Packages/SopsGUIKit/Sources/SopsUI/Projects/ProjectAccessView.swift`, související testy.

**Produces:** preview matched files; explicit config update; ordered per-file results (`updated`, `unchanged`, `failed`).

- [ ] Napiš failing test: one inaccessible/malformed file neblokuje ostatní a config se nemění bez confirmation.
- [ ] Implementuj config rewrite přes Go YAML AST, zachovej unrelated rules; jen flat age-only rule, unsupported shapes read-only.
- [ ] Implementuj scanner-driven apply, fingerprint při zápisu, cancellation mezi soubory.
- [ ] Spusť project/UI suites; commit `feat(projects): sync recipients across project`.

### Task 5: Release verification

**Files:** release version files + release notes podle `release.conf`.

- [ ] Spusť `go test ./...`, `swift test --package-path Packages/SopsGUIKit` a Xcode archive/test.
- [ ] Zkontroluj registry/config test fixtures bez secrets, `git diff --check`, snapshots relevantních UI stavů.
- [ ] Commit release version, push `master`, spusť `release <verze>` pouze po green checks; ověř appcast a GitHub assets.

## Self-review

Spec coverage: registry (Task 2), file updatekeys (1+3), config+bulk (4), destructive confirmation (3+4), safety (1–4), release (5). Názvy rozhraní jsou definované v produkujících tasks.
