# Task 3 report — File access model and UI

## Status

Complete.

## What was built

- `Packages/SopsGUIKit/Sources/SopsUI/Editor/RecipientAccessModel.swift` —
  `@MainActor @Observable final class RecipientAccessModel`. Reads a file's
  native age recipient metadata via `SopsBridge.recipients(in:)` (no session
  key needed), optionally attaches labels from `RecipientRegistry` for a
  given `projectURL`, and holds a purely in-memory staged working set
  (`stagedRecipients`) that `stageAdd`/`stageRemove`/`discardStagedChanges`
  mutate. `apply()` is the only method that calls
  `SopsBridge.updateRecipients` — it re-wraps the data key with the session
  key (`SessionKeyStore.withKey`), writes atomically via the same
  `AtomicFileWriter`/`FileFingerprint` second-writer guard
  `SecretDocumentViewModel.save()` uses, and only then adopts the staged set
  as `currentRecipients`. It refuses, before touching the bridge or the file,
  when the staged set is empty (`.refusedEmptyRecipients`) or no key is
  configured (`.refusedNoKey`). `AccessEntry`/`entries` never drop a
  recipient absent from the registry — it falls back to showing the raw
  `age1…` public key.
- `Packages/SopsGUIKit/Sources/SopsUI/Editor/RecipientAccessView.swift` — the
  sheet: entry list (label or raw key, staged-status badges, per-row
  add/undo/remove toggle), an add-by-pasting-a-key field, a destructive
  confirmation dialog before any Apply that would remove a recipient
  (naming who loses access), an error alert for `.failed`/refusal outcomes,
  and a progress indicator with an `.accessibilityLabel` while `apply()` is
  in flight. The needs-key case is explained inline rather than failing
  obscurely — reading still works without a key.
- `Packages/SopsGUIKit/Sources/SopsUI/Editor/SecretEditorView.swift` — added
  an optional `RecipientAccessContext` (file URL, key store, project URL)
  and an optional `recipientAccess:` init parameter (default `nil`, so no
  existing call site needed to change), a toolbar "Access" button that
  builds a fresh `RecipientAccessModel` when pressed, and a
  `.sheet(item:)` presenting `RecipientAccessView`. On a successful apply,
  the callback reloads the open `SecretDocumentViewModel` (`viewModel.load()`)
  so its own save-time fingerprint resyncs with the rewrapped file — a
  rewrap changes the file's bytes even though it never touches row values.
- `Packages/SopsGUIKit/Sources/SopsUI/AppShell.swift` — wired
  `ProjectWorkspaceView.editorPane` to actually supply
  `SecretEditorView.RecipientAccessContext` (the selected file URL, the
  shared `keyStore`, and a new `activeProjectRootURL` computed from the
  active project) so the feature is reachable in the shipped app. Not named
  in the brief's file list, but required for a real user to reach the
  feature; touched nothing else.
- `Packages/SopsGUIKit/Sources/SopsUI/LocalizedKey.swift` /
  `Resources/Localizable.xcstrings` — 17 new keys under "Task 3 (recipient
  management) — file access panel" (toolbar button, sheet title, add field,
  duplicate/empty-set/no-key explanations, destructive-confirm title/message/
  button, pending-removal/addition badges, per-row a11y labels, apply-error
  title). `LocalizationTests` (165 keys total now) passes.
- `Packages/SopsGUIKit/Tests/SopsUITests/RecipientAccessTests.swift` — 8
  tests across 3 suites, all against real in-process bridge crypto
  (`SopsBridge.encryptYAML`/`decryptYAML`, real `age-keygen` identities, no
  hand-written ciphertext).

## Deliberate scope decision: `SecretEditorView`'s new params are optional

