# M2 review log

Fifteen iterative review rounds over M2 (core editing), each one reviewing the
commit the previous round produced. Every round found defects; **no round has
ever come back clean**, and eleven of the fifteen found defects in the
immediately preceding round's own fixes.

The stopping rule this was run under — three consecutive clean rounds, or
twenty rounds — is **not met**. Round 15 is where it stands.

## What kept going wrong

Three failure classes account for almost everything below.

1. **A confident statement standing over work that did not happen.** "No
   encrypted files found in this project" over a directory the scan could not
   read; "No unprotected age key file was found" over paths a failed probe
   never resolved; a health panel showing the previous run's verdicts in the
   present tense. PROPOSAL §6 D forbids exactly this and it recurred in a new
   place every round.
2. **A test that exists, is green, and guards nothing.** A fixture the code
   rejects on length so the assertion could not fail; a model-level test whose
   entire view wiring could be deleted; a test asserting against a private
   reimplementation of the fix it was named after; source-text guards defeated
   by a comment, three separate rounds, three different comment syntaxes.
3. **A report accurate about what was done and wrong about what it means.**
   Including my own: three rounds running I described a guard's design in a doc
   comment that the code did not implement.

## Verification standard used

A finding counts only if something was run: a test that fails against HEAD, a
mutation that leaves the suite green, or pasted command output. Fixes are
mutation-verified — break the thing the new test guards, watch it redden,
restore from a checksummed copy and confirm the checksum. Two restores failed
silently earlier in the series because a `cd` in a compound command moved the
working directory, which is why absolute paths and `shasum` are now the rule.

One reported finding was **rejected after checking** (round 12: a claimed
list-renumbering leak whose own pasted output showed the value in plaintext
before the save, so nothing had been protected). Everything else reproduced.

---

# M2 iterative review ledger

Stop condition: 3 consecutive clean iterations, or 20 iterations.

| Iter | Commit reviewed | Findings | Clean streak |
|---|---|---|---|
| 1 | `0f6849e` | 2 blocking + 10 | 0 |
| 2 | `21a91dc` | 3 blocking + 8 | 0 |
| 3 | `dcd11c5` | 5 blocking + 6 | 0 |
| 4 | `2315c8c` | running | — |

---

## Iteration 1 — `0f6849e`

| # | Finding | Fix |
|---|---|---|
| 1.1 | `TestEveryExportRunsInsideTheGuard` was `strings.Contains`; passed with guard deleted | Rewritten as AST rule (`1d78101`) |
| 1.2 | §6 D: four undisclosed exclusion paths; `.ok` over plaintext `sk_live_` key | `ScanLimitation` + `ScopedFinding` + `FindingSubject` (`1563442`) |
| 1.3 | External file change silently overwritten on save | `FileFingerprint` checked before `replaceItemAt` (`1d78101`) |
| 1.4 | Quit outside the app's own menu item destroyed unsaved edits | `applicationShouldTerminate` (`1d78101`) |
| 1.5 | Reveal state survived shape-changing save → exposed unrevealed secret | `rowIdentityGeneration` (`9f67c77`) |
| 1.6 | In-flight save + switch dialog: lied and lost data | `.waitForSaveInFlight` (`9f67c77`) |
| 1.7 | Padlock claimed "not encrypted" about an encrypted value | `adoptSavedDocument` re-reads `isEncrypted` (`9f67c77`) |
| 1.8 | Pasteboard not marked concealed; managers archived secrets | `ConcealedType`/`TransientType`, `.currentHostOnly` (`d7cae79`) |
| 1.9 | `bridgeCallDoesNotBlockMainActor` passed at 0.15% of required scheduling | Re-based on main-thread CPU occupancy (`d7cae79`) |
| 1.10 | CRLF guard: 12 of 13 evasions passed | Tokeniser; all 18 caught (`d7cae79`) |
| 1.11 | Import button offered a key path sops does not read | `AgeKeyFileLocations`, 3 hardcoded copies (`aec2031`) |
| 1.12 | Masked values leaked secret **length** to the AX tree | Fixed 8-bullet mask (`0a5c405`) |

## Iteration 2 — `21a91dc`

| # | Finding | Fix |
|---|---|---|
| 2.1 | Outer sidebar = third unguarded exit; also disarmed ⌘Q | Routed through `WorkspaceSwitchDecision` (`bf48988`) |
| 2.2 | `TestResultRecoversToo` still `strings.Contains` | AST rule (`bf48988`) |
| 2.3 | ThreadSanitizer-confirmed race in `concurrentMap` | `UnsafeMutableBufferPointer` (`bf48988`) |
| 2.4 | `ScanLimitation` claimed "cannot compile"; disproved | Comment rewritten to what it enforces (`bf48988`) |
| 2.5 | AST rule blind to work in the guard's argument list | Rule 5 (`019bf83`) |
| 2.6 | `err = nil` after the guard passed every rule | Rule 6 (`019bf83`) |
| 2.7–2.12 | `ProjectStore` quarantine/symlink/mode 644, clipboard normalise, quit timeout, generation breadth, hardcoded `/opt/homebrew` | Recorded as M3 items 12–17 |

