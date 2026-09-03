#!/usr/bin/env bash
# Runs from `release`'s PREBUILD_CMD, before anything expensive happens.
#
# Two refusals that both exist because the failure they prevent is silent or
# late. Then the engine build, which is what this hook used to be on its own.
#
# ── 1. Can the signing key actually be read without a prompt? (ticket SOPS-26.3)
#
# `mac-release`'s own preflight step 9 runs
#     security find-generic-password -s https://sparkle-project.org -a "$SPARKLE_KEY_ACCOUNT"
# with no `-w`, which asks only whether the keychain *item* exists. Item
# metadata is readable without authorization, so that check passes whatever
# the ACL says. `sign_update` later reads the secret itself, and *that* is the
# call an ACL can answer with a GUI authorization dialog.
#
# The consequence is a release that builds, signs, notarizes and staples —
# minutes of work — and then stops at the appcast step waiting on a dialog.
# In a non-interactive shell there is nobody to dismiss it, so it does not
# fail: it hangs.
#
# So: sign a throwaway file with the real `sign_update`, in the background
# with a deadline. Fast success means the ACL already grants the signing path
# what it needs. A deadline hit means a prompt is waiting, and it is far
# better to learn that here than after notarization.
#
# ⚠️ It must be `sign_update`, not `security find-generic-password -w`, and
# this was measured rather than assumed. A keychain ACL grants access
# per-application: the first version of this check asked whether
# `/usr/bin/security`, invoked from this shell, could read the key — it could
# not, and timed out, on a machine where the release had succeeded hours
# earlier. That check would have blocked every working release while reading
# as proof of a real problem. The question is only ever whether the tool that
# will actually read the key can read it.
#
# The signature `sign_update` prints is discarded; nothing derived from the
# key is kept, printed or written.
#
# ── 2. Would this release ship a byte-identical app? (ticket SOPS-26.4)
#
# It has already happened once: 0.1.12 was followed by a commit touching only
# `docs/GUIDE.md`, which is not in the bundle, so releasing again would have
# produced the same app and offered every user an update for nothing. That
# was caught by a human noticing.
#
# The check is a DENYLIST of paths known not to reach the bundle, not an
# allowlist of paths that do — and the direction matters. An allowlist has to
# be complete to be safe: a shipping path nobody remembered to list reads as
# "nothing changed" and blocks a real release. A denylist is wrong in the
# harmless direction: a non-shipping path nobody listed reads as "something
# changed" and the release proceeds, exactly as it does today.
#
# Set ALLOW_UNCHANGED_BUNDLE=1 to release anyway — re-releasing an identical
# build is occasionally the right thing (a botched upload, a feed repair).
set -euo pipefail

cd "$(dirname "$0")/.."

fail() { printf '\033[1;31m✗\033[0m %s\n' "$1" >&2; exit 1; }
note() { printf '\033[1;34m▸\033[0m %s\n' "$1"; }

# ── 1 ────────────────────────────────────────────────────────────────────────
account=$(grep -E '^SPARKLE_KEY_ACCOUNT=' release.conf | head -1 | cut -d= -f2- | tr -d "\"'")
signer="${SPARKLE_SIGN_UPDATE:-$HOME/.local/libexec/sparkle/sign_update}"

if [[ -z "$account" ]]; then
    note "no SPARKLE_KEY_ACCOUNT in release.conf — skipping the keychain ACL probe"
elif [[ ! -x "$signer" ]]; then
    note "sign_update not found at $signer — skipping the keychain ACL probe"
else
    probe_file=$(mktemp -t sparkle-acl-probe)
    printf 'probe' > "$probe_file"
    "$signer" --account "$account" "$probe_file" >/dev/null 2>&1 &
    probe=$!
    waited=0
    timed_out=""
    while kill -0 "$probe" 2>/dev/null; do
        if (( waited >= 100 )); then          # 10 s in 0.1 s steps
            kill -9 "$probe" 2>/dev/null || true
            timed_out=1
            break
        fi
        sleep 0.1
        waited=$(( waited + 1 ))
    done
    wait "$probe" 2>/dev/null && signed=1 || signed=""
    rm -f "$probe_file"

    if [[ -n "$timed_out" ]]; then
        fail "signing a throwaway file with the Sparkle key for account '$account' did not
       finish within 10 s. That means its keychain ACL is asking for
       authorization, and in a non-interactive shell nobody can answer — the
       release would hang at the appcast step, after notarizing.
       Grant the signing tool access without prompting, then re-run.
       mac-release's own preflight cannot catch this: it checks only that the
       keychain item exists, which never prompts."
    elif [[ -z "$signed" ]]; then
        fail "sign_update could not sign with the key for account '$account'.
       The key is missing, or its ACL denies the signing tool outright.
       Run '$signer --account $account <any file>' by hand to see what it says."
    fi
    note "Sparkle key signs without a prompt"
fi

# ── 2 ────────────────────────────────────────────────────────────────────────
# Paths that cannot reach the shipped bundle. Anything not listed counts as
# shipping — see the header for why that direction is the safe one.
NON_SHIPPING_PREFIXES=(
    "docs/"
    "Packages/SopsGUIKit/Tests/"
    ".github/"
)
NON_SHIPPING_EXACT=(
    ".gitignore"
    "CLAUDE.md"
    "PROPOSAL.md"
    "README.md"
)

