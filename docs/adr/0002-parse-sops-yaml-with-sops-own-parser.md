# ADR 0002 — `.sops.yaml` is parsed by sops's own parser, through the bridge

**Date:** 2026-08-07
**Status:** Accepted
**Milestone:** M1 (Task 11, ProjectHealthCheck)

## Context

`ProjectHealthCheck` needs to know, for a given encrypted file, which creation rule in
`.sops.yaml` governs it and which recipients that rule declares. The M1 plan specified a
small hand-rolled parser for a narrow subset of `.sops.yaml` — `path_regex` and `age` only —
on the reasoning that the app is not a YAML editor and needs very little.

That reasoning was wrong, and three consecutive review rounds proved it. Each round fixed
the reported defect and introduced or exposed a different one, all of the same kind: the
parser silently produced plausible-looking wrong data instead of failing.

1. The parser as written in the plan **did not pass the plan's own tests**. Malformed YAML
   parsed to a one-rule config instead of failing; a nested `age:` block list was read as
   three separate creation rules.
2. Flow style — `age: [key1, key2]`, valid and common — corrupted every recipient with stray
   brackets, so the check reported "stale recipients" and advised `sops updatekeys` against a
   healthy repository.
3. A flow list wrapped across two lines parsed to `["[k1"]`, dropping the second key entirely
   and producing three false claims about a project that was correctly encrypted.
4. The line-joining fix for (3) then merged two unrelated creation rules whenever two
   unmatched brackets inside quoted `path_regex` values happened to cancel across the
   document — garbling both rules' patterns and dropping a recipient.

Separately, a pgp-only `.sops.yaml` produced a confident `.ok` — "every file's key list
matches" — because real PGP metadata has no `recipient:` field, so both sides of the
comparison were empty and matched.

Every one of these tells the user something untrue about their own repository. For a tool
whose entire job is telling people whether their secrets are configured correctly, that is
the worst available failure mode — worse than crashing, because it is silent.

## Decision

**Parse `.sops.yaml` with `github.com/getsops/sops/v3/config`, exposed through the Go bridge.**
Delete the hand-rolled parser.

The engine already links that package. `config.LoadCreationRuleForFile(confPath, filePath, nil)`
returns the rule governing a given file, carrying `KeyGroups []sops.KeyGroup`. In the pinned
v3.13.3 source, `creationRule.Age` is declared `interface{}` with the comment
`// string or []string` — sops parses its own configuration format with a real YAML parser
and handles every shape natively.

## Consequences

- **The whole bug class is gone permanently.** Flow style, block lists, multi-line values,
  anchors, comments, quoting, CRLF — all of it is handled by the same code sops itself uses.
  There is no drift to maintain, because there is no second implementation.
- **`path_regex` matching and non-age-backend detection come for free**, computed sops's way
  rather than ours. The pgp/KMS false-`.ok` cannot recur, because the rule's key groups
  carry typed master keys instead of being inferred from text.
- **The cost is one more C entry point**, returning JSON. That is a small, well-understood
  surface compared with owning a YAML parser we cannot afford to get wrong.
- **This does not cover reading an encrypted file's own metadata** (`recipients(inEncryptedFile:)`),
  which is a separate concern. That path is covered by a test that encrypts with the real
  bridge and parses the genuine output — the right shape, and the reason the field-order
  difference between the plan's fixture and reality was caught rather than shipped.
- **A general lesson for this codebase, worth stating because it recurred:** where we already
  link the authoritative implementation of a format, use it. Reimplementing a format we do
  not control is how a check earns the user's trust and then quietly abuses it.

## Related

- [ADR 0001](0001-in-process-go-bridge.md) — the in-process bridge that makes this cheap.
- PROPOSAL.md §2, "File compatibility": *we never reimplement the SOPS format.* This decision
  extends that rule from the file format to the configuration format, where it should have
  applied from the start.