## Iteration 3 — `dcd11c5`

| # | Finding | Fix |
|---|---|---|
| 3.1 | **RCE**: `core.fsmonitor` from a scanned repo executed by the health scan | `-c core.fsmonitor=` on every git call + 3 tests (`ca1083a`) |
| 3.2 | Guard test parsed `main.go` only; unguarded export in a 2nd file invisible | Parses whole package (`9a635ef`) |
| 3.3 | `recover()` in a nested goroutine returned nil; test said ok | Rules 4 & 5 + 7 fixtures (`9a635ef`) |
| 3.4 | ⌘W destroyed dirty doc **and** cleared the tracker | `windowShouldClose` → `QuitRequest` (`fa7c8be`) |
| 3.5 | ⌘N: two windows shared one tracker | `.newItem` removed (`fa7c8be`) |
| 3.6 | Disconnecting the outer-sidebar guard left 577 green | Source-level wiring tests (`fa7c8be`) |
| 3.7 | Three false doc comments (`onDisappear` ×2, `standardizedFileURL`) | Corrected against measurement (`fa7c8be`) |
| 3.8 | Stale test counts in §9 | Rewritten as timestamps (`fa7c8be`) |
| 3.9–3.12 | `!!binary` display/destruction, rule 6 top-level only, `ExternalToolCheck` `.ok`, `WorktreeResolver` canonicalisation | Recorded as M3 items 18–21 |

## Iteration 4 — `2315c8c` → fixed in `fa8dd85`

14 findings. Three were my own iteration-3 fixes.

| # | Finding | Fix |
|---|---|---|
| 4.1 | **BLOCKER** `windowShouldClose` never called — SwiftUI window already has a delegate, so `where delegate == nil` assigned 0. My iteration-3 fix was inert, and the `terminateAfterLastWindowClosed` I added with it turned silent doc loss into silent process exit | `WindowCloseGuard` forwarding proxy; verified in a real `WindowGroup` that the guard fires and `onDisappear` still runs |
| 4.2 | **BLOCKER** SIGPIPE kills the whole app; the comment claiming Foundation disables it was false | `signal(SIGPIPE, SIG_IGN)` once + 3 tests |
| 4.3 | **BLOCKER** `status = status` passed every recover rule and swallowed the panic as success | Rule 5 rejects self-assignment + fixture |
| 4.4 | **BLOCKER-lite** `OuterSidebarWiringTests` checked the name, not the setter body; gutting it left 583 green | Test asserts the setter calls `requestSectionSwitch` |
| 4.5 | Git guard-count test read one file; extraction to a sibling defeated it | Scans all of `Sources/`, counts by tool |
| 4.6 | `EncryptedFileMetadata` took the first `sops:`, `SopsMetadataShape` the last → false "missing recipient" accusation | Both take the last + agreement test |
| 4.7 | `timeout:` was not a bound — SIGTERM-ignoring child blocked forever | Escalates to SIGKILL after 2s grace |
| 4.8 | Truncated drain returned empty output as status 0 → every candidate "exposed" → false plaintext-leak `.problem` | Returns `nil`; callers already map that to `.undetermined` |

**Deferred to iteration 5 (recorded, not yet fixed):**

| # | Finding |
|---|---|
| 4.9 | `HealthReport.standard()` runs two synchronous login-shell probes on the main actor, ~95 ms each, every refresh |
| 4.10 | The ACE mitigation test was red 1 of 5 full runs — either a rare real failure or parallel-test cross-talk. Must be resolved, not left. |
| 4.11 | Remove Project persists the deletion **before** the unsaved-changes guard asks; Cancel cannot restore it |
| 4.12 | Settings › Key › Forget orphans an open dirty document — every "Save and …" path then fails |
| 4.13 | `SopsBridge` `String(cString:)` truncates at NUL; length-aware `sops_take_result`/`sops_result_len` exist and are unused |
| 4.14 | Go error text reaches UI and health findings verbatim on the save path; the never-log rule rests on the Go side alone |

**Verified clean by iteration 4:** `-c core.fsmonitor=` is complete for the three subcommands (~20 config keys tested, plus hooks, aliases, `.gitattributes`, `include.path`, `includeIf`); only 4 `CommandRunner.run` call sites and no other `Process()` in shipped code; `parser.ParseDir` discovery cannot be evaded.

## Iteration 5 — `8dc4536` → fixed in `ba84e6b`

11 findings. Three were iteration-4 fixes of mine.

