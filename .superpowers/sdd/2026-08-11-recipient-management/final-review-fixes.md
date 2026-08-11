# Final whole-branch review — fix wave

Branch `recipient-management`, on top of `2a69934`. One wave, every assigned finding.

Toolchains, named per CLAUDE.md:

- **Xcode's bundled compiler** — `/usr/bin/swift`, Apple Swift 6.4 (`swiftlang-6.4.0.27.1`), from
  Xcode-27.0.0-Beta.4. This is what bare `swift` resolves to on this machine (`which -a swift`
  puts `/usr/bin` ahead of `~/.swiftly/bin` — the inverse of what CLAUDE.md warns is typical), so
  it is named rather than assumed.
- **swiftly-managed open-source toolchain** — `~/.swiftly/bin/swift`, Apple Swift 6.3.3
  (`swift-6.3.3-RELEASE`).
- **Go** — go 1.26.5, `go vet ./...` and `go test ./...` in `Engine/`.

Every number below says which one produced it.

---

## I1 — `refreshPlan()` had no generation guard

**Changed**

- `ProjectRecipientApplier.Plan` gains `requestedRecipients: [String]` — the set the plan was
  computed for, carried on the plan itself so "the plan I hold" and "the set I am about to write"
  can be compared at all.
- `ProjectAccessModel.refreshPlan()` stamps a `planGeneration` before awaiting and publishes only
  if no later refresh started meanwhile. Finishing last is no longer the same as being right.
- `ProjectAccessModel.startRefreshingPlan()` — new, owns the task and cancels the previous one.
  `ProjectAccessView` calls it instead of spawning an unowned `Task { await model.refreshPlan() }`
  in `addStagedRecipient` and `toggleRemoval`.
- `applyConfig()` compares `plan.requestedRecipients` to `stagedRecipients`; re-plans on a
  mismatch, and if it *still* disagrees refuses with a new outcome `.refusedStalePlan` rather than
  writing older text. On success `configRecipients` is taken from `plan.requestedRecipients`, not
  from `stagedRecipients`, so the second-order lie (the model claiming a set the file does not
  hold) cannot come back if the guard is ever loosened.
- New string `project-access.error.stale-plan`.

**RED** — `ProjectAccessPlanGenerationTests`, with the fix reverted (generation stamp removed,
`applyConfig` restored to its old body):

```
✘ "a refresh that finishes last cannot overwrite a newer one"
  ProjectAccessTests.swift: Expectation failed: model.plan?.requestedRecipients == model.stagedRecipients
  — the overtaken refresh published its older plan on top of the newer one
  Expectation failed: config.contains(third.public)
  — the recipient staged during the refresh was silently dropped from .sops.yaml
✘ "applying with a plan nobody refreshed re-plans first"
  Expectation failed: await model.applyConfig() == .written   (was .nothingToWrite)
✘ "a staged change during the re-plan refuses the write outright"
  Expectation failed: await applying.value == .refusedStalePlan
```

The interleave is exact, not timed: `ScanGate` holds the first scan inside the injected
`scanProject` seam until the test releases it, so refresh #1 is *made* to finish last.

---

## I2 — the fallback scope crossed creation-rule boundaries silently

**Changed (Go)**

- `ConfigRecipientUpdate.FilesGovernedByOtherRules` (`filesGovernedByOtherRules`) — candidates some
  rule *other* than `RuleIndex` governs. Populated on the `index < 0` refusal path too, which is
  the case that needs it: `MatchedFiles` is empty there by construction.
- `filesGovernedElsewhere` — `filesGovernedBy`'s complement; never names a file no rule governs.
- `refuse()` initialises it to `[]string{}` so the field is never `null` for Swift's non-optional
  `[String]`.

**Changed (Swift)**

- `SopsBridge.ConfigRecipientUpdate.filesGovernedByOtherRules`, `Plan.filesGovernedByOtherRules`.
- `ProjectAccessView.scope` renders `project-access.other-rules-in-scope` (pluralized) in the
  fallback branch, in orange; `fileApplyConfirmationMessage` appends the same sentence.

**RED (Go)** — implementation removed, tests kept:

