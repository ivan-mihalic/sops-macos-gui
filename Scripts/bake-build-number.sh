#!/bin/bash
# Writes the real CFBundleVersion into the built app's Info.plist, plus the
# commit it was built from.
#
# `CURRENT_PROJECT_VERSION` in project.yml is a placeholder, and must stay one.
# Sparkle decides whether an update exists by comparing CFBundleVersion
# (`sparkle:version` in the appcast), not the marketing version — so a constant
# "1" means every release ships build 1 and every installed copy is told it is
# up to date forever. `mac-release` refuses to publish a bundle whose
# CFBundleVersion is <= 1 for exactly that reason; this is what makes it a real
# number. Commit count is monotonic and needs no hand maintenance.
#
# `SopsGUICommit` is the other half: a user reporting "it lost my file" names a
# version, and a version maps to many builds during development. This maps the
# copy in their hands to one commit.
set -euo pipefail

cd "$SRCROOT"

# Hard failure, not a `|| echo 1` fallback. A build number of 1 is precisely
# the state mac-release exists to catch, and producing it quietly here would
# push the discovery to the release that silently never updates anybody.
BUILD="$(git rev-list --count HEAD)"
COMMIT="$(git rev-parse --short HEAD)"
[ "$BUILD" -gt 1 ] || { echo "error: git rev-list --count HEAD returned $BUILD" >&2; exit 1; }

PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
[ -f "$PLIST" ] || { echo "error: no Info.plist at $PLIST" >&2; exit 1; }

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST" \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :SopsGUICommit $COMMIT" "$PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :SopsGUICommit string $COMMIT" "$PLIST"
