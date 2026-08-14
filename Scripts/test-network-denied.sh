#!/usr/bin/env bash
# Runs SopsHealthTests with all networking denied at the OS sandbox level.
#
# WHAT THIS ESTABLISHES, precisely — the wording above this line used to claim
# more, and a review proved the claim false by inserting an unconditional,
# consent-ignoring URLSession call into the app's only networking function and
# watching this script exit 0.
#
#   It establishes: with the network genuinely unreachable, the health suite
#   still passes. No check hangs, crashes, or reports a wrong verdict because
#   a request failed. That is worth having and it is all this proves.
#
#   It does NOT, on its own, establish that the app never *attempts* a request.
#   Failures are swallowed into `.lookupFailed` by design, so an unwanted
#   request would be invisible to this script.
#
#   That gap is now closed elsewhere, and deliberately elsewhere:
#   `FullReportNetworkGuardTests` runs the real `HealthReport.standard` chain
#   with consent off and asserts zero requests reached the URL loading system.
#   It runs in the ordinary suite, not here, because it needs the network
#   stack present in order to watch it.
#
#   ⚠️ The obvious implementation of that guard does not work, and the reason
#   is worth keeping: a process-wide `URLProtocol.registerClass` intercepts
#   `URLSession.shared` and *not* a session built from an ephemeral or custom
#   configuration — measured directly. `GitHubReleaseSource` builds an
#   ephemeral one, so a global registration would have reported "zero
#   requests" whether or not any were made: an observation point with a hole
#   exactly where it matters, which is worse than none, because it reads as
#   proof. The guard therefore instruments that one session by name, and a
#   companion test asserts the app constructs a `URLSession` in exactly one
#   file, so a second one added later cannot slip past it.
#
#   Still true, and not fixable here: the sandboxed run asserts a strict
#   subset of the unsandboxed one — anything gated on a resource the sandbox
#   denies is absent from the very run meant to be strictest. The sandbox
#   really does deny those resources, so those skips are irreducible. What
#   changed is that they are no longer silent: `./Scripts/test.sh` prints
#   every skipped test with its reason in a block at the end of the run, and
#   this script goes one step further — it names every skip it is allowed to
#   have (below, `known_skips_file`) and fails if one shows up that isn't on
#   that list, rather than letting the count difference sit unexplained.
#   Measured directly, same target, same machine: both runs count 350 tests
#   in 65 suites; the plain run (`./Scripts/test.sh --filter SopsHealthTests`)
#   skips 2 (both opt-in, gated on an environment variable nobody sets in
#   either run); this one skips those same 2 plus exactly 3 more, each one
#   a real-binary test whose precondition is a socket bind this profile
#   denies (loopback TCP, or a Unix-domain gpg-agent socket).
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
log=$(mktemp -t sopsgui-network-denied)
known_skips_file=$(mktemp -t sopsgui-known-skips)
trap 'rm -f "$log" "$known_skips_file"' EXIT

set +e
sandbox-exec -f "$PROFILE" xcrun xctest \
    Packages/SopsGUIKit/.build/out/Products/Debug/SopsHealthTests.xctest 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

if [[ "$status" -ne 0 ]]; then
    echo "SopsHealthTests failed under the deny-network profile" >&2
    exit "$status"
fi

# Every skip this run is allowed to have, and why — one line each,
# `<test name>|<reason>`. Two kinds appear here:
#
#   * caused by THIS profile specifically: the sandbox denies a socket bind
#     (loopback TCP, or the Unix-domain socket gpg-agent needs) that a
#     real-binary test's precondition checks for, so it skips here and runs
#     under `./Scripts/test.sh`.
#   * present either way: an opt-in test gated on an environment variable
#     nobody sets in either run — nothing to do with the sandbox, listed here
#     anyway so every skip this run produces is accounted for, not just the
#     sandbox-caused ones.
#
# A skip that is not on this list is new and unexplained: either this profile
# now denies something it didn't before, or a test's precondition changed.
# Either way this script must fail loudly instead of reporting success while
# quietly saying nothing about it — that is the exact failure mode ticket #21
# exists to close. Widening this list to make a red run pass again is the
# wrong fix; find out why the skip appeared, then decide whether it belongs
# here.
cat >"$known_skips_file" <<'EOF'
the request on the wire carries a fixed User-Agent and Accept-Language, not CFNetwork's own|loopback bind denied by this profile (UpstreamVersionSourceTests.headersOnTheWireAreFixed)
a real sops --pgp encrypted file has no age recipient, and is recognised as pgp-protected|gpg needs a Unix-domain agent socket, denied by this profile (GPGAvailability.canGenerateKeys)
a pgp-only rule protecting a real pgp-encrypted file is .unknown, never a confident .ok|gpg needs a Unix-domain agent socket, denied by this profile (GPGAvailability.canGenerateKeys)
real repository findings|opt-in, gated on $PROJECT_HEALTH_ROOT — unset in every run, not caused by the sandbox
real repository scan wall clock|opt-in, gated on $SCAN_TIMING_ROOT — unset in every run, not caused by the sandbox
EOF

echo
echo "==> skips under this profile — every one must be on the known, explained list:"
unexplained=0
while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    reason=$(awk -F'|' -v n="$name" '$1 == n { print $2; found=1 } END { if (!found) exit 1 }' "$known_skips_file") || reason=""
    if [[ -n "$reason" ]]; then
        echo "    known: \"$name\" — $reason"
    else
        echo "    UNEXPECTED: \"$name\" is not on the known list" >&2
        unexplained=1
    fi
done < <(grep -o '➜ Test "[^"]*" skipped' "$log" | sed -E 's/➜ Test "(.*)" skipped/\1/' | sort -u)

if [[ "$unexplained" -ne 0 ]]; then
    echo >&2
    echo "A skip appeared under the deny-network profile that is not on the known, explained list in this script." >&2
    echo "Either this profile is now denying something new, or a test's precondition changed. Find out which," >&2
    echo "then update the list above — do not just widen it to make this pass." >&2
    exit 1
fi