```
--- FAIL: TestUpdateConfigRecipients_NoMatchingRuleNamesTheFilesOtherRulesGovern
    configwrite_test.go:808: FilesGovernedByOtherRules = [], want [.../prod/db.yaml .../prod/api.yaml]
--- FAIL: TestUpdateConfigRecipients_FilesGovernedByOtherRulesExcludesTheSelectedRule
    configwrite_test.go:833: FilesGovernedByOtherRules = [], want just the staging file
```

**RED (Swift)** — see the mutation run below.

### A second defect this finding's test uncovered — anchored `path_regex` never matched

Writing the I2 fixture (`path_regex: ^prod/`, plus a `dev/local.yaml` that sorts first) failed for
a reason that had nothing to do with the disclosure: **no anchored `path_regex` matched anything at
all.**

sops picks a rule by stripping the config's directory off the file's path *as a literal prefix*
and matching what is left. `FileManager.enumerator` returns entries with the directory prefix's
symlinks already resolved (`/var/…` → `/private/var/…`), while the project root keeps whatever form
it was added in — `ProjectStore` deliberately stores the display path a symlink was added under
(`ProjectStoreTests`: "a project added via a symlink displays the symlink path"). The two spellings
disagree, the prefix strip is a no-op, and every `path_regex` is matched against an **absolute**
path. `^prod/` then matches nothing; `.*\.yaml$` matches everything — which is precisely why every
existing fixture passed: they all used the second kind. (`ProjectRecipientApplierOrderingTests`
even names the `/var` → `/private/var` discrepancy, in a comment about sorting, without connecting
it to matching.)

Fixed in `ProjectRecipientApplier.ruleMatchingPath(_:)`: the config path, the target and the
candidates are resolved to one form before the bridge sees them, and results are mapped back the
same way. `Plan.configURL` and the file URLs themselves are untouched — this form is used to *ask
about* files, never to write one. `sortedByProjectRelativePath` now uses it too, where the same
prefix strip was silently falling back to sorting absolute paths.

This is outside the assigned list; it is reported rather than left, because I2 cannot be
implemented correctly without it — the disclosure would have been permanently empty.

---

## I3 — `RecipientKind` was never displayed

`RecipientKindBadge` (shared) is drawn by both row views. `RecipientRowContent.label(for:)` maps
the kind to one of three new strings (`recipient.kind.device|server|person`). Kept in one type
rather than two so the two panels cannot drift again — see M3, which is what drift in this exact
seam already cost.

**Not built:** an in-app registry editor. Recorded as a deliberate deferral in
`docs/superpowers/specs/2026-08-11-recipient-management-design.md` so `RecipientRegistry
.save/upsert/remove` having no production caller is not read as an oversight.

---

## M1 — the config-update confirmation understated the diff

`project-access.update-config-confirm.message` no longer says "a **slightly** larger diff"; it
names the flush-style config whose every line shifts. `LocalizationTests
.configUpdateConfirmationDisclosesReformatting` now asserts the absence of "slightly" and the
presence of "flush" / "every line".

---

## M2 — `project-access.files-summary` read wrong at 1

The string is now two substitutions (`%1$#@matched@`, `%2$#@found@`) and the call site passes
`Int`s. `project-access.apply-files-removal.message`'s count went the same way.

Two guards, because the catalog check alone could not see this:

- `countedStringsPluralize` now detects `#@` rather than `%#@`, so a *positional* substitution
  (`%1$#@…@`, which is what a two-count sentence has to use) is no longer skipped.
- `noCallSitePreStringifiesACount` — new. Scans `Sources/SopsUI` for
  `String(format: LocalizedKey.…text, …)` whose arguments interpolate into a string literal, with
  an exemption list carrying a written reason (`project-access.results.summary`: three bare tallies
  with no noun or verb agreeing with them).
- `pluralsResolve` gained the two-count key at (1,1) and (2,3) — the half that proves the
  substitutions actually expand rather than reaching the user as `%1$#@matched@`.

---

## M3 — trim mismatch between the two panels

`RecipientRowContent.canAdd` trims `.whitespacesAndNewlines`, and both panels' Add buttons call it.
Pinned by `addButtonTrimsWhatTheModelsTrim`.

---

## M5 — two sources of the project root