| # | Finding | Fix |
|---|---|---|
| 5.1 | **BLOCKER** Network-denial gate built with `swift`, ran an `xcrun swift` artefact — 87 source files newer than the bundle it asserted over | Gate builds with `xcrun swift`; surfaced 2 GPG tests now gated on an agent-socket probe |
| 5.2 | **BLOCKER** Rule 5 rejected one literal; 7 shapes still swallowed the panic (`status = statusOK` worst) | Rule names the one right value + 9 regression cases |
| 5.3 | **HIGH** ACE guard-count test beaten 5 ways, incl. deleting `safeArguments` | Single `runGit` chokepoint; test strips comments |
| 5.4 | **HIGH** Sidebar setter test beaten by a comment above the gutted code | Comments stripped before matching |
| 5.5 | **HIGH** My iteration-4 nil-return discarded a complete stdout answer when a grandchild held stderr | Condition is stdout-only + regression test |
| 5.6 | Fourth, disagreeing copy of min macOS (14.0 vs 26.0) made the OS check unreachable | Aligned to 26.0 |
| 5.7 | Second window still constructible via window tabbing | `allowsAutomaticWindowTabbing = false` |
| 5.8 | "Guarding Settings is harmless" was false | Settings window skipped by identity |
| 5.9 | `sopsBlockLines` fix was right for a documented reason that cannot exist | Reason corrected to multi-document YAML, measured |
| 5.10 | Key accepted on 16-char prefix alone → Health `.ok` over a key that decrypts nothing | Length + Bech32 shape check, multi-key refusal, 5 tests |

**Recorded, not fixed (M3):** `ProjectSidebar` drop silently ignores `NSURL` providers; `SnapshotTool` hardcodes `age-keygen` and ignores git exit status; `Catalog` leaks a `UserDefaults` plist and an `NSWindow` per snapshot; decrypted JSON is `free()`d without `memset_s`.

**Verified clean:** no seventh exit from a dirty document — and ⌘W does not exist at all, because removing `.newItem` removed the whole File menu. `WindowCloseGuard` forwarding measured complete for value-returning methods and notifications; only type identity (`as? AppKitWindowController`) is lost. Process-wide `SIG_IGN` is safe.

## Iteration 6 — `ba84e6b` → fixed in `ca7a965`

13 findings. Two blockers were iteration-5 fixes of mine.

| # | Finding | Fix |
|---|---|---|
| 6.1 | **BLOCKER** Comment stripper handled `//` only; `/* */` restored the sidebar bug with all tests green | Binding extracted to `makeGuardedSelection`, tested by writing to it; both strippers handle block comments |
| 6.2 | **BLOCKER** Network gate cannot fail — an unconditional URLSession call in the app's only networking function still exits 0 | Header narrowed to what it establishes; gap named; deeper fix → M3 |
| 6.3 | **BLOCKER** Rule 5 checked the assignment was *written*, not that it *runs* — 6 shapes | Canonical-shape requirement + 6 regression cases |
| 6.4 | **BLOCKER** `HealthViewModel.refresh()` answered a mid-scan caller with a report built before the request | In-flight run loops again; freshness test |
| 6.5–6.13 | stderr rationale false + `ToolLocator` thread/fd leak; rule 3 covers only `*p`; "only place that runs git" untrue; tabbing action still live; Settings skip by substring could skip the main window; 655 `/tmp` dirs with real PGP keys; two Go negative tests can't tell refusal from unparsed fixture; padlock decided by regex; 7 nits | Recorded — see below |

**Recorded, not fixed:** `ToolLocator` loses stderr entirely when a grandchild holds it (+1 thread/fd per call, permanent); `rule 3` misses `payload[0]` and friends; `ToolLocator.capture` reaches git without `safeArguments`; `newWindowForTab:` still live; Settings skip is substring-based; `RealPGPFixture` never cleans up; two Go negative tests lack message assertions; padlock uses a ciphertext-shaped regex rather than the file's rules; plan item 25 names `sops_take_result`/`sops_result_len`, which do not exist.

## Iterations 7–10

| Iter | HEAD reviewed | Findings | Fixed in |
|---|---|---|---|
| 7 | `ca7a965` (self) | 3 | `c3547b1` |
| 8 | `c3547b1` (self) | 1 | `b161395` |
| 9 | `b161395` | 26 (3 blockers) | `b749e1f` |
| 10 | `b749e1f` | 10 | `8beba90` |

**7:** `readDataToEndOfFile` filled its box only at EOF → `ToolLocator` lost stderr entirely when a grandchild held it; chunked drain + `outputComplete`. Plan item 25 named C functions that do not exist.

**8:** `isInsideWorkTree` returned `Bool`, so "git says no" and "we could not read git" were one value → false "not inside a git repository". Tri-state. (First test passed with the check deleted; the discriminating case is a non-zero exit with a blocked read.)

**9:** `SecretRow.id` was not injective — NFC/NFD collide under Swift string equality while the file format sees different bytes, so **one edit wrote to two keys and destroyed the untouched secret**. Base64 of UTF-8. Plus two defects in my own iteration 7–8 fixes (`outputComplete` merging both streams; any non-zero git exit reading as "outside"). Two blockers recorded not fixed: `sops/audit` can `os.Exit` mid-save (registry is package-private); `stores.yaml.indent` reindents the whole file (needs a config path through three C exports).

