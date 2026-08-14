#!/usr/bin/env bash
# Removes this suite's leftover fixture directories from `$TMPDIR`.
#
#   ./Scripts/clean-test-temp.sh            — show what would be removed
#   ./Scripts/clean-test-temp.sh --apply    — actually remove it
#   ./Scripts/clean-test-temp.sh --apply --min-age 0
#                                           — include entries touched in the last hour
#
# Why this exists: the tests build their scratch trees as
# `$TMPDIR/<label>-<UUID>` and — as of the audit on 2026-08-10 — almost none of
# them delete the tree afterwards. Three days of running `swift test` in a loop
# left 2 529 `large-*` directories holding 506 copies of a 200 MB
# `huge-asset.bin`: 113 GB, on a disk that was down to 71 GB free. Another
# ~156 000 smaller directories (`project-*`, `vm-fixture-*`, `sops-spike-*`,
# `repo-*`, `atomicwriter-*`, `shell-harness-*`, `cli-decrypt-*`, …) came from
# the same habit. macOS does not reap `$TMPDIR` while the login session lives,
# so this grows without bound until something else on the machine fails.
#
# What it matches: entries whose name ends in a UUID, i.e. `<label>-<UUID>`
# with an optional extension. That is the shape every fixture helper in this
# repo produces, and it is narrow enough not to touch the OS's own scratch
# files (`ibtoold-*`, `TemporaryDirectory.*`, `com.apple.*`, sockets, caches).
#
# Also `go-build<digits>` — a second, unrelated shape, not a fixture at all:
# `go build`'s own per-invocation cache directory (`cmd/go/internal/work`
# names it that way), one per run of `Engine/build-xcframework.sh` and every
# `go test`/`go vet` in `Engine/gobridge`. It carries no UUID, so the pattern
# above never matched it — measured on this machine (#26 item 5): 2.36 GB
# across leftover `go-build*` directories that this script had never once
# swept. Same age floor, same reasoning: `go build` removes its own cache
# directory on a normal exit, so anything old enough to clear `-mmin` is one a
# killed or crashed `go` process left behind, not one still in use.
#
# What it deliberately does NOT do: match on a hand-maintained list of label
# prefixes. There are 75+ of them across the suite and a stale list silently
# under-cleans, which is the failure mode this script exists to prevent.
# `go-build*` is a named exception because it is not a `<label>-<UUID>`
# fixture in the first place — extending the *regex* to cover it would either
# loosen the UUID requirement (matching things that are not fixtures either)
# or bolt on a second, differently-shaped pattern inline. It gets its own
# `find`, kept to exactly this one name, rather than either.
#
# The age floor is the safety catch: a run in another terminal, or a test still
# executing right now, owns entries younger than the floor. Default is 60
# minutes. Pass `--min-age 0` only when you know nothing else is running.
set -euo pipefail

APPLY=0
MIN_AGE=60

while [[ $# -gt 0 ]]; do
    case "$1" in
        --apply)   APPLY=1; shift ;;
        --min-age) MIN_AGE="$2"; shift 2 ;;
        -h|--help) sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

TMP="${TMPDIR:-/tmp}"
TMP="${TMP%/}"

UUID_TAIL='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

# `find -E` for the extended regex; `-maxdepth 1` so a fixture that itself
# contains UUID-named children is removed once, at its root, not walked into.
# `-mmin +N` is the age floor. NUL-delimited throughout — a stray newline in a
# fixture name must not become two paths. Read with a `while` loop rather than
# `mapfile -d ''`, which needs bash 4: `/bin/bash` here is still 3.2, and this
# script has to work whichever bash the caller's PATH finds first.
VICTIMS=()
while IFS= read -r -d '' entry; do
    VICTIMS+=("$entry")
done < <(
    find -E "$TMP" -maxdepth 1 \
        -regex ".*/[A-Za-z0-9._-]+-${UUID_TAIL}(\.[A-Za-z0-9]+)?" \
        -mmin "+${MIN_AGE}" \
        -print0 2>/dev/null || true
)

# `go-build<digits>` — see the header comment for why this is a second,
# separate `find` rather than folded into the pattern above.
while IFS= read -r -d '' entry; do
    VICTIMS+=("$entry")