`AppShell.activeProjectRootURL` (an ID lookup in `projects.groups`) is gone;
`recipientRegistryProjectRoot` is `fileListModel?.projectRoot`, which is what the project panel
already used. Pinned structurally by `AppShellProjectRootSourceTests` — `AppShell`'s state is all
`private @State`, so the source is what a test can reach.

---

## M6 — a `nil` fingerprint disabled the second-writer check

`ProjectRecipientApplier.applyToOne` refuses a file that reads fine but yielded no fingerprint,
mirroring `RecipientAccessModel.load()`. `AtomicFileWriter.write(expecting: nil)` does not check
loosely — it does not check at all, which is a different thing from the accepted best-effort
micro-window.

---

## M7 — rotation advice on the per-file removal

`access.remove-confirm.message` now carries the same sentence
`project-access.apply-files-removal.message` already did.

---

## M8 / M10 — doc comments that had stopped being true

- `Plan.encryptedFiles` / `Plan.targetFile`: "in scan order" → project-relative path order, which
  is what decides the targeted rule.
- `newAgeNode` (`configwrite.go`): the scalar's trailing comment is carried over only when
  `scalarValues[0]` survives — stated as the deliberate, narrower behaviour it is.
- `RecipientAccessView` / `ProjectAccessView`: both claimed to be public "so the headless snapshot
  catalog can render it". Neither has a catalog entry. Corrected to the real reason (a test renders
  them through `GatingHost` and walks the accessibility tree) and the absence is stated with why —
  a live `.task` scan races the single-shot renderer.

## M11 — `PROPOSAL.md`

"nine cgo entry points" → twelve, at both places, with a parenthetical preserving that nine was
right when the note was written.

---

## Runs

### Go — `Engine/`

```
$ go vet ./...
(clean)

$ go test -timeout 40m ./...
ok      github.com/ivan-mihalic/sops-macos-gui/engine/cshim      3.779s
ok      github.com/ivan-mihalic/sops-macos-gui/engine/gobridge   594.144s
?       github.com/ivan-mihalic/sops-macos-gui/engine/internal/versionprobe [no test files]
```

`gobridge` takes 594s on this machine, which is over `go test`'s **default** 10-minute timeout —
the first run of it here failed with a timeout panic at 604s and no test failure. It is a
pre-existing property of the suite (2.7M-execution fuzz corpora), not of this change; `-timeout`
has to be raised to see a real result. `gofmt -l gobridge/` reports `bridge_test.go`, which this
change does not touch (pre-existing).

The xcframework was rebuilt (`Engine/build-xcframework.sh`) before any Swift run, since the bridge
gained a JSON field.

### Swift — Xcode's bundled toolchain

`/usr/bin/swift` → Xcode-27.0.0-Beta.4, Apple Swift 6.4 (`swiftlang-6.4.0.27.1`). This is what
plain `swift` resolves to on this machine's `PATH` — the inverse of what CLAUDE.md warns is
typical, so it is named rather than assumed. It drives the **Swift Build** engine
(`.build/out/Products/Debug/…xctest/Contents/MacOS`), which *does* compile
`Localizable.xcstrings` — so `bundleHasMacOSLayout` was true and the bundle-gated localization
assertions (`everyKeyResolves`, `pluralsResolve`, including the new two-substitution checks)
actually ran instead of skipping.

```
$ swift test
✔ Test run with 358 tests in 73 suites passed after 21.187 seconds.   (SopsUITests)
✔ Test run with 116 tests in 16 suites passed after 0.626 seconds.    (SopsProjectsTests)
✔ Test run with 271 tests in 46 suites passed after 189.037 seconds.  (SopsHealthTests)
✔ Test run with 79 tests in 14 suites passed after 80.816 seconds.    (SopsEngineTests)
exit=0
```

824/824, zero failures.

An earlier full run on the same tree failed three timing-sensitive tests —
`CopyFeedbackTests` "the label returns to Copy once the confirmation expires" (the flake CLAUDE.md
and the task-4 report both name), `SecretDocumentViewModelTests` "the main-actor instrument tells
a blocked main actor from a busy machine", and `ClipboardClearingTests` "the pasteboard is cleared
after the interval elapses". All three passed on the clean run above; the failing run overlapped a
594s Go suite and a foreign `xcodebuild test` on the same machine, and its individual test
durations (528s for a test that normally takes under a second) say so. `AtomicFileWriterTests`
"the file is replaced atomically" (`observations.sampleCount > 1_000`) flaked once under the same
load and passed otherwise. None are related to this change.

