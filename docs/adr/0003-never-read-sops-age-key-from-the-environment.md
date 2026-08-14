# ADR 0003 — Never read `SOPS_AGE_KEY` from the environment

**Date:** 2026-08-14
**Status:** Accepted
**Milestone:** M2 (ticket #7)

## Context

`AgeKeyFileLocations` resolves every place the embedded sops build looks for a plaintext
age identity — `SOPS_AGE_KEY_FILE`, then `$HOME/Library/Application Support/sops/age/keys.txt`,
then the conventional `~/.config/sops/age/keys.txt` — and `SecurityPostureCheck`'s
`security.legacy-key-file` finding warns when one of those files sits unprotected on disk.

`SOPS_AGE_KEY` is a different mechanism entirely: the upstream `age` and `sops` tooling also
accept the identity itself, in the environment, as a variable whose *value* is the private
key. This app has never read it — `AgeKeyFileLocations.swift`'s "What is deliberately not
here" doc comment section states the reasoning — but until this ADR that decision existed
only as a code comment, one contributor away from being "fixed" by whoever next wondered why
the file-based check does not also cover it. Ticket #7's audit named this explicitly:
finding a plaintext key file and reporting only its existence is the ticket's main subject,
but "the biggest exposure is deliberately not checked at all" needed a decision on the
record, not just a warning under a section header.

Two separate questions are easy to conflate here, and this ADR answers only the first:

1. Should this app's health check *inspect* `SOPS_AGE_KEY`'s value to decide whether to warn?
2. Should this app ever *read* `SOPS_AGE_KEY`'s value for any purpose (decryption, import)?

ADR 0001 already answers (2) — the bridge takes key material as function arguments through
`keyservice.KeyServiceServer`, and CLAUDE.md's hard constraints repeat it: "Never call
`decrypt.File`/`decrypt.Data`, never set `SOPS_AGE_KEY*` in app code." This ADR is about (1)
alone: whether *checking for the variable's presence*, for the sole purpose of warning the
user about it, is worth doing.

## Decision

**Never touch `SOPS_AGE_KEY` — not to read it, and not even to check whether it is set.**

`AgeKeyFileLocations.loginShellPathVariables` asks the login shell for exactly two names,
`SOPS_AGE_KEY_FILE` and `XDG_CONFIG_HOME`, both of which hold *paths* — safe to hold, quote,
and log. It does not use `env` or `export -p`, specifically because either would pull
`SOPS_AGE_KEY` into this process as a side effect of looking for file paths. That restraint
stays exactly as narrow going forward: no future change to this probe may widen it to read
`SOPS_AGE_KEY`'s value, and no new check may either.

A narrower version of "check for its presence" was considered and rejected: reading only
`ProcessInfo.processInfo.environment["SOPS_AGE_KEY"] != nil` — a boolean, never the value —
to add a `.problem` finding "an age key is exposed in your environment." Rejected because:

- **The type of the value it touches makes the boundary easy to cross by accident.**
  `ProcessInfo.processInfo.environment` is `[String: String]` — a `Bool` read of it still
  requires the dictionary lookup to have the private key sitting in a local variable for the
  duration of the `!= nil` check, in a codebase whose CLAUDE.md states "Key material never
  goes through the environment" as a hard constraint with no carve-out for "briefly, for a
  presence check." The safest way to guarantee a value is never logged, printed, or
  accidentally interpolated is for it to never be read into this process at all.
- **It would not be an isolated line.** `Never log a raw request/response containing a
  secret` review discipline exists precisely because a debugger breakpoint, a future
  `print(ProcessInfo.processInfo.environment)` added for an unrelated diagnostic, or a crash
  reporter that dumps environment variables (several do, by default) would then be one
  accidental step from exposing a real private key from a codebase that otherwise never
  brings one into Swift-land outside `SessionKeyStore`'s single `private var`.
- **The finding it would produce is not actionable by this app.** `SecurityPostureCheck`
  already declines to run `chmod` or touch the filesystem — CLAUDE.md's "the app never
  mutates the system" — so a `SOPS_AGE_KEY` finding could only ever say "unset this yourself
  in your shell profile," which the user is equally able to notice from their own `env` or
  `.zshrc` without this app touching the variable at all. The file-based finding above is
  actionable in a way this one would not be: the app can name a path and hand over a `chmod`
  command.

## Consequences

- **`SOPS_AGE_KEY` is invisible to this app's health report, on purpose, forever** — not an
  oversight to fix later. A user relying on `SOPS_AGE_KEY` for the CLI gets no warning from
  this app about it, and this ADR is the place that says why, so nobody "fixes" the gap by
  reintroducing the exact exposure ADR 0001 already closed for decryption.
- **The exposure is real and unaddressed by this app** — worth stating plainly rather than
  implying the finding above covers it. Anyone who *does* export `SOPS_AGE_KEY` in a shell
  profile is exposed to every process that can read their environment (which is broader than
  "every process that can read their home directory," the file-based finding's stated
  threat model — child processes inherit environment by default without needing filesystem
  access at all). This app simply does not have a mechanism, and per this ADR will not build
  one, to say so.
- **`AgeKeyFileLocations`'s existing two-name allowlist (`SOPS_AGE_KEY_FILE`,
  `XDG_CONFIG_HOME`) is the permanent shape of environment access for this feature.** A
  future contributor adding a third name to that list must not add `SOPS_AGE_KEY`.

## Related

- [ADR 0001](0001-in-process-go-bridge.md) — key material as function arguments, never
  environment-based key discovery, for the *decryption* path.
- `AgeKeyFileLocations.swift`'s "What is deliberately *not* here" doc comment section — the
  code-level statement of this same decision, now backed by this record.
- CLAUDE.md, "Hard constraints" — "Key material never goes through the environment" and
  "No secret values in logs, errors or crash reports."