The brief lists only `SecretEditorView.swift` as a file to touch, but wiring
the Access button through to real usage requires the file URL, the session
key store, and (for labels) the project URL to reach the view. Rather than
making these required parameters — which would have forced changes to all
~18 other `SecretEditorView(...)` call sites across `AppShell.swift`,
`SnapshotTool/Catalog.swift`, `SnapshotTool/Guide.swift`,
`AccessibilityTreeTests.swift`, and `RevealedRowTests.swift` — I added one
optional `recipientAccess: RecipientAccessContext?` parameter defaulting to
`nil`. Every pre-existing call site compiles and behaves exactly as before
(Access button simply does not render); only `AppShell.swift`, which is the
one place the feature needs to be real, was updated. This kept the change
surface to what the brief named plus the one integration point needed to
make the feature reachable, and avoided a 20-file mechanical edit for no
behavioral gain in tests/snapshots that don't exercise this feature.

## Deliberate scope decision: `RecipientAccessModel` re-reads/re-writes the file independently

`RecipientAccessModel` does not reach into `SecretDocumentViewModel`'s
private `encryptedContents`/`loadedFingerprint`. It has its own
read/fingerprint/write cycle, mirroring `SecretDocumentViewModel.load()`/
`save()`'s exact discipline (fingerprint-before-read, NUL-boundary guard,
`AtomicFileWriter` with `expecting:`). This means the two models never share
mutable state and can't develop an ordering bug between them; the cost is
that after a successful apply, `SecretEditorView` explicitly calls
`viewModel.load()` to resync the document view model's own fingerprint.
This mirrors the existing project convention of each type holding exactly
what it needs (e.g. `fileName` is already handed to `SecretEditorView`
rather than derived from `viewModel`).

## TDD RED evidence

Wrote `RecipientAccessTests.swift` first, referencing `RecipientAccessModel`
before it existed. `swift build --build-tests` (Xcode toolchain,
swift-frontend 6.4.0.27.1) failed with the expected error at every call
site:

```
RecipientAccessTests.swift:182:21: error: cannot find 'RecipientAccessModel' in scope
RecipientAccessTests.swift:205:24: error: cannot find 'RecipientAccessModel' in scope
RecipientAccessTests.swift:219:21: error: cannot find 'RecipientAccessModel' in scope
RecipientAccessTests.swift:243:21: error: cannot find 'RecipientAccessModel' in scope
RecipientAccessTests.swift:284:21: error: cannot find 'RecipientAccessModel' in scope
RecipientAccessTests.swift:304:21: error: cannot find 'RecipientAccessModel' in scope
error: Build failed
```

After implementing `RecipientAccessModel.swift`, one test failed for a real
reason (not implementation): `apply rewraps to exactly the staged set and
persists atomically` failed decrypting the re-wrapped file back to
`plainYAML`. Root cause: sops's own YAML emitter normalizes indentation to 4
spaces regardless of the input, and my fixture's `plainYAML` used 2-space
indent, so the round-tripped plaintext differed from the fixture only in
indentation — not a model defect. Fixed by using the same 4-space canonical
form `Tests/SopsEngineTests/CompatibilityTests.swift` already uses for
exactly this reason. After that fix, all 8 tests passed on first run.

## Test commands and output

**Xcode toolchain** (`swift` resolves through `PATH` to
`/usr/bin/swift` → `/Applications/Xcode-27.0.0-Beta.4.app` toolchain, Apple
Swift 6.4.0.27.1, swift-frontend `swiftlang-6.4.0.27.1`) — confirmed via
`which -a swift` / `swift --version`; `PATH` on this machine currently puts
`/usr/bin` ahead of `~/.swiftly/bin`, the inverse of what CLAUDE.md warns is
typical, so both toolchains had to be resolved explicitly rather than
assumed from `swift`/`xcrun swift`:

