#!/usr/bin/env bash
# Proves `Scripts/release-prebuild.sh`'s unchanged-bundle refusal can actually
# fire, using the case it was written for rather than a synthetic one.
#
# `v0.1.12..18dd38c` is real history: the only commit between the 0.1.12 tag
# and that ref touched `docs/GUIDE.md`, which is not in the bundle. Releasing
# there would have shipped a byte-identical app. That was caught by a person
# noticing at the time; this is the check that would catch it now.
#
# The positive case uses the current HEAD, which has real shipping changes
# since the last tag — so a run that refuses everything, or accepts
# everything, fails here rather than looking correct.
#
# Only the refusal logic is exercised: SKIP_ENGINE_BUILD stops the script
# before it hands off to the engine build, which takes minutes and proves
# nothing about this.
set -uo pipefail

cd "$(dirname "$0")/.."

fail() { printf '\033[1;31mFAIL:\033[0m %s\n' "$1" >&2; exit 1; }
pass() { printf '\033[1;32mpass:\033[0m %s\n' "$1"; }

# ── the historical case: only docs changed, must refuse ──────────────────────
out=$(PREVIOUS_RELEASE_TAG=v0.1.12 RELEASE_HEAD=18dd38c SKIP_ENGINE_BUILD=1 \
      ./Scripts/release-prebuild.sh 2>&1)
status=$?

if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "$out"
    fail "a docs-only range was accepted — this is exactly the release that should be refused"
fi
if ! grep -q "nothing that reaches the bundle has changed" <<<"$out"; then
    printf '%s\n' "$out"
    fail "refused, but not for the unchanged-bundle reason"
fi
if ! grep -q "docs/GUIDE.md" <<<"$out"; then
    printf '%s\n' "$out"
    fail "refusal did not name the non-shipping paths it saw"
fi
pass "a docs-only range is refused, and the refusal names docs/GUIDE.md"

# ── today: real shipping changes since the last tag, must proceed ────────────
out=$(SKIP_ENGINE_BUILD=1 ./Scripts/release-prebuild.sh 2>&1)
status=$?

if [[ "$status" -ne 0 ]]; then
    printf '%s\n' "$out"
    fail "HEAD has real shipping changes since the last tag but was refused"
fi
if ! grep -q "shipping path(s) changed since" <<<"$out"; then
    printf '%s\n' "$out"
    fail "proceeded without reporting how many shipping paths changed"
fi
pass "HEAD, which has shipping changes, is allowed through"

echo
echo "All release-prebuild checks passed."
