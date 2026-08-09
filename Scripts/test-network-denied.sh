#!/usr/bin/env bash
# Runs SopsHealthTests with all networking denied at the OS sandbox level, to
# verify GitHubReleaseSource (the app's only network call) never touches the
# network outside of its own explicit, consent-gated request.
#
# Positive control: also confirms the profile actually blocks networking by
# running curl against a real host first — if that unexpectedly succeeds, the
# profile isn't doing its job and the test run below proves nothing.
#
# One test, UpstreamVersionSourceTests.headersOnTheWireAreFixed, needs a real
# (loopback-only) socket to read genuine wire bytes below what URLProtocol can
# see. It is gated with .enabled(if:) to skip — not fail — when loopback
# binding itself is unavailable, which is expected under this profile.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="Scripts/no-network.sb"

echo "==> positive control: curl must fail to resolve under the deny-network profile"
if sandbox-exec -f "$PROFILE" curl -s -m 5 https://api.github.com >/dev/null 2>&1; then
    echo "curl succeeded — the sandbox profile is not blocking network access as expected" >&2
    exit 1
fi
echo "    confirmed: curl could not reach the network"

# `xcrun swift`, not bare `swift`. This machine has two toolchains (see
# CLAUDE.md) and they use different build layouts: the swiftly-managed one
# produces a single `SopsGUIKitPackageTests.xctest` under
# `.build/arm64-apple-macosx/debug/`, while `xcrun swift` (Swift Build)
# produces per-target bundles under `.build/out/Products/Debug/` — which is
# what the run step below executes.
#
# Building with the wrong one meant this gate could never refresh the bundle it
# then ran. On a fresh clone it failed loudly; on a machine where a stale
# bundle happened to exist it passed quietly — measured at 87 source files
# newer than the artefact it was asserting about. "The app does not touch the
# network" then said nothing about the current code.
echo "==> building SopsHealthTests"
(cd Packages/SopsGUIKit && xcrun swift build --build-tests)

echo "==> running SopsHealthTests with networking denied"
sandbox-exec -f "$PROFILE" xcrun xctest \
    Packages/SopsGUIKit/.build/out/Products/Debug/SopsHealthTests.xctest