### The RED mutation run — Xcode toolchain

Every behavioural fix was reverted at once (script kept out of the tree, in the session
scratchpad), the new tests kept, and the suites re-run. Output, trimmed to the assertions:

```
✘ "a refresh that finishes last cannot overwrite a newer one"                          [I1]
   ProjectAccessTests.swift:714: model.plan?.requestedRecipients == model.stagedRecipients
   ProjectAccessTests.swift:719: config.contains(third.public)
✘ "applying with a plan nobody refreshed re-plans first"                               [I1]
   ProjectAccessTests.swift:744: await model.applyConfig() == .written
   ProjectAccessTests.swift:746: config.contains(added.public)
✘ "a staged change during the re-plan refuses the write outright"                      [I1]
   ProjectAccessTests.swift:668: no scan started within 10s — nothing re-planned
   ProjectAccessTests.swift:775: await applying.value == .refusedStalePlan
✘ "the panel says so before the button is pressed"                                     [I2]
   ProjectAccessTests.swift:837: labels(in: host.nodes()).contains(expected)
✘ "and the confirmation dialog says it again"                                          [I2]
   ProjectAccessTests.swift:852: view.fileApplyConfirmationMessage.contains(expected)
✘ "the project panel draws the recipient's kind"                                       [I3]
   ProjectAccessTests.swift:906: labels(…).contains(LocalizedKey.recipientKindServer.text)
✘ "the per-file panel draws the same kind the same way"                                [I3]
   ProjectAccessTests.swift:927: labels(…).contains(LocalizedKey.recipientKindDevice.text)
✘ "the config-update confirmation warns that the whole .sops.yaml is rewritten"        [M1]
   LocalizationTests.swift:413: !message.lowercased().contains("slightly")
   LocalizationTests.swift:415: message.lowercased().contains("flush")
   LocalizationTests.swift:417: message.lowercased().contains("every line")
✘ "no call site turns a count into a string before formatting it"                      [M2]
   LocalizationTests.swift:263: 2 issues recorded
✘ "neither Access panel decides for itself what an empty recipient is"                 [M3]
   ProjectAccessTests.swift:958: !text.contains("trimmingCharacters(in: .whitespaces)")
   ProjectAccessTests.swift:960: text.contains("RecipientRowContent.canAdd")
✘ "the per-file panel's registry root and the project panel's root are the same source" [M5]
   AppShellTests.swift:94: perFileRoot.contains("fileListModel")
✘ "no second project-root derivation survives in AppShell"                             [M5]
   AppShellTests.swift:105
✘ "a file that reads fine but yields no fingerprint is refused, not written"           [M6]
   ProjectRecipientApplierTests.swift:684
```

Two things the mutation run itself taught, both fixed in the tests before the green run:

1. `applyConfigRefusesWhenTheStagedSetMovesAgain` originally waited on a continuation for the
   re-plan's scan to start. The pre-fix code never re-plans, so it **hung** rather than failed —
   the worst way for a guard to report a regression. It now polls with a 10s ceiling and records
   an issue, which is the first line of that test's RED above.
2. The reverted catalog plus the fixed call sites crashed the test process (`signal 11`):
   `String(format: "%1$@ …", 1, 1)` reads an `Int` as an object pointer. Incidental to the
   mutation, but it is the sharp end of M2 — a count and its format specifier disagreeing is not
   only a cosmetic bug.

### Swift — swiftly-managed toolchain (`~/.swiftly/bin/swift`, Swift 6.3.3)

This one drives SwiftPM's **native (llbuild)** build system, which does *not* compile the string
catalog — so every `LocalizedKey.text` resolves to its own raw key here and the bundle-gated
assertions skip with their stated reason. Every new AX assertion compares key-derived text to
key-derived text for exactly that reason, so they hold under both.

```
$ ~/.swiftly/bin/swift test
✘ Test run with 824 tests in 149 suites failed after 705.798 seconds with 7 issues.
```