**10:** the encrypt path had none of the decrypt path's guards — a pasted private key echoed in the error, `age-plugin-*` executed from `$PATH`, and an uncompilable `encrypted_regex` writing the whole file in plaintext with a valid MAC. Iteration 9's own end-to-end fixture could not fail on the bug it named. Worktree/damaged-repo stderr shapes read as a verdict. `FileListModel` dropped `rootUnreadable`. The `key-import-configured` snapshot rendered the empty state.

## Iteration 11 — `8beba90` → fixed in `e2a94a4`

14 findings, 2 blockers, both in iteration 10's fixes.

| # | Finding | Fix |
|---|---|---|
| 11.1 | **BLOCKER** The uncompilable-regex guard sat only on `Encrypt`, reachable via `sops_encrypt_yaml`, which M2 never calls — the real save path had none | `refuseUnusableEncryptionRule` on `ApplyChangesAndEncrypt` |
| 11.2 | **BLOCKER** `workTreeVerdict` branches swapped: git's canonical "not a git repository (or any of the parent directories)" read as a malfunction | Corrected; measured both stderrs (identical), `.git` existence is the discriminator; pinned against the real git binary |
| 11.3 | `FileListModel` read 1 of 5 blocking limitations → `chmod 000` on a subdirectory rendered "No encrypted files found in this project." | `ScannedTree.incompleteScanReason` off the same `blocksAffirmativeVerdict` rule; banner + narrowed empty state |
| 11.4 | `otherFormatCount` rendered only inside the has-files branch — a dotenv-only project was told nothing was there | Footnotes moved outside the branch |
| 11.5 | `AccessibilityTreeTests` 72-char fixture `importKey` rejects on length → the assertion could not fail; the comment claimed the opposite | Real generated identity + probe proving the store accepts it |
| 11.6 | A rule that compiles and matches nothing → complete metadata, valid MAC, every value cleartext, `sops --decrypt` silent | Post-condition on `Encrypt`: leaf values compared before/after `EncryptTree`. Not applied to the save path (document arrived that way) |
| 11.7 | Skipped-directory disclosure nested inside the truncation banner, which fires only at the budget cap, while `.git` is in that list on every repo | Standing footnote |
| 11.8 | `Catalog.swift` kept `try?` under a comment explaining `try?` had made a broken fixture look working | `try!` |
| 11.9 | "Obviously fake" comment untrue after 11.5 | Rewritten to say what the fixture is and why it must be real |
| 11.10 | Unreadable *parent* → `rootMissing`: `fileExists` needs `+x` on every parent and cannot say which failed | `stat` + `errno` (`ENOENT` vs `EACCES`/`EPERM`) |
| 11.11 | `rootUnreadable` documented at length, driving a distinct finding, asserted nowhere | Two tests, both self-checking against a root-user vacuous pass |
| 11.12 | Deployment target: four copies, no test; stated symptom (a linker warning) never appears in the fast loop | `DeploymentTargetTests` reads all four and requires one value |
| 11.13 | Three `if let`s in `Fixtures.swift` would render "pending changes" with none | `requireRow` throws `FixtureFailure`; `SnapshotMain`'s `try?` too |
| 11.14a | A dropped folder arriving as `NSURL` rather than `Data` was discarded in silence | Both representations read; unreadable drop alerts. Extracted as a free function — the bug was unreachable from any test inside a `private func` on a `View` |

Two new snapshots (`file-list-incomplete-scan`, `file-list-empty-partial-scan`) for states nothing had ever rendered. The `as? NSURL` branch was deleted after measuring that `as? URL` bridges it, rather than kept on assumption.

**Recorded, not fixed (M3):** 11.14b — `ProjectSidebarModel.isMissing` runs a `stat` per row inside `body`, and `buildGroups` runs up to four per project on the MainActor. Microseconds locally; seconds on an unmounted network volume, once per render. The fix is a cache with a refresh policy, which changes staleness semantics the current doc comment deliberately argues against — not a mid-review edit.

**Unexplained, not reproduced:** one full-suite run reported `SopsHealthTests` failures with no `✘` captured; three subsequent full runs and all later runs were clean.

## Iteration 12 — `1fc51e1` → fixed in `fe05ff2` + `5bf2774`

Four independent reviews. 20 findings, 3 blockers; two of the three were
regressions iteration 11 introduced.