# PREVIOUS_RELEASE_TAG / RELEASE_HEAD exist so this check is testable against
# a known-bad pair of refs — see Scripts/test-release-prebuild.sh. Unset in
# every real run.
previous_tag="${PREVIOUS_RELEASE_TAG:-$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)}"
release_head="${RELEASE_HEAD:-HEAD}"
if [[ -z "$previous_tag" ]]; then
    note "no previous v* tag — nothing to compare against, proceeding"
elif [[ "${ALLOW_UNCHANGED_BUNDLE:-}" == "1" ]]; then
    note "ALLOW_UNCHANGED_BUNDLE=1 — skipping the unchanged-bundle check"
else
    shipping_changes=()
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        skip=""
        for prefix in "${NON_SHIPPING_PREFIXES[@]}"; do
            [[ "$path" == "$prefix"* ]] && { skip=1; break; }
        done
        if [[ -z "$skip" ]]; then
            for exact in "${NON_SHIPPING_EXACT[@]}"; do
                [[ "$path" == "$exact" ]] && { skip=1; break; }
            done
        fi
        [[ -z "$skip" ]] && shipping_changes+=("$path")
    done < <(git diff --name-only "$previous_tag".."$release_head")

    if (( ${#shipping_changes[@]} == 0 )); then
        fail "nothing that reaches the bundle has changed since $previous_tag.
       Releasing would publish a byte-identical app and offer every user an
       update for nothing — this happened once already, after 0.1.12, when the
       only commit since touched docs/GUIDE.md.
       Changed since $previous_tag, all non-shipping:
$(git diff --name-only "$previous_tag".."$release_head" | sed 's/^/         /')
       If you mean to re-release anyway, run with ALLOW_UNCHANGED_BUNDLE=1."
    fi
    # Named, not just counted, when there are few. The denylist below is
    # deliberately permissive — a path nobody listed counts as shipping — so
    # the number on its own can be reassuring about a release that ships
    # nothing. Measured on the first real run after 0.1.14: the only change
    # since the tag was an untracked local backup being removed, which is not
    # on the list, so this said "1 shipping path" about a release that would
    # have produced a byte-identical app. A count cannot show that; the path
    # can.
    if (( ${#shipping_changes[@]} <= 5 )); then
        note "${#shipping_changes[@]} shipping path(s) changed since $previous_tag — check these are real:"
        printf '         %s\n' "${shipping_changes[@]}"
    else
        note "${#shipping_changes[@]} shipping path(s) changed since $previous_tag"
    fi
fi

# ── 3. Entitlements with $(AppIdentifierPrefix) already expanded ─────────────
#
# ⚠️ The release driver signs the app ITSELF, after xcodebuild, with the file
# named by ENTITLEMENTS in release.conf. `codesign` does NOT expand
# `$(AppIdentifierPrefix)` — only Xcode does, from the provisioning profile.
# Measured 2026-09-03: a signature carrying the literal string is treated as an
# unauthorised entitlement and the binary is killed by AMFI at launch.
#
# So the driver gets a resolved copy, generated here from the profile itself
# rather than from a team identifier written down in the repository. It lands
# in the gitignored build/ directory, which is where the driver already puts
# its derived data.
#
# Failing here is deliberate: signing with the unresolved file produces a
# release that installs, passes Gatekeeper, and does not open.
profile="${SOPS_GUI_PROVISIONING_PROFILE:-$HOME/Development/_apple-developer-id/mac_studio/SopsGUI.provisionprofile}"
source_entitlements="App/SopsGUI.entitlements"
resolved_entitlements="build/SopsGUI.resolved.entitlements"

if [[ ! -f "$profile" ]]; then
    fail "provisioning profil nenalezen: $profile — bez něj by se vydal build, který se nespustí"
fi

# `TeamIdentifier.0`, ne `Entitlements.com.apple.developer.team-identifier`:
# `plutil -extract` bere tečku jako oddělovač cesty a nemá jak ji v názvu klíče
# odescapovat, takže druhý tvar vrací prázdno — tiše, s návratovým kódem 0.
team="$(security cms -D -i "$profile" 2>/dev/null \
    | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null || true)"
if [[ -z "$team" ]]; then
    fail "z profilu $profile nešlo přečíst team identifier"
fi

mkdir -p "$(dirname "$resolved_entitlements")"
sed "s/\$(AppIdentifierPrefix)/$team./g" "$source_entitlements" > "$resolved_entitlements"

# Kanárek: kdyby se substituce nechytila, tichý průchod by znamenal přesně tu
# vadu, kterou tenhle krok existuje odvrátit.
if command grep -q 'AppIdentifierPrefix' "$resolved_entitlements"; then
    fail "v $resolved_entitlements zůstala nerozvinutá substituce"
fi
if ! command grep -q "$team\." "$resolved_entitlements"; then
    fail "$resolved_entitlements neobsahuje team prefix — substituce neproběhla"
fi
note "entitlements rozvinuté do $resolved_entitlements"

# ── the engine build this hook has always done ───────────────────────────────
# SKIP_ENGINE_BUILD exists for Scripts/test-release-prebuild.sh, which is about
# the refusals above and has no use for a several-minute build. Unset in every
# real run.
if [[ "${SKIP_ENGINE_BUILD:-}" == "1" ]]; then
    note "SKIP_ENGINE_BUILD=1 — stopping before the engine build"
    exit 0
fi
exec ./Engine/build-xcframework.sh