Six tests, and none of them a defect in this change:

| test | verdict |
|---|---|
| `FirstRunWindowAndSummaryTests` "the Add Project control fills the sidebar footer" | **documented pre-existing** under this toolchain — task-3's report reproduced it on `d9b7bc6` in a throwaway worktree; the uncompiled catalog makes a width assertion keyed to resolved English text build-system-dependent |
| `CopyFeedbackTests` "the label returns to Copy once the confirmation expires" | the documented flake; took 481s here |
| `ClipboardClearingTests` "the pasteboard is cleared after the interval elapses" | same class, 74s |
| `SecretDocumentViewModelTests` "the main-actor instrument tells a blocked main actor…" | measured 0.03 against a 0.5 threshold, 499s |
| `ProjectScanDisclosureTests` "a truncated walk stops the plaintext finding reporting ok" | `Time limit was exceeded: 300.000 seconds` |
| **`ProjectAccessCrossRuleDisclosureTests` "the panel says so before the button is pressed"** | mine — `model.plan` was still `nil` at the assertion, i.e. `GatingHost.settle(until:)` gave up before the view's own `.task` finished a real project scan |

The whole run took 705s for what takes ~20s idle, with individual tests reporting 481–684s, and a
foreign `xcodebuild test` was running on the machine throughout. The last row was therefore
re-checked on a quieter machine, same toolchain:

```
$ ~/.swiftly/bin/swift test --filter 'ProjectAccessCrossRuleDisclosureTests|ProjectAccessScopeDisclosureTests'
✔ Test run with 7 tests in 2 suites passed after 0.573 seconds.
```

0.573s against 562s. Load, not logic. Every other new test passed in the loaded full run too —
including both `ScanGate` interleaves (683s and 658s there).

### `$TMPDIR`

```
$ ./Scripts/clean-test-temp.sh
would remove 21 entries (2M) from $TMPDIR   (age floor: older than 60 min)
$ ./Scripts/clean-test-temp.sh --apply
removed 21 entries (2M) from $TMPDIR
$TMPDIR is now 2.4G
```

Every new fixture goes through `projectScratchDirectory` / `applierScratchDirectory`, which
register with `ScratchDirectoryRegistry`, and keeps the `<label>-<UUID>` shape the sweeper matches
(`project-access-cross-rule-…`, `applier-no-fingerprint-…`, `applier-absent-…`). What is left in
`$TMPDIR` afterwards is 11 suite entries younger than the 60-minute floor plus ~21 600 entries
this repo does not produce (editor sockets, `xcrun_db`, random-named caches) — nothing in the
2.4G is a leak from this wave.

---

## Disagreements and things done differently

1. **M2's guard could not be built the way the finding described.** "Extend the guard test so a
   pre-stringified count cannot evade it again" cannot be done from the catalog: the catalog entry
   of a pre-stringified count is indistinguishable from any other `%@` string. The guard therefore
   reads the *module's source* for the call sites. It is a coarser instrument than
   `countedStringsPluralize` and it needs an exemption list, so it was given the same
   reason-in-writing shape the existing exemption list has.

2. **I2 needed a fix outside the assigned list to work at all** — the anchored-`path_regex`
   defect above. Reported rather than silently folded in.

3. **M3's assigned test does not, by itself, pin the finding.** A pure-function test on
   `RecipientRowContent.canAdd` passes whether or not the views call it — the mutation run proved
   that: it stayed green while the panel was reverted to `.whitespaces`. The suite therefore also
   carries a source-level check that neither view trims for itself. Stated because a
   reader comparing findings to tests would otherwise credit the wrong one.

4. **`.refusedStalePlan` adds a user-facing string that a very careful user will rarely see.**
   The alternative was to re-plan and write whatever the second plan said, which is the same class
   of silent substitution I1 is about. Refusing needs a sentence.

5. **No snapshot catalog entries were added** (M10's other half), as instructed; both doc comments
   now say so and say why, rather than claiming an entry that does not exist.

6. **The Go suite needs `-timeout` raised to pass at all on this machine** (594s vs a 600s
   default). Not this change's doing and not in the findings, but a `go test ./...` typed exactly
   as the method section spells it fails, so it is stated rather than quietly worked around.
