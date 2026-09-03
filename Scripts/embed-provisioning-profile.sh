#!/usr/bin/env bash
# Kopíruje Developer ID provisioning profil do .app bundlu jako
# `Contents/embedded.provisionprofile` (SOPS-46 / SOPS-49, ADR 0006).
#
# ⚠️ PROČ TO MUSÍ BÝT TVRDÁ CHYBA, KDYŽ PROFIL CHYBÍ
#
# `App/SopsGUI.entitlements` žádá o `keychain-access-groups`. To je restricted
# entitlement: binárku, která ho nese bez profilu, který ho autorizuje, AMFI
# zabije při startu — SIGKILL, žádná hláška, `main` neproběhne. Naměřeno
# 2026-09-03 podepsanou sondou: exit 137.
#
# Build, který profil tiše přeskočí, se tedy podepíše, notarizuje, projde celou
# testovou sadou a na uživatelově Macu se NEOTEVŘE. Proto tenhle skript raději
# shodí build, než aby vyrobil něco takového.
#
# Profil bydlí MIMO repo (`~/Development/_apple-developer-id/`), protože do repa
# nepatří nic z Apple podepisovacího řetězce — CLAUDE.md, „Hard constraints".
set -euo pipefail

PROFILE_HOME="${SOPS_GUI_PROVISIONING_PROFILE:-$HOME/Development/_apple-developer-id/mac_studio/SopsGUI.provisionprofile}"

if [[ -z "${BUILT_PRODUCTS_DIR:-}" || -z "${CONTENTS_FOLDER_PATH:-}" ]]; then
    echo "error: tenhle skript patří do Xcode build fáze (chybí BUILT_PRODUCTS_DIR / CONTENTS_FOLDER_PATH)" >&2
    exit 1
fi

CONTENTS="$BUILT_PRODUCTS_DIR/$CONTENTS_FOLDER_PATH"
DESTINATION="$CONTENTS/embedded.provisionprofile"

if [[ ! -f "$PROFILE_HOME" ]]; then
    cat >&2 <<EOF
error: provisioning profil nenalezen: $PROFILE_HOME

Bez něj by tenhle build nesl entitlement keychain-access-groups, který mu nikdo
neautorizoval — appka by se nespustila vůbec (AMFI, SIGKILL). Build se proto
zastavuje tady, ne až u uživatele.

Profil se vyrábí z App Store Connect API klíče s rolí Admin; postup je
v _ai-memory u tiketu SOPS-49. Jinou cestu si lze určit proměnnou
SOPS_GUI_PROVISIONING_PROFILE.
EOF
    exit 1
fi

# `security cms -D` profil rozbalí; jde o kontrolu, ne o transformaci — do
# bundlu jde původní podepsaný soubor beze změny.
if ! ENTITLEMENTS_PLIST="$(security cms -D -i "$PROFILE_HOME" 2>/dev/null)"; then
    echo "error: $PROFILE_HOME není podepsaný provisioning profil" >&2
    exit 1
fi

# Kanárek na vlastnost, kvůli které tenhle profil existuje. Profil BEZ téhle
# skupiny by prošel podpisem, prošel notarizací a appku by stejně nespustil —
# a chyba by vypadala jako vada v kódu, ne jako špatný profil.
if ! printf '%s' "$ENTITLEMENTS_PLIST" | command grep -q "keychain-access-groups"; then
    echo "error: profil $PROFILE_HOME neautorizuje keychain-access-groups" >&2
    echo "       (profil vyrobený bez toho oprávnění appku nespustí)" >&2
    exit 1
fi

mkdir -p "$CONTENTS"
cp "$PROFILE_HOME" "$DESTINATION"
echo "embedded.provisionprofile ← $PROFILE_HOME"