```
$ swift test --filter RecipientAccess
✔ Test run with 8 tests in 3 suites passed after 0.669 seconds.

$ swift test --filter SopsUITests
✔ Test run with 297 tests in 57 suites passed after 10.592 seconds.

$ swift test   # all 4 targets
✔ Test run with 297 tests in 57 suites passed after 10.592 seconds.  (SopsUITests)
✔ Test run with 101 tests in 7 suites passed after 0.598 seconds.    (SopsProjectsTests)
✔ Test run with 271 tests in 46 suites passed after 32.068 seconds.  (SopsHealthTests)
✔ Test run with 74 tests in 13 suites passed after 5.147 seconds.    (SopsEngineTests)
```

743/743 across all four test targets, zero failures.

**Swiftly-managed toolchain** (`~/.swiftly/bin/swift`, Apple Swift 6.3.3
`swift-6.3.3-RELEASE`, `swift-testing` library 6.3.3):

```
$ ~/.swiftly/bin/swift test --filter RecipientAccess
✔ Test run with 8 tests in 3 suites passed after 0.533 seconds.

$ ~/.swiftly/bin/swift test --filter SopsUITests
✘ Test run with 297 tests in 57 suites failed after 10.517 seconds with 1 issue.
  — sole failure: "the Add Project control fills the sidebar footer"
    (FirstRunWindowAndSummaryTests.swift:398), an unrelated, pre-existing,
    environment-dependent test. Verified pre-existing by checking out HEAD
    (d9b7bc6, before this task's changes) into a throwaway `git worktree`
    at /tmp/rm-baseline-check and running the same test under the same
    toolchain: it fails there too, for the same reason
    ("no Add Project button in the rendered tree") — CLAUDE.md's documented
    hazard that `swift test`'s native (llbuild) build system does not
    compile `Localizable.xcstrings`, so a layout assertion keyed to resolved
    English button width is toolchain/build-system-dependent, unrelated to
    recipient management. The diagnostic worktree was removed after use
    (`git worktree remove /tmp/rm-baseline-check --force`).

$ ~/.swiftly/bin/swift test --filter SopsProjectsTests
✔ Test run with 101 tests in 7 suites passed after 0.619 seconds.

$ ~/.swiftly/bin/swift test --filter SopsEngineTests
✔ Test run with 74 tests in 13 suites passed after 5.317 seconds.
```

296/297 + 101/101 + 74/74 = 471/472, the sole non-pass being the
pre-existing, unrelated flake confirmed above.

## Housekeeping

- `git diff --check`: passed, no whitespace errors.
- `$TMPDIR` after the full session: 2.1G (healthy baseline, unrelated to
  this task — this machine's own churn from other sessions). No leftover
  `recipient-access-*`/`recipient-access-project-*` directories from this
  task's tests (`find "$TMPDIR" -maxdepth 1 -iname "*recipient-access*"`
  returns nothing) — the test file's `scratchDirectory()` helper registers
  every directory with `ScratchDirectoryRegistry.shared`, which deletes them
  when the test process exits, consistent with the project's fixed-on
  2026-08-10 discipline.

## Concerns / things I was unsure about

