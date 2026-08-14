# ADR 0003 — Two single-chokepoint rules against arbitrary code execution

**Date:** 2026-08-14
**Status:** Accepted
**Milestone:** M2 (ticket #9)

## Context

This app's whole reason to exist is holding private key material and other people's
secrets. Two of its ordinary-looking operations — scanning a project for gitignored
files, and turning a `.sops.yaml` recipient list into a set sops will encrypt to — can
each be steered into running a program the app never meant to run, chosen by the
contents of a repository the app is merely looking at, not code the app wrote or the
user typed.

Both vectors were found and closed once each. Ticket #9 asked a harder question: what
stops a *second* call site, added later by someone who has not read the fix, from
reopening either one? An audit against `master` = `c33b549` (2026-08-14) found the
answer was "nothing" for one of the two, and "only a per-file test" for the other.

### Vector 1 — `core.fsmonitor` in a cloned repository's `.git/config`

`GitIgnoreOracle` shells out to `git check-ignore`/`rev-parse`/`ls-files` on every
project scan, to answer "would git ignore this file?" correctly (exact-line matching
against `.gitignore` was tried first and was wrong in both directions — see that type's
own doc comment). `core.fsmonitor` is a **repository-local** git config key whose value
git *executes*, and consulting the index is enough to trigger it. A repository the user
merely cloned or unpacked can set this in its own `.git/config`, so the sequence is:
add a project → the scan reaches a file named `.env` → the attacker's script runs as
the user. `safe.directory` does not help — the user owns the directory they just
cloned into, which is exactly the case that check exists to allow.

Measured, not theorised: git 2.54.0, a hook that touches a marker file, driven through
the exact `check-ignore --stdin -z` call the oracle makes. Without `-c
core.fsmonitor=` prepended, the marker appears. With it, it does not.
(`GitIgnoreOracleSafetyTests.theHookIsRealWithoutTheMitigation` is this measurement,
kept as a permanent control so the sibling behavioural test cannot start passing for
the wrong reason.)

### Vector 2 — `age1<name>1…` recipients executing an `age-plugin-*` binary

sops's own recipient parser routes anything shaped like `age1<name>1<data>` to
`plugin.NewIdentity`, which execs `age-plugin-<name>` **found on `$PATH`**, with no
absolute path and no timeout. Recipients this app hands to sops come from a project's
`.sops.yaml` or from whatever a user pastes into a recipient field — both are
attacker-influenced inputs for a hostile or merely careless repository. This is the
same "run whatever the environment points at" hazard ADR 0001 already closed for
identity discovery (`SOPS_AGE_KEY_CMD` and friends); this is the same shape reached
through the recipient argument instead.

## What was actually enforcing each rule, before this ADR

| Vector | What held it |
|---|---|
| git | `GitIgnoreOracle.runGit` is the sole function that calls `CommandRunner.run` with a git executable, and it unconditionally prepends `safeArguments = ["-c", "core.fsmonitor="]`. `GitIgnoreOracleSafetyTests.gitHasASingleGuardedChokepoint` asserts that shape structurally against `GitIgnoreOracle.swift`'s own source — but only that file's source. A new file elsewhere calling `Process`/`CommandRunner.run` with a git executable directly was not checked by anything. |
| plugin recipients | `nativeAgeMasterKeys` (`Engine/gobridge/recipients.go`) refuses a plugin-shaped or private-key-shaped recipient, and `UpdateRecipients` and `validAgeRecipients` (`configwrite.go`) both call it. `Encrypt` (`bridge.go`) **did not** — it carried its own hand-written copy of the same two checks, calling `sopsage.MasterKeysFromRecipients` (upstream's own parser, with none of this app's refusals) directly. The two implementations happened to agree, each pinned by its own independent test (`bridge_test.go`, `recipients_test.go`), but nothing made them agree — a third recipients-to-sops path could add a third copy and forget one of the two checks, and the whole suite would stay green. |

## Decision

**Both rules must have exactly one implementation, and exactly one test that fails
structurally — not merely behaviourally — the moment a second implementation exists.**

1. **Git.** `GitIgnoreOracle.runGit` remains the only place in the shipped app allowed
   to start a subprocess for git. Enforced two ways now instead of one:
   `gitHasASingleGuardedChokepoint` (unchanged, per-file: `GitIgnoreOracle.swift` itself
   carries exactly one `CommandRunner.run` call and it applies `safeArguments`) plus
   `ProcessSpawningChokepointTests.processIsConstructedInExactlyOneShippedFile`
   (new: `Process()` is constructed in exactly one file, `CommandRunner.swift`, across
   every shipped target). A new git call site written as its own `Process()` — the
   shape a diff view, git awareness, or a pre-commit hook would plausibly reach for —
   fails the second test the moment it exists, regardless of which file it lives in.

2. **Plugin recipients.** `nativeAgeMasterKeys` (`recipients.go`) is now the only
   function in `gobridge` that turns a caller-supplied recipient string into a
   `sops.MasterKey`. `Encrypt`'s hand-written copy was deleted; it now calls
   `nativeAgeMasterKeys` directly, the same as `UpdateRecipients` and
   `validAgeRecipients` already did. Enforced structurally by
   `TestRecipientValidationHasExactlyOneChokepoint` (`recipientvalidation_test.go`),
   an AST walk — not a `strings.Contains`, for the same reason
   `Engine/cshim/exports_test.go` is an AST walk and not one either, verified there by
   mutation: a comment satisfies a substring check — over every non-test file in the
   package. It asserts two things: `sopsage.MasterKeysFromRecipients` (upstream's
   unguarded parser) is called nowhere in this package, and `&sopsage.MasterKey{Recipient:
   ...}` — the composite literal that mints a key-group member from a string — is
   constructed in exactly one function.

## Consequences

- **A new git call site or a new recipients-to-sops path is now a compile-time-adjacent
  failure, not a code-review hope.** Both standing tests were verified, by deliberately
  reintroducing the exact violation each guards against and watching it fail with a
  message naming the offending file and line, then reverting — not merely written and
  trusted.
- **The `Encrypt`/`nativeAgeMasterKeys` duplication is gone permanently**, and cannot
  silently return, because `TestRecipientValidationHasExactlyOneChokepoint` would need
  to be deliberately weakened first — the same property ADR 0002 claims for parsing
  `.sops.yaml` with sops's own parser instead of a hand-rolled one: there is no drift
  to maintain because there is no second implementation.
- **What this does not cover:** `Sources/SnapshotTool`, a dev-only executable target
  that never reaches `App/` or a notarized build (`Package.swift`'s own comment on it
  says so directly), does construct `Process()` for git, to build fixtures for its own
  snapshots. That is deliberately out of scope — a hostile repository cannot make code
  that never ships do anything to a real user.

## Related

- [ADR 0001](0001-in-process-go-bridge.md) — "identities are passed as function
  arguments only", the same reasoning this ADR extends from key discovery to recipient
  parsing.
- [ADR 0002](0002-parse-sops-yaml-with-sops-own-parser.md) — the "no second
  implementation to drift" argument this ADR makes the same case for, on a different
  surface.
- `Packages/SopsGUIKit/Tests/SopsHealthTests/GitIgnoreOracleSafetyTests.swift`,
  `Packages/SopsGUIKit/Tests/SopsHealthTests/ProcessSpawningChokepointTests.swift`,
  `Engine/gobridge/recipientvalidation_test.go`.
