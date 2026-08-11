# Engine — in-process SOPS bridge

Go wrapper over `getsops/sops`, built as a static `c-archive` and wrapped into an
xcframework so the Swift app can drive SOPS in-process — no `sops` binary is ever
spawned. Verdict and reasoning behind this approach: [ADR 0001](../docs/adr/0001-in-process-go-bridge.md).

Promoted out of the M0 `spike/` prototype once the approach proved out; behaviour
is unchanged from the spike, only the location and Swift package wiring moved.

## Layout

| Path | What it is |
|---|---|
| `gobridge/` | Go wrapper over upstream sops — `Encrypt`, `Decrypt`, own age keyservice |
| `cshim/` | cgo entry points, built as `c-archive` |
| `build-xcframework.sh` | `go build -buildmode=c-archive` → `build/SopsBridge.xcframework` (arm64) |

The Swift side lives in `Packages/SopsGUIKit`, not here:

| Path | What it is |
|---|---|
| `Packages/SopsGUIKit/Sources/SopsEngine/` | Swift wrapper over the C API (`SopsBridge.swift`) |
| `Packages/SopsGUIKit/Tests/SopsEngineTests/` | Swift-side compatibility tests against the real `sops` CLI |

`Packages/SopsGUIKit/Package.swift` declares a `CSopsBridge` binary target pointing at
`Engine/build/SopsBridge.xcframework` — build the xcframework before running `swift test`
or opening the Xcode project. `Scripts/bootstrap.sh` does this for you.

## Running it

```bash
brew install sops age go            # compatibility oracle + toolchain
./build-xcframework.sh              # must run before anything Swift
go test ./...                       # Go-level round-trips against the CLI
cd ../Packages/SopsGUIKit && swift test   # Swift-level round-trips against the CLI
```

Both suites generate throwaway age keys at runtime and hand them to the CLI via
`SOPS_AGE_KEY_FILE`, so your own `~/.config/sops/age/keys.txt` can never affect a result.
No key material is written into the repo.

### `go test ./...` needs no `-timeout` of its own

Recorded because it has been raised as a risk once already, on a figure of ~594s
against `go test`'s 600s default — which would make the suite a coin flip on any
slower machine. Measured here on 2026-08-11, `go clean -testcache` first:

| | wall clock | inside the test binary |
|---|---|---|
| `go test ./...` | 13.1s | gobridge 10.1s, cshim 0.7s |
| `go test -race ./...` | 41.3s | gobridge 19.7s, cshim 2.0s |

Two orders of magnitude of headroom, so nothing is set. And the 594s figure
cannot have been the timeout in any case: `-timeout` is handed to the compiled
test binary and starts when that binary runs, so however long `go build` spends
on the sops dependency tree, it is never counted against it. If a future run
does approach the limit, the fix is to find what got slow — Go has no
per-repository default to raise, only the process environment (`GOFLAGS`) or a
wrapper, and a wrapper only protects people who use it.