- **Add-by-paste vs. pick-from-registry.** The Access sheet lets a user
  stage an addition only by pasting a raw `age1…` key; it does not offer a
  picker over existing registry entries not currently in the file, nor does
  it let the user create a new registry entry from this sheet. The brief's
  scope line is "staged add/remove; registry label fallback to public key,"
  which I read as "the registry supplies labels for display" rather than "the
  registry is edited or browsed from here" — registry authoring already has
  its own surface (Task 2's `RecipientRegistry.upsert`), and nothing in the
  brief or the design spec names a picker for this task. If a picker/"add
  from registry" affordance was expected here, that's a gap I'd want
  confirmed rather than assumed.
- **No new snapshot-catalog entries.** `CLAUDE.md`'s snapshot discipline says
  adding a view means adding a `Snapshot` to `Catalog.swift`, but the brief's
  file list doesn't include `SnapshotTool`, and this task's own required
  tests (`RecipientAccessTests.swift`) already exercise the model
  end-to-end with real crypto. I left the visual catalog untouched to keep
  the change scoped to the brief; happy to add snapshot entries if wanted
  for future visual review.
- **`stageAdd` validates only shape-free non-emptiness/duplication**, not
  that the pasted text is actually a valid native age recipient — that
  check is deferred to `apply()`, where `SopsBridge.updateRecipients`
  is the authority (per the brief's stated bridge guarantee: it "rejects...
  invalid recipients"). This mirrors `SecretDocumentViewModel.refusalForAdding`'s
  own division of labor (view-level check for the obviously wrong case, bridge
  as final authority) but means a badly-pasted key only surfaces its
  specific rejection reason at Apply time, inside the generic `.failed(String)`
  path, not as a dedicated `StageAddRefusal` case. I judged this acceptable
  given the interface note that `updateRecipients` "rejects... invalid
  recipients" with fixed, non-secret text, so the error the user sees is
  still honest and specific — just one step later than it could be.

---

# Fix round 1/5 — response to independent review of `4216abd`

Three findings against `4216abd`: one Critical (C1), two Important (I2, I3).
All three addressed.

## C1 — Applying access changes silently discarded unsaved secret edits

**Root cause confirmed exactly as reported.** The toolbar's Access button was
disabled only on `viewModel.loadState != .loaded || isSaving`, never on
`viewModel.isDirty`. A successful apply's `onApplied` callback calls
`viewModel.load()` to resync the document's save-fingerprint with the
rewrapped bytes, and `load()` → `adoptBaseline` → `discardPendingChanges()`
silently wipes every pending edit/addition/removal and clears `isDirty`.

**Fix.** Took the reviewer's first suggested fix: gate Access on
`!viewModel.isDirty`. Pulled the decision out as a pure, directly-testable
static function — `SecretEditorView.canOpenAccessPanel(loadState:isDirty:
isSaving:)` — mirroring this module's existing `WorkspaceSwitchDecision`/
`QuitRequest` pattern rather than inlining a boolean expression nobody could
unit test. The toolbar button's `.disabled`/`.help` now read from it, and the
disabled state explains itself via a new localized key,
`access.disabled-unsaved-changes` ("Save your changes before managing
access."), instead of looking identical to the enabled state.

Files: `Packages/SopsGUIKit/Sources/SopsUI/Editor/SecretEditorView.swift`,
`Packages/SopsGUIKit/Sources/SopsUI/LocalizedKey.swift`,
`Packages/SopsGUIKit/Sources/SopsUI/Resources/Localizable.xcstrings`.

**RED evidence.** Wrote `AccessButtonWiringTests
.theAccessButtonIsUnreachableWhileTheDocumentIsDirty` (new file
`RecipientAccessGatingTests.swift`) first, against a temporarily-reverted
gate (`viewModel.loadState == .loaded && !isSaving`, the exact pre-fix
condition). It failed for the right reason:

```
✘ Test "the Access button explains itself as unavailable while the document has unsaved edits"
  recorded an issue: Expectation failed: accessButton?.help == LocalizedKey.accessDisabledUnsavedChanges.text
  accessButton?.help → "Access"
  LocalizedKey.accessDisabledUnsavedChanges.text → "Save your changes before managing access."
```

i.e. a dirty document rendered the Access button with the ordinary, enabled
help text — reachable — exactly the defect. Restored the fix
(`Self.canOpenAccessPanel(...)`), re-ran: passed. Also added
`CanOpenAccessPanelTests` (6 tests) unit-testing the pure function directly
(clean/idle, dirty, saving, every non-`.loaded` state, dirty+saving
together) and `theAccessButtonIsReachableWhenClean` proving the fix isn't
"always disabled."

## I2 — `isDirty` was order-sensitive; the row's own Undo control reordered it, leaving Apply enabled for a no-op write

**Root cause confirmed exactly as reported**, including that the removed
doc comment's own rationale was false for the row toggle's exact undo
sequence (`stageRemove` then `stageAdd` the same recipient — what
`RecipientAccessRow`'s button does for a `.pendingRemoval` row).

**Fix.** `isDirty` now compares `Set(stagedRecipients) != Set(currentRecipients)`
instead of array inequality. Rewrote the doc comment to state the true
property and name the false claim it replaces, rather than leaving a
misleading rationale in place (reviewer's explicit ask: "fix the comment
along with the logic").

File: `Packages/SopsGUIKit/Sources/SopsUI/Editor/RecipientAccessModel.swift`.

**RED evidence.** Added
`RecipientAccessStagingTests.removeThenReAddViaUndoIsNotDirty` (exercises
`stageRemove(owner)` then `stageAdd(owner)` — same sequence the row's undo
performs), watched it fail against the pre-fix array comparison (reverted
`isDirty` to `stagedRecipients != currentRecipients` for the RED run, then
restored):

```
✘ Test "removing a recipient and then re-adding it — the row toggle's undo — leaves the document clean"
  failed after 0.136 seconds with 2 issues.
```

Two issues, both the ones the finding predicts: `!isDirty` failed, and —
because the test also calls `apply()` on the resulting state and checks the
file's bytes are untouched — a real `updateRecipients` rewrap and disk
write actually happened for the no-op change (the second issue). Restored
the `Set`-based fix: both assertions pass. Also added
`RecipientAccessPendingRemovalsTests.reportsExactlyStagedRemovals`, which
independently confirms `pendingRemovals` (the destructive-dialog gate) is
correctly empty for the undo case even before the `isDirty` fix — that
specific gate was never wrong; only `isDirty` was.

## I3 — Coverage stopped at the model's happy paths; the four injectable seams and the view were entirely untested

Agreed with the finding as stated. Added:

**Model-level, in `RecipientAccessTests.swift`** (new suite
`RecipientAccessSeamTests`, plus additions to existing suites):

- `applyCallsTheRewrapSeamExactlyOnceWithTheStagedSet` — proves "apply calls
  only `updateRecipients`" **directly** rather than by inference. This
  required a structural change: `rewrapRecipients` used to be called from
  inside a background `Thread` (`runOffCooperativePool`), which would have
  made a test's spy closure need `@Sendable`-safe locking to capture calls.
  Restructured so the seam itself is `async` and MainActor-callable — only
  the *default* implementation (`RecipientAccessModel.defaultRewrap`) hops
  off the main actor internally — so a test's substitute can just be a plain
  closure capturing a local `var`, no locks needed. (This also deleted the
  now-unnecessary private `Outcome` enum, since `apply()` now uses
  `SessionKeyStore.withKey`'s `rethrows` directly.)
- `applyIsANoOpWhenNothingIsStagedAndSkipsBothSeams` — counts `rewrapRecipients`
  and `writeFile` calls, asserts both are 0 for a no-op apply.
- `bridgeFailureLeavesRecipientsUntouched` — injects a `rewrapRecipients`
  that throws; asserts `.failed`, the write seam is never reached,
  `currentRecipients`/`stagedRecipients`/`loadState` are all untouched.
- `writeFailureLeavesRecipientsUntouched` — injects `writeFile` throwing
  `AtomicFileWriter.Error.destinationChangedOnDisk` directly (deterministic,
  no real disk race needed); asserts the same preservation guarantee and
  that the message names what happened.
- `aRealConcurrentWriterIsRefusedWithoutClobbering` — the real-external-writer
  counterpart: the actual `sops set` CLI modifies the fixture file between
  `load()` and `apply()` (mirrors `SecretDocumentViewModelTests
  .externalChangeIsRefusedNotClobbered` for the editor's own save path).
  Proves the *default* `writeFile` (real `AtomicFileWriter`) refuses for
  real, not just that an injected error is handled.
- `readFailureSurfacesAsFailedLoad` — injects `readFile` throwing; asserts
  `.failed` with no crash and an empty document, no real file needed.
- `customLoadRegistrySeamSuppliesLabels` — injects `loadRegistry` returning
  canned records unrelated to the real `RecipientRegistry`; proves the seam,
  not just the real registry path already covered elsewhere, drives labels.
- `stageAddBeforeLoadIsRefused` — `.notLoaded`, previously unexercised.
- `RecipientAccessPendingRemovalsTests.reportsExactlyStagedRemovals` —
  direct assertions on `pendingRemovals`, previously never asserted anywhere
  despite gating the destructive dialog.

**View-level, in new file `RecipientAccessGatingTests.swift`** (using this
module's existing precedent: `AccessibilityTreeTests`' reflective `AXProbe`
technique, duplicated per-file the same way `RevealedRowTests` already
duplicates it; and `QuitRequestTests`/`WorkspaceSwitchDecisionTests`' "pull
the decision into a pure function, test that, and state plainly what the
`.confirmationDialog` itself is unreachable to unit test" pattern — a
`.confirmationDialog` is documented in this codebase, correctly, as
untestable outside a launched app):

- `CanOpenAccessPanelTests` (6 tests) — the C1 gate, pure-function level.
- `CanApplyTests` (5 tests) — the Apply button's gate
  (`RecipientAccessView.canApply`, also newly extracted as a pure, testable
  function, same pattern as C1's fix).
- `AccessButtonWiringTests` (2 tests) — the C1 regression, through a real
  rendered `SecretEditorView`.
- `RecipientAccessRowLabelTests.rowLabelMatchesStatus` — renders a real
  `RecipientAccessView` and asserts the per-row toggle button's
  accessibility label switches between "Remove this recipient" and "Keep
  this recipient" for the correct row status. Needed a small addition to the
  AX-probe technique: `RecipientAccessView` carries its own
  `.task { await model.load() }`, so a synchronous single-shot walk (the
  `AXProbe.tree` shape) races that task. Added `GatingHost`, mirroring
  `RevealedRowTests.EditorHost`'s already-established "keep the host alive,
  settle with a 120ms real sleep, mutate the model, settle again, re-walk"
  shape, rather than inventing a new async testing technique.

**What was deliberately not attempted, per the finding's own framing and
this codebase's own precedent:** the `.confirmationDialog` itself is not
tested for appearance/wiring — `WorkspaceSwitchDecisionTests`' and
`QuitRequestTests`' doc comments both state this explicitly as a documented,
accepted limitation of `swift test` here (no window server, no way to drive
a real system dialog), not an oversight. `pendingRemovals` — the gate that
decides whether the dialog is shown — is the part that *is* directly and
thoroughly tested, per the finding's own suggestion.

**One gap not fully closed:** the transient "applying" `ProgressView`'s
`.accessibilityLabel(LocalizedKey.accessApplyingLabel.text)` is still
verified only by `LocalizationTests` (the string exists, resolves, is
non-empty) — not by an AX-tree assertion that the label is actually attached
to the node while `isApplying == true`. Synchronizing an AX walk with that
specific mid-`await` window reliably (`apply()`'s single `await
keyStore.withKey`/`rewrapRecipients` call, not a settled multi-frame state
like the row toggle) looked like it would need either a hand-rolled
continuation-holding fake `rewrapRecipients` or a similar mechanism, for a
narrow payoff given the label text itself is already localization-tested
and the surrounding wiring (`if model.isApplying { ProgressView()... } else
{ Button(...) }`) is a two-line, visually-inspectable conditional. Flagging
rather than silently leaving it off the list.

## Test commands and output — round 1 fixes

**Xcode toolchain** (`/usr/bin/swift` on this machine's current `PATH`
ordering, Apple Swift 6.4.0.27.1, swift-frontend `swiftlang-6.4.0.27.1` —
same toolchain identified in the original task-3 report; re-verified via
`which -a swift` / `swift --version` before this round, unchanged):

```
$ swift test --filter RecipientAccess
✔ Test run with 31 tests in 9 suites passed after 3.412 seconds.

$ swift test   # all 4 targets
✔ Test run with 320 tests in 63 suites passed after 18.181 seconds.  (SopsUITests)
✔ Test run with 101 tests in 7 suites passed after 0.607 seconds.    (SopsProjectsTests)
✔ Test run with 271 tests in 46 suites passed after 31.136 seconds.  (SopsHealthTests)
✔ Test run with 74 tests in 13 suites passed after 5.593 seconds.    (SopsEngineTests)
```

766/766 across all four targets, zero failures. (297 → 320 in SopsUITests:
+23 new tests this round — 10 model-level in `RecipientAccessTests.swift`,
13 in the new `RecipientAccessGatingTests.swift`.)

**Swiftly-managed toolchain** (`~/.swiftly/bin/swift`, Apple Swift 6.3.3
`swift-6.3.3-RELEASE`):

```
$ ~/.swiftly/bin/swift test --filter RecipientAccess
✔ Test run with 31 tests in 9 suites passed after 2.292 seconds.

$ ~/.swiftly/bin/swift test --filter SopsUITests
✘ Test run with 320 tests in 63 suites failed after 17.811 seconds with 1 issue.
  — sole failure: "the Add Project control fills the sidebar footer"
    (FirstRunWindowAndSummaryTests.swift:398), the same pre-existing,
    environment-dependent flake identified and verified pre-existing (at
    HEAD, before any task-3 change) in the original task-3 report. Not
    re-verified against this round's HEAD specifically since nothing in
    this round touches `ProjectSidebar` or that test; the prior verification
    stands.

$ ~/.swiftly/bin/swift test --filter SopsProjectsTests
✔ Test run with 101 tests in 7 suites passed after 0.570 seconds.

$ ~/.swiftly/bin/swift test --filter SopsEngineTests
✔ Test run with 74 tests in 13 suites passed after 5.416 seconds.
```

319/320 + 101/101 + 74/74 = 494/495, the sole non-pass being the confirmed
pre-existing, unrelated flake.

## Housekeeping

- `git diff --check`: passed.
- `$TMPDIR`: 2.1G, unchanged from before this round (this machine's own
  baseline churn, unrelated to this task). No leftover
  `*recipient-access*`/`*cli-set*` entries after the full run — every new
  fixture goes through the same `scratchDirectory()`/`ScratchDirectoryRegistry`
  registration the original task-3 tests already used, plus the new
  seam-injection tests that touch no disk at all (fake `/dev/null/...` URLs
  with injected `readFile`).

## Files touched this round

- `Packages/SopsGUIKit/Sources/SopsUI/Editor/RecipientAccessModel.swift` —
  I2 fix (`isDirty`), I3 seam restructuring (`rewrapRecipients` seam,
  `defaultRewrap`, deleted `Outcome`/old `rewrap`).
- `Packages/SopsGUIKit/Sources/SopsUI/Editor/SecretEditorView.swift` — C1
  fix (`canOpenAccessPanel`, wired into the toolbar button).
- `Packages/SopsGUIKit/Sources/SopsUI/Editor/RecipientAccessView.swift` —
  extracted `canApply` as a pure, testable function (part of I3's ask).
- `Packages/SopsGUIKit/Sources/SopsUI/LocalizedKey.swift`,
  `Resources/Localizable.xcstrings` — one new key,
  `access.disabled-unsaved-changes`.
- `Packages/SopsGUIKit/Tests/SopsUITests/RecipientAccessTests.swift` — I2
  regression test, I3 model-level coverage (10 new tests, 2 new suites).
- `Packages/SopsGUIKit/Tests/SopsUITests/RecipientAccessGatingTests.swift`
  (new) — C1 regression + pure-function tests, I3 view-level coverage (13
  tests, 4 suites).

## Disagreements

None. All three findings were reproduced exactly as described before
fixing, including the I2 finding's specific claim that the prior doc
comment's own rationale was false.