| # | Finding | Fix |
|---|---|---|
| 12.1 | **BLOCKER** A save writes a previously-encrypted value in cleartext. `unencrypted_comment_regex` + deleting an unrelated row; MAC verifies because with `mac_only_encrypted` unset it covers plaintext leaves regardless of encryption; `sops --decrypt` exit 0 | Post-condition on `ApplyChangesAndEncrypt` comparing values before/after `EncryptTree` — by value, not path (a list removal legitimately renumbers half the tree) |
| 12.2 | **BLOCKER** Iteration 11's own save-path guard had no test; deleting the call left the Go suite green | Test against the reachable shape (`.sops.yaml` broken before the first encrypt). The corrupt-metadata shape is caught by the MAC — right refusal, wrong reason — so it is not what is asserted |
| 12.3 | **BLOCKER** `.git` discriminator looked only at the root, so a project in a subdirectory of a damaged repo got the confident false "not inside a git repository" back | Searches upward, as git does |
| 12.4 | Symlink into an unsearchable directory dropped with no `ScanLimitation` — the same `fileExists` defect fixed for the root 110 lines above, in the same function | `stat` + `errno`; `ENOENT` stays an absence |
| 12.5 | Plaintext-key-file all-clear computed from the launch environment. **This machine sets `SOPS_AGE_KEY_FILE`** | Two path variables read from the login shell, never `SOPS_AGE_KEY` |
| 12.6 | Sidebar badges "Missing" via `fileExists`, contradicting the file list beside it | `stat` + `errno` |
| 12.7 | Settings › Health showed the previous run's verdicts, present tense, no timestamp | Unconditional refresh; freshness test on the property |
| 12.8 | "That file has 2 keys in it" for a paste of one key + age-keygen's comment | Separate `.multipleLinesPasted` case; the file path counts key-shaped lines |
| 12.9 | "the key is never written to disk" compared directory *listings* — a write into the existing `projects.json` kept it green while real keys landed on disk | Compares contents |
| 12.10 | Iteration 11's three file-list tests asserted on the model; deleting the whole view wiring left 628 tests green | Six tests on the rendered accessibility tree; `AXProbe` shared |
| 12.11 | `ScrollOverflowFadeCoverageTests` beaten by a comment (fourth time for this class) | Strips comments via the existing stripper |
| 12.12 | Health snapshots rendered prose no check emits; no `.ok` project fixture carried the scope-disclosure paragraph | Findings come from a real `ProjectHealthCheck` run; fixed path, real age public key |
| 12.13 | `swift test --sanitize=thread` could not pass — a wall-clock ratio the instrumentation moves (plain 6.7–30.1%, TSan 20.3–56.0%, 3/3 red) | Ratio skipped under a sanitizer; suite now green under TSan |
| 12.14 | Drop called the model per provider, so a good folder finishing last wiped the alert | One drop, one outcome |
| 12.15 | `Encrypt` post-condition counted YAML nulls, then explained the refusal with a false sentence | Nulls exempt; message pinned by test |
| 12.16 | **Self-inflicted, same round:** the new login-shell probe sat in `KeyImportView.init`, i.e. the render path. 200 lookups: 19.8 s uncached, 0.2 s cached | Cached once per process |

