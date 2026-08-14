#!/usr/bin/env bash
# The canonical way to run the Swift suite in this repo.
#
# `swift test` on its own is the wrong command here, and wrong in a way that
# looks right: its default build system (llbuild) never compiles
# `Localizable.xcstrings`, so `LocalizedKey` resolves to its own raw key. Two
# consequences, both measured on 2026-08-14 at 89795b0:
#
#   * the two localization guards disable themselves — `catalogIsBundled` and
#     `everyKeyResolves` skip with a reason, so the daily loop checks nothing
#     about strings while reporting a pass;
#   * `FirstRunWindowAndSummaryTests`' "the Add Project control fills the
#     sidebar footer" fails, deterministically, for the same reason. It was
#     carried as a flake for a while. It is not one.
#
# The newer Swift Build engine compiles the catalog, so both go away:
#
#   | filter                            | llbuild        | swiftbuild        |
#   |-----------------------------------|----------------|-------------------|
#   | catalogIsBundled/everyKeyResolves | skipped        | 307 cases, passed |
#   | the sidebar-footer test           | failed         | passed            |
#
# Hence `--build-system swiftbuild` below. `xcodebuild` compiles the catalog
# too, which is why the same suite has always been green under Xcode — the
# disagreement was never between machines, it was between build systems.
#
# Usage:
#   ./Scripts/test.sh                 # whole suite
#   ./Scripts/test.sh --filter Foo    # anything else is passed to swift test
set -euo pipefail

cd "$(dirname "$0")/../Packages/SopsGUIKit"

if [[ ! -e ../../Engine/build/SopsBridge.xcframework ]]; then
    echo "==> Engine/build/SopsBridge.xcframework missing — building it first"
    ../../Engine/build-xcframework.sh
fi

# #26 item 1: an xcframework that *exists* but no longer matches the Go
# sources in Engine/ is a worse trap than a missing one — the suite runs and
# reports a result, just about a different engine than the one in the diff.
# See check-xcframework-freshness.sh's own header for the incident this
# closes. Deliberately refuses rather than auto-rebuilding: the point is that
# a stale archive is never silently believed, not that this script should
# guess what the right fix is on every run.
if ! ../../Scripts/check-xcframework-freshness.sh; then
    exit 1
fi

log=$(mktemp -t sopsgui-test)
trap 'rm -f "$log"' EXIT

set +e
swift test --build-system swiftbuild "$@" 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
set -e

# A suite that skipped is a suite that did not check what you think it did, so
# say so at the end where it cannot be missed, rather than leaving it 300 lines
# up in the scroll.
skipped=$(grep -c '➜ Test .* skipped' "$log" || true)

echo
echo "──────────────────────────────────────────────────────────"
grep -E 'Test run with' "$log" | sed 's/^/  /' || true
if [[ "$skipped" -gt 0 ]]; then
    echo
    echo "  ⚠️  $skipped test(s) skipped — these asserted nothing:"
    grep '➜ Test .* skipped' "$log" | sed 's/^/      /'
fi
echo "──────────────────────────────────────────────────────────"

exit "$status"
