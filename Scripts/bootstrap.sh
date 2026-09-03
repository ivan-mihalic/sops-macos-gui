#!/usr/bin/env bash
# Everything a fresh clone needs before opening Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "need: brew install xcodegen"; exit 1; }

echo "==> building the SOPS bridge"
Engine/build-xcframework.sh

echo "==> generating SopsGUI.xcodeproj"
xcodegen generate

# SOPS-49. Xcode hledá profil podle jména (PROVISIONING_PROFILE_SPECIFIER)
# výhradně tady; profil sám bydlí mimo repo, protože do repa nepatří nic
# z Apple podepisovacího řetězce. Bez něj build spadne na
# „requires a provisioning profile" — což je lepší než tichý build, který se
# nespustí, ale na čerstvém klonu to vypadá jako vada projektu, ne jako
# chybějící soubor. Proto se instaluje tady a řekne se to nahlas.
echo "==> installing the provisioning profile for Xcode"
profile="${SOPS_GUI_PROVISIONING_PROFILE:-$HOME/Development/_apple-developer-id/mac_studio/SopsGUI.provisionprofile}"
if [ -f "$profile" ]; then
    destination="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
    mkdir -p "$destination"
    # Jméno souboru musí být UUID profilu — Xcode ten adresář indexuje podle
    # obsahu, ale nástroje kolem něj (a starší Xcode) čekají tenhle tvar.
    uuid="$(security cms -D -i "$profile" 2>/dev/null \
        | plutil -extract UUID raw -o - - 2>/dev/null || true)"
    if [ -n "$uuid" ]; then
        cp "$profile" "$destination/$uuid.provisionprofile"
        echo "    $uuid.provisionprofile"
    else
        echo "    ⚠️  $profile se nepodařilo přečíst — Xcode build se nepodepíše"
    fi
else
    cat <<'EOF'
    ⚠️  Provisioning profil nenalezen.

    Bez něj se `xcodebuild` zastaví na „requires a provisioning profile", a to
    je záměr: appka nese restricted entitlement keychain-access-groups a bez
    profilu, který ho autorizuje, by se nespustila vůbec (ADR 0006).

    Postup, jak profil vyrobit, je v _ai-memory u tiketu SOPS-49. Jinou cestu
    lze určit proměnnou SOPS_GUI_PROVISIONING_PROFILE.

    Testy (`./Scripts/test.sh`) a snapshoty profil NEPOTŘEBUJÍ — týká se to jen
    stavby .app.
EOF
fi

echo "==> done. Open SopsGUI.xcodeproj, or run: ./Scripts/test.sh"