Also corrected: 1c in the security report ("list renumbering moves a value out
of encryption") does **not** reproduce — its own output shows the value in
plaintext *before* the save, so nothing was ever protected. Checked before
acting on it.

**Recorded, not fixed (M3):**
- `Add` writes a new secret in cleartext when the file's rules do not cover the
  new key, with no signal in the return value. Documented behaviour, no way for
  the UI to warn.
- Decrypted plaintext survives `sops_free`: measured on this machine, ≥4 KB
  payloads survive `free()` intact (64 B–1 KB are zeroed by libmalloc's nano
  zone; 4 KB, 64 KB, 1 MB are not). Supersedes the vaguer iteration-5 entry.
- `mac_only_encrypted` leaves the plaintext half unauthenticated and the app
  presents "MAC verified" as a trust signal with no caveat.
- The two `.sops.yaml` config entry points wrap go-yaml with `%w`, so
  attacker-authored text (e.g. a duplicate-key name) reaches the UI verbatim —
  every document path routes through `describeYAMLFailure` instead.
- A `sops` key in a non-first YAML document is silently destroyed by a save.
- `capturingStandardError` dup2's process-wide fd 2 under parallel execution.
- `ToolLocatorTests`' `elapsed < 2s` measures machine load.
- `App/Info.plist` holds a fifth, committed copy of `LSMinimumSystemVersion`
  that `DeploymentTargetTests` does not read (XcodeGen regenerates it, but a
  build without `xcodegen` uses the stale one).

**Correction to a number I reported:** 628 was tests *collected*; 626 execute
under `xcrun` and 623 under swiftly, the difference being three bundle-gated
localization tests that structurally cannot run under the native build system.

## Iteration 13 — `5bf2774` → fixed in `0219926`

Four independent reviews. Iteration 12's save-path leak guard was defective in
every direction it could be.

| # | Finding | Fix |
|---|---|---|
| 13.1 | **BLOCKER** Guard captured by *path*, after the change set renumbered the tree — the one scenario its own rationale names as motivation | `exposureLedger`, captured before any mutation |
| 13.2 | **BLOCKER** Only `string` leaves protected; an int/bool/float secret went to disk in the clear | Type-tagged canonical form over every scalar |
| 13.3 | **BLOCKER** Comments never seen. sops encrypts them **and** leaves them out of the MAC, so it was invisible twice over. The `bridge.go` comment asserting "sops never encrypts them" was false | Guard walks comments; comment corrected |
| 13.4 | **BLOCKER** Login-shell probe corrupted by any profile that prints — the security all-clear was wrong again, over a real key file | Marker-delimited script; unusable shell yields nothing |
| 13.5 | A secret whose plaintext is a well-formed `ENC[…]` string read as protected | Compares the tree before/after `EncryptTree`, not the output's shape |
| 13.6 | **False refusal:** a file with the same text in one encrypted and one plaintext row could never be saved again; message named the wrong key with a false reason | Counts occurrences; exposure = more cleartext copies than the input had |
| 13.7 | The refusal was forgeable — a multi-line YAML key produced "Saved. Your changes are on disk." | `describePath` escapes control characters and bounds length |
| 13.8 | **Silent data loss:** typing into a `null` row discarded the secret and reported the save as successful | Editor sends `.string`; bridge refuses a null edit carrying a value |
| 13.9 | Symlink change recorded a limitation for every errno but `ENOENT`, so `ELOOP`/`ENOTDIR` put the warning banner on any project with a stale link | Only `EACCES`/`EPERM` |
| 13.10 | "That file has 2 keys in it" became "That file has 1 keys in it" — the number was never the defect | `.unreadableKeysFile`, its own sentence |
| 13.11 | `HealthPanelFreshnessTests` never rendered `HealthPanel`; the buggy `.task` could be restored with the suite green | Renders through `AXProbe` |
| 13.12 | `mainActorInstrumentDiscriminates` asserted absolute occupancy 0.8; under the one-process full suite a real block measured 0.55 — the test against measuring machine load was measuring machine load | Asserts discrimination between two controls |

**Rejected after checking:** nothing this round — every reported finding
reproduced. (Contrast iteration 12, where one did not.)

**Recorded, not fixed (M3):**
- `LegacyKeyFileImportOptions` counts: the empty-document editor message
  ("nothing was left out") is shown over a document whose content is comments,
  and over a state where every row is pending-removed; saving the latter
  produces `key: {}`, not an empty document.
- Removing a map's last child hides the parent row before the save, but the
  save leaves `key: {}` behind — the pending view shows a document the save
  will not produce.
- `WorktreeResolver` has no *unknown*: an unreadable `.git` is reported as "not
  a git repository", and the sidebar then states the worktree is an unrelated
  standalone repository.
- Two rows in different YAML documents render under one identical key label
  (`displayPath` drops `row.document`).
- `−`/`+` tooltips promise the action while disabled during a save.
- The login-shell cache stores a failed probe permanently (deliberate: a
  deterministic script against a deterministic shell will not start working,
  and re-probing costs ~95 ms per call).
- `handleDrop` now awaits providers sequentially; one that never completes
  hangs the whole drop.
- `isRunningUnderThreadSanitizer` does not detect AddressSanitizer.
- `hasGitDirectoryAtOrAbove` crosses mount points; git's discovery does not.

## Iteration 14 — mutation audit of the untouched suite → fixed in `1931555`

Eleven findings, every one demonstrated by breaking production code and
watching the suite stay green.

| # | Finding | Fix |
|---|---|---|
| 14.1 | A failed save could mark the document clean; 658 tests green. `QuitRequest` reads that flag, so ⌘Q would close without asking and lose the edits. Both failure branches unreached | Tests on both branches, mutation-verified |
| 14.2 | The editor could stop registering with the shared `UnsavedChangesTracker` entirely | Source guard, comments stripped |
| 14.3 | The Copy button could bypass `ClipboardClearing` — no 30 s clear, no `ConcealedType`, and Universal Clipboard carries the secret to every device on the account | Source guard + the two legitimate command-copy sites pinned |
| 14.4 | The reveal timeout's default could become thirty *minutes* with both existing tests green | Source guard on the default |
| 14.5 | Two `.enabled(if:)` opt-in tests had zero assertions and passed against a nonexistent path | `realRepositoryFindings` asserts; fails against a missing root |
| 14.6 | `ToolLocator`'s `elapsed < 2s` fired at 5.3 s under full parallelism — a load meter, on the ledger two rounds | 4 s, still below the 5 s timeout it discriminates against |
| 14.7 | **Found under TSan:** the login-shell probe can fail transiently and the cache stored that failure permanently as "no variables set" — a false security all-clear for the whole session | Caches successes only; the probe reports failure as failure |

**Recorded, not fixed:**
- `HealthReport.standard`'s wiring: three of four branches unguarded —
  `legacyKeyFilePaths`, the `ToolLocator` search paths, and the project source
  can each be neutered with the suite green. (`GitHubReleaseSource` *is*
  guarded, so the gap is precise, not blanket.)
- Six `ProjectStore`/`AtomicFileWriter` guards unguarded: the `unsafeToWrite`
  refusal, the late `refuseIfChanged`, the staging file's mode, `flush()`'s
  `F_FULLFSYNC`, the explicit permission protection, and temp-file cleanup.
- `WorktreeResolverTests.bareRepository` builds no fixture — its `git()` helper
  ignores exit status, so the test passes in 0.002 s with `git()` a no-op.
- `readingRefusesAnEmptyKey` never puts a usable identity in the environment,
  so it does not test the clause in its own name. (The property itself holds —
  checked separately.)
- `CopyFeedbackTests`, the onboarding suites, `OuterSidebarSwitchTests`,
  `ProjectSidebarModelTests` and `SecretRowViewLogicTests` were never mutated;
  nothing is claimed about them.

**Fourteen iterations, zero clean.** Every round has found something the round
before it called finished.

## Iteration 15 — `1931555` (in progress)

### UI honesty agent (done) — 6 findings

| # | Finding | Status |
|---|---|---|
| 15.1 | The wizard justifies its whole Tools step with "the snippets in **Help**" — there is no Help section anywhere; PROPOSAL puts it in M4. Same defect the file already records fixing twice for a nonexistent "Keys section" | to fix |
| 15.2 | Welcome screen: "Where something needs fixing, you get the command and run it yourself." Four reachable findings carry no command, and the whole engine category **can never** carry one by design | to fix (copy, not checks) |
| 15.3 | Tools/Engine/Security snapshot fixtures are hand-written prose no check emits — only the project findings were made real last round. Two divergences matter: the fixture drops the code's "latest **known** release" hedge, and shows the `~/.config/…` key path the code carries 20 lines of comment about *not* being read on macOS | to fix |
| 15.4 | `security.os` cannot fail: `LSMinimumSystemVersion` is 26.0 and the check's floor is 26.0. The comment claims raising 14.0→26.0 *cured* the vacuity; both are equally unreachable under a 26.0 launch floor | to fix |
| 15.5 | `appUpdateFinding` tells the user to flip "Check for engine updates" (which provably gates only `EngineFreshnessCheck`) and to install from "the About window" (which has no view). Both branches dead today, live the moment M5 lands | to fix |
| 15.6 | The Copy button wipes the clipboard after 30 s and no string in the app says so; the health/key Copy buttons share the identical "Copy" label and deliberately do *not* clear; and the secret copy is the one with no "Copied" feedback | to fix |

**Checked clean by that agent:** wizard gating against partial scans;
`EngineFreshnessCheck`'s branch statuses and its hedge; `ClipboardClearing`'s
`changeCount`+digest guard, `.currentHostOnly` and concealed markers;
`HealthFindingRow`'s pasteboard write (agent's own suspicion, tested and
withdrawn).

