#!/usr/bin/env bash
# Refuses to proceed if Engine/build/SopsBridge.xcframework was built from a
# different set of Go sources than what is on disk right now.
#
#   ./Scripts/check-xcframework-freshness.sh
#
# Exit 0: the archive is fresh, or does not exist yet at all (nothing to
#         compare — `Scripts/test.sh` builds it in that case, before this
#         check ever runs).
# Exit 1: the archive exists and does not match current sources.
#
# Why this exists (#26 item 1): the Swift build links against whatever
# xcframework is already sitting in `Engine/build/`. Nothing checked whether
# that archive still matched `Engine/`'s Go sources, so a worktree where the
# feature under test lived only in Swift, and the Go bridge in another
# checkout entirely, verified against a *different engine than the one in the
# diff* with no signal anywhere — measured in production during this ticket's
# own predecessor phase (`sops-macos-gui` STATE.md, 2026-08-14): the main
# checkout's xcframework was stale after a feature was built in a worktree,
# and the only reason it was caught was a human remembering to re-run
# `Engine/build-xcframework.sh` by hand before believing a build result.
#
# The fingerprint this compares against is written by
# `Engine/build-xcframework.sh` itself, into `Engine/build/.source-fingerprint`
# — see that script's own comment for the exact pipeline, which this is a
# byte-for-byte copy of. The two must stay in lockstep; there is no shared
# library file (see that script's comment for why), so a change to one's
# `find`/`shasum` pipeline needs the identical change here.
set -euo pipefail

cd "$(dirname "$0")/../Engine"

XCFRAMEWORK="build/SopsBridge.xcframework"
FINGERPRINT_FILE="build/.source-fingerprint"

if [[ ! -e "$XCFRAMEWORK" ]]; then
    # Nothing to be stale relative to. The caller (`Scripts/test.sh`) builds
    # it fresh in this case, which is by construction never stale.
    exit 0
fi

if [[ ! -f "$FINGERPRINT_FILE" ]]; then
    echo "error: $XCFRAMEWORK exists but has no $FINGERPRINT_FILE next to it," >&2
    echo "       so its freshness relative to the Go sources cannot be confirmed." >&2
    echo "       This is expected for an xcframework built before this check existed." >&2
    echo "       Run ./Engine/build-xcframework.sh to rebuild it and lay down the fingerprint." >&2
    exit 1
fi

CURRENT=$(
    find . \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -not -path './build/*' -print0 \
        | sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
)
BUILT=$(cat "$FINGERPRINT_FILE")

if [[ "$CURRENT" != "$BUILT" ]]; then
    echo "error: $XCFRAMEWORK does not match the Go sources in Engine/ right now." >&2
    echo "       It was built from a different snapshot of Engine/ (fingerprint $BUILT)" >&2
    echo "       than what is on disk (fingerprint $CURRENT) — a test run against it would" >&2
    echo "       verify a different engine than the one in your working tree." >&2
    echo "       Run ./Engine/build-xcframework.sh to rebuild it, then re-run." >&2
    exit 1
fi

exit 0
