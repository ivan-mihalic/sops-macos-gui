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