**Held back from editing** while three agents are still mutating the repo —
editing under them corrupted reports in two earlier rounds.

## Iteration 15 — `1931555` → fixed in `9709a6c`

Four reviews. 20 findings.

| # | Finding | Fix |
|---|---|---|
| 15.7 | **The security all-clear was still wrong, for a third distinct reason.** Round 13 taught the probe to signal failure, round 14 stopped the cache remembering it — and `cachedLoginShellPathVariables()` then mapped the failure back to `[:]` before anything saw it. Verified end to end against a hanging shell: same machine, same plaintext key file, opposite verdict | `resolved()` carries the failure out; the `.unknown` branch that already existed in `SecurityPostureCheck` is finally reachable |
| 15.8 | The probe marker was a fixed constant and `range(of:)` takes the first match, so a `.zprofile` printing it took over every field (real zsh, decoy paths returned) | Per-invocation nonce |
| 15.9 | The noisy-shell test built its own `Process`, script and marker-strip — deleting the whole marker mechanism from production left 26 tests green | Calls `readFromLoginShell`; the mutation now reddens two tests |
| 15.10 | "a failed probe is not cached" never touched the cache; reverting the successes-only rule stayed green | Injectable `Storage`; the mutation reddens three assertions |
| 15.11 | My own first version of the noisy-shell test used process-wide `setenv`, leaking into every parallel suite | `CommandRunner.run` takes an `environment:` for the child |
| 15.12 | `ToolLocatorTests` sets `SHELL` process-wide to a nonexistent path, so any sibling reading `$SHELL` reads whichever test wrote last | These tests name their shell |
| 15.13 | The probe's 3 s timeout is reachable under the suite's own parallelism, and a timed-out probe is not a pass | 10 s; a probe that still cannot finish records the run inconclusive |

**Recorded, not fixed** — this is where a sixteenth round starts:

- **Round 14's source-text guards are unsound.** `String.contains` over source
  text is neither necessary nor sufficient for a call happening at a site: six
  bypasses demonstrated (helper in another file plus a decoy literal, `#if
  false`, `#if <undefined>`, an inline raw write via a typealias), and one
  false *failure* (an innocent `"/*"` literal blanks the rest of the file,
  because `strippingComments` has no string-literal awareness). Concretely: a
  **30-minute reveal timeout still ships** with all three tests green, and the
  editor's Copy button can still bypass `ClipboardClearing` — losing the 30 s
  clear, the `ConcealedType` marker and `.currentHostOnly`, which puts a
  decrypted secret on Universal Clipboard. The available fix is behavioural:
  inject the pasteboard writer, or have `ClipboardClearing` record copies, and
  assert the button's action produced one.
- `realRepositoryFindings` passes against an empty directory — `!findings.isEmpty`
  counts checks, not problems.
- The 4 s `ToolLocator` ceiling absorbs a 200× poll regression (`usleep`
  20 ms → 3 s still passes).
