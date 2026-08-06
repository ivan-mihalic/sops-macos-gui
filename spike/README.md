# M0 spike — in-process SOPS bridge

Throwaway proof that Swift can drive `getsops/sops` in-process, producing files the
standard `sops` CLI accepts. Verdict and reasoning: [ADR 0001](../docs/adr/0001-in-process-go-bridge.md).

## Layout

| Path | What it is |
|---|---|
| `gobridge/` | Go wrapper over upstream sops — `Encrypt`, `Decrypt`, own age keyservice |
| `cshim/` | cgo entry points, built as `c-archive` |
| `build-xcframework.sh` | `go build -buildmode=c-archive` → `SopsBridge.xcframework` (arm64) |
| `Sources/SopsBridge/` | Swift wrapper over the C API |
| `Sources/sops-spike-demo/` | Executable used to prove no subprocess is involved |
| `Tests/SopsBridgeTests/` | Swift-side compatibility tests against the real `sops` CLI |

## Running it

```bash
brew install sops age go            # compatibility oracle + toolchain
./build-xcframework.sh              # must run before anything Swift
go test ./...                       # Go-level round-trips against the CLI
swift test                          # Swift-level round-trips against the CLI
```

Both suites generate throwaway age keys at runtime and hand them to the CLI via
`SOPS_AGE_KEY_FILE`, so your own `~/.config/sops/age/keys.txt` can never affect a result.
No key material is written into the repo.

## Proving it is really in-process

```bash
swift build -c release
env -i "$(swift build -c release --show-bin-path)/sops-spike-demo" age1...
```

`env -i` clears the environment entirely — there is no `PATH`, so no `sops` binary is
reachable. It still encrypts.