done < <(
    find -E "$TMP" -maxdepth 1 \
        -regex ".*/go-build[0-9]+" \
        -mmin "+${MIN_AGE}" \
        -print0 2>/dev/null || true
)

if [[ ${#VICTIMS[@]} -eq 0 ]]; then
    echo "nothing to clean in $TMP (age floor: ${MIN_AGE} min)"
    exit 0
fi

# `xargs` splits a set this large (six figures of entries) across several `du`
# invocations, so each batch prints its own `total` line. Summing every `total`
# is the only way to get the real figure — taking `tail -1` reports the last
# batch alone, which understated 120 GB as 1.4 GB when this was first written.
#
# A victim this process cannot read — an unrelated test's chmod 000 fixture
# (FileListView, SecretFileCreator) still sitting there because the process
# died before its own `defer` restored permissions — makes `du` exit non-zero
# for that one batch. Under `pipefail`, that non-zero status is what the
# `SIZE=$(...)` assignment sees; under `set -e`, an assignment that fails
# aborts the script right there, before it prints anything at all. That is
# SOPS-32: the backstop against a full disk quietly stops sweeping and looks
# like it ran. The `|| true` below is scoped to exactly this one assignment —
# `pipefail` stays on everywhere else, which is what makes the rest of this
# script's exit status still worth trusting.
#
# `du`'s stderr on the failing entries is kept (not `2>/dev/null`'d away) and
# parsed for the paths it named, so a skipped entry is reported, not assumed
# swept.
DU_ERR="$(mktemp)"
trap 'rm -f "$DU_ERR"' EXIT

SIZE=$(
    printf '%s\0' "${VICTIMS[@]}" \
        | xargs -0 du -ck 2>"$DU_ERR" \
        | awk '$2 == "total" { kb += $1 }
               END { if (kb >= 1048576) printf "%.1fG", kb/1048576;
                     else if (kb >= 1024) printf "%.0fM", kb/1024;
                     else printf "%dK", kb }'
) || true

UNREADABLE=()
while IFS= read -r path; do
    UNREADABLE+=("$path")
done < <(sed -n -E 's/^du: (.*): .*/\1/p' "$DU_ERR" | sort -u)

if [[ $APPLY -eq 0 ]]; then
    echo "would remove ${#VICTIMS[@]} entries (${SIZE}) from $TMP"
    echo "  age floor: older than ${MIN_AGE} min"
    echo "  sample:"
    printf '    %s\n' "${VICTIMS[@]:0:5}" | sed "s|$TMP/||"
    echo "  re-run with --apply to delete"
    if [[ ${#UNREADABLE[@]} -gt 0 ]]; then
        echo
        echo "  ⚠️  could not fully read ${#UNREADABLE[@]} entrie(s) — size above may undercount them, and --apply may not be able to remove them either:"
        printf '      %s\n' "${UNREADABLE[@]}" | sed "s|$TMP/||"
        echo "  fix permissions by hand (chmod -R u+rwX <path>) and re-run, or remove it directly"
    fi
    exit 0
fi

# Same shape of failure is possible here: `rm -rf` exits non-zero for a
# victim it cannot fully remove, and this is the last command in the script,
# so under `set -e`/`pipefail` it would abort before the summary below ever
# prints. `|| true` keeps the sweep going; what actually remains afterward is
# then checked directly rather than assumed from the exit status.
printf '%s\0' "${VICTIMS[@]}" | xargs -0 rm -rf || true

REMAINING=()
for entry in "${VICTIMS[@]}"; do
    [[ -e "$entry" ]] && REMAINING+=("$entry")
done
removed=$(( ${#VICTIMS[@]} - ${#REMAINING[@]} ))

echo "removed ${removed} entries (${SIZE}) from $TMP"
echo "$TMP is now $(du -sh "$TMP" 2>/dev/null | cut -f1)"
if [[ ${#REMAINING[@]} -gt 0 ]]; then
    echo
    echo "  ⚠️  could not remove ${#REMAINING[@]} entrie(s) — left in place:"
    printf '      %s\n' "${REMAINING[@]}" | sed "s|$TMP/||"
    echo "  fix permissions by hand (chmod -R u+rwX <path>) and re-run, or remove it directly"
fi