- The probe's failure path re-spawns a login shell per call, synchronously,
  under a global lock, on the main actor: 3.1 s blocked, 9.4 s for three
  concurrent callers.
- The onboarding wizard justifies its whole Tools step with "the snippets in
  **Help**" — there is no Help section; PROPOSAL puts it in M4. The welcome
  screen promises "you get the command and run it yourself" while four
  reachable findings carry no command and the engine category never can.
- `security.os` cannot fail: `LSMinimumSystemVersion` and the check's floor are
  both 26.0, and the comment claims raising 14.0 → 26.0 *cured* that vacuity.
- The Tools/Engine/Security snapshot fixtures render prose no check emits —
  including dropping the code's "latest **known** release" hedge and showing
  the `~/.config/…` key path the code documents as one sops does not read on
  macOS.
- `appUpdateFinding` points at a Settings toggle that provably gates only
  `EngineFreshnessCheck`, and at an About window with no view. Dead today, live
  when M5 lands.
- The Copy button clears the clipboard after 30 s and no string in the app says
  so; the health and key-import Copy buttons share the identical label and
  deliberately do not clear.
- From round 14, still open: `HealthReport.standard`'s wiring (three of four
  branches can be neutered with the suite green), six `ProjectStore` /
  `AtomicFileWriter` durability and permission guards, and
  `WorktreeResolverTests`' `git()` helper ignoring exit status so
  `bareRepository` builds no fixture at all.

### Round 15, remaining reviews — fixed in `db331a5`

Three defects that destroyed data, all reproduced before being touched.

| # | Finding | Fix |
|---|---|---|
| 15.14 | **A save could overwrite an arbitrary file outside the repository and report success.** `load()` fingerprints and reads in two syscalls; `FileFingerprint.of` is `nil` for a dangling symlink; `refuseIfChanged` returns immediately with nothing to compare; the writer resolves symlinks. Reproduced overwriting a file outside the repo with ciphertext while the real document went unchanged — 20–28% of loads under a flipping symlink | Refused at the caller. Tightening the writer instead reddened eight tests: `expecting: nil` is legitimate there (writing through a symlink, creating a new file) |
| 15.15 | **One NUL byte truncated the document and the next save deleted the rest, permanently.** Two complete SOPS documents joined by a NUL opened showing only the first; saving wrote back what was shown. The real `sops` CLI refuses the same file, so this was also a read-direction divergence from the CLI ADR 0001 requires round-tripping with | Refused until the boundary is length-prefixed |
| 15.16 | **A symlink to a FIFO hung the scan forever** — `tailBytes` does `open(O_RDONLY)` with no `O_NONBLOCK` and no timeout, inside `concurrentPerform` where cancellation cannot reach it | Only a regular-file target is followed |

**Also recorded from those reviews, not fixed** — beyond the list above:

- The `exposureLedger` counting rule **refuses legitimate saves**: any save that
  adds a plaintext copy of a value encrypted elsewhere fires it, which for
  `true`/`0`/`1` in a config file is near-certain. A file with one encrypted
  `true` means no plaintext boolean in it can ever be set to `true`. Narrowed
  from round 13, not removed.
- `snapshotBeforeEncrypting` — round 13's headline redesign — has **no
  observable effect**: two independent mutations survived all ten tests the
  round added, because an encrypted node's canonical form is its ciphertext and
  never matches a plaintext secret name.
- `describePath` escapes only `< 0x20` and `0x7f`, so U+2028/U+2029/U+0085 still
  break the refusal into a forged paragraph (measured through real CoreText).
  Its 120 bound counts **bytes**, and escape expansion produces a 723-byte
  message — past the test's own 400-byte threshold, which the test never sees
  because it only uses ASCII.
- The refusal names one key per canonical value, so with two keys holding one
  secret the user fixes one and ships the other.
- Duplicate keys in YAML document 1+ are accepted (sops's uniqueness check runs
  on document 0 only), the editor shows a value the key does not hold, and the
  file becomes permanently unsaveable. The real `sops` CLI produces such files.
- Opening a file is **quadratic in keys within one mapping** — 100 000 keys in
  one map is 53 s of parse, on every load and every save, ~13× the file size in
  RSS with plaintext in the heap. Attributed precisely to sops's
  `LoadPlainFile` doing an extra whole decode for a uniqueness check.
- `Encrypted: true` is decided by a regex over the value text rather than by the
  file's rules, so a plaintext value shaped like ciphertext is badged encrypted.
- The scan budget counts files, not directories: 25 000 directories reports
  `wasTruncated = false`.
- `replaceItemAt` — not the writer's `chmod` — decides the final mode of the
  secrets file, contradicting the comment above it.

## Where it stands

`swift test` 685 collected at the last full run (626/623
executed — the difference is bundle-gated localization tests that structurally
cannot run under the native build system), green under ThreadSanitizer, Go
green, 38/38 snapshots.

**M2 has no ✅.** It was awarded once, withdrawn, and has been withheld since.
Fifteen rounds in, the honest summary is that each round makes the next one's
findings narrower, and none has yet made them stop.
