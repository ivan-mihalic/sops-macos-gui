#!/usr/bin/env bash
# Regression test for SOPS-32: clean-test-temp.sh must not abort mid-sweep
# when one of its victims is a chmod-000 fixture directory (the shape
# FileListView's and SecretFileCreator's tests leave behind if the process
# dies before their own `defer` restores permissions).
#
# Runs clean-test-temp.sh against an isolated, throwaway $TMPDIR — never the
# real one — so this is safe to run any time, including in CI.
set -euo pipefail
cd "$(dirname "$0")/.."

FAIL=0
fail() { echo "FAIL: $1" >&2; FAIL=1; }
pass() { echo "pass: $1"; }

FAKE_TMP="$(mktemp -d)"
cleanup() {
    chmod -R u+rwx "$FAKE_TMP" 2>/dev/null || true
    rm -rf "$FAKE_TMP"
}
trap cleanup EXIT

READABLE_UUID="AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
LOCKED_UUID="BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
READABLE_DIR="$FAKE_TMP/readable-fixture-$READABLE_UUID"
LOCKED_DIR="$FAKE_TMP/locked-fixture-$LOCKED_UUID"

mkdir -p "$READABLE_DIR" "$LOCKED_DIR/inner"
echo "leftover" > "$READABLE_DIR/file.txt"
echo "leftover" > "$LOCKED_DIR/inner/file.txt"

# Back-date everything before locking anything down — `find -exec touch`
# needs to descend into $LOCKED_DIR, which chmod 000 would then block.
OLD="$(date -v-2H +%Y%m%d%H%M.%S 2>/dev/null || date -d '2 hours ago' +%Y%m%d%H%M.%S)"
find "$FAKE_TMP" -exec touch -t "$OLD" {} \;

# Mirrors FileListModelTests.swift / FileListViewWiringTests.swift:
# `setAttributes([.posixPermissions: 0o000], ...)` on a fixture directory.
chmod 000 "$LOCKED_DIR"

echo "==> dry run against a $LOCKED_DIR that clean-test-temp.sh cannot read"
set +e
DRY_OUT="$(TMPDIR="$FAKE_TMP" ./Scripts/clean-test-temp.sh --min-age 0 2>&1)"
DRY_STATUS=$?
set -e
echo "--- output ---"
echo "$DRY_OUT"
echo "--- exit: $DRY_STATUS ---"

if [[ $DRY_STATUS -ne 0 ]]; then
    fail "dry run exited $DRY_STATUS instead of reporting and continuing — this is the SOPS-32 symptom: du's non-zero status under pipefail/set -e kills the script before it prints anything"
else
    pass "dry run exited 0 despite the unreadable fixture"
fi

if ! grep -q "$READABLE_UUID" <<<"$DRY_OUT"; then
    fail "dry run report never mentions the readable fixture — the sweep stopped before reaching it"
else
    pass "dry run report still names the readable fixture"
fi

if [[ $FAIL -eq 1 ]]; then
    echo
    echo "clean-test-temp.sh stops silently on a chmod-000 fixture (SOPS-32) — reproduced." >&2
    exit 1
fi

echo
echo "==> --apply against the same fixtures"
set +e
APPLY_OUT="$(TMPDIR="$FAKE_TMP" ./Scripts/clean-test-temp.sh --apply --min-age 0 2>&1)"
APPLY_STATUS=$?
set -e
echo "--- output ---"
echo "$APPLY_OUT"
echo "--- exit: $APPLY_STATUS ---"

[[ $APPLY_STATUS -eq 0 ]] && pass "--apply exited 0" || fail "--apply exited $APPLY_STATUS"
[[ -e "$READABLE_DIR" ]] && fail "readable fixture was not removed" || pass "readable fixture was swept"
grep -qi "removed" <<<"$APPLY_OUT" && pass "--apply printed its removal summary" \
    || fail "--apply never printed a removal summary — it stopped before reaching it"

if [[ $FAIL -eq 1 ]]; then
    exit 1
fi

echo
echo "All SOPS-32 checks passed."
