# ADR 0001 — SOPS engine runs in-process via a Go c-archive

**Date:** 2026-08-06
**Status:** Accepted
**Milestone:** M0 (spike, PROPOSAL.md §9)

## Context

PROPOSAL.md §3 proposed compiling upstream `getsops/sops` + `filippo.io/age` into an
xcframework (`c-archive`) called in-process from Swift, with bundled binaries invoked as a
subprocess as the fallback if that proved impractical. The spike existed to decide which.

Hard requirement either way: every file the app writes must round-trip with the standard
`sops` CLI, including MAC and `encrypted_regex`. We never reimplement the SOPS format.

## Decision

**Go for the in-process bridge.** The fallback is not needed.

## What the spike proved

Code lives in `spike/`. Both suites run green on macOS 26.5.2 / Xcode 27 / Go 1.26.5,
against `sops` 3.13.2 and `age` 1.3.1 as the compatibility oracle.

- `sops` v3.13.3 has **no `internal/` packages**. The full encrypt path
  (`cmd/sops/common`, `cmd/sops/formats`, `stores/yaml`, `aes`, `age`, `keyservice`) is
  importable. No forking, vendoring, or shim into private code is required —
  `gobridge.Encrypt` mirrors `cmd/sops/encrypt.go` step for step.
- Both directions verified against the real CLI: bridge-encrypted files decrypt with
  `sops --decrypt`, and CLI-encrypted files decrypt through the bridge, byte-identical.
- `encrypted_regex` round-trips in both directions, and non-matching keys demonstrably
  stay in plaintext while matching ones do not.
- MAC tampering is rejected; an unrelated identity fails rather than returning garbage;
  each of several recipients decrypts independently.
- `env -i ./sops-spike-demo` (no `PATH`, no reachable `sops` binary) encrypts successfully.
  `otool -L` shows only system dylibs. The engine really is in-process.

## Consequences

### Key material never touches the environment

Upstream's default age key discovery reads `SOPS_AGE_KEY`, `SOPS_AGE_KEY_FILE`, and
`~/.config/sops/age/keys.txt`. Environment variables leak to child processes and crash
reports, which is incompatible with the Keychain/Touch-ID model in PROPOSAL.md §2.

The bridge therefore implements its own `keyservice.KeyServiceServer` and injects
identities through `age.ParsedIdentities.ApplyToMasterKey`, wired up via
`keyservice.NewCustomLocalClient`. Identities are passed as function arguments only.
**This must survive into M1+ — do not switch to `decrypt.File`/`decrypt.Data`, whose
stability guarantee comes with environment-based key discovery.**

### Binary size

The archive is ~109 MB unstripped; a linked, stripped release executable is ~40 MB,
because `sops` pulls in the AWS, GCP, Azure and Vault SDKs even for an age-only build.
Acceptable for a notarized Mac app, but if it becomes a problem the lever is trimming
unused KMS backends from the dependency graph — not abandoning the in-process design.

### Text-only C boundary

The C shim passes NUL-terminated strings. That is fine for YAML/JSON/dotenv/INI. If the
SOPS `binary` format is ever supported, the boundary needs length-prefixed buffers.

### Ownership across the boundary

Every entry point returns 0 on success, non-zero on failure, and writes a Go-allocated
C string into an out-parameter that the caller releases with `sops_free`. Swift's
`SopsBridge.call` centralises this in a `defer`.

### Deployment target

`build-xcframework.sh` passes `-mmacosx-version-min` to cgo explicitly; without it Go
takes the SDK default (26.0) and the linker warns on every object file. The value must
stay in sync with `platforms:` in `Package.swift`. It is currently 14.0, which does not
prejudge PROPOSAL.md §10 question 3 — raising it is a one-variable change.

### Architecture

arm64-only, per the decision recorded alongside this spike. `build-xcframework.sh` builds
a single slice; adding x86_64 later means a second `go build` plus `lipo`.
