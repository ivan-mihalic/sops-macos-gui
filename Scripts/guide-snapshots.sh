#!/bin/bash
# Renders the images `docs/GUIDE.md` embeds, into `docs/images/`.
#
# Deliberately a second script rather than a flag on `snapshots.sh`. The two
# have opposite lifecycles: `.snapshots/` is gitignored scratch for diffing a
# change against the commit before it, `docs/images/` is committed and shipped
# with the documentation. Sharing one entry point would make it one typo away
# to commit 48 review images or to leave the guide's pointing at nothing.
#
# The catalog entries live in `Sources/SnapshotTool/Guide.swift`; everything
# about the toolchain below is the same, and for the same reasons, as
# `snapshots.sh` — read that one's comments first.
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="$(pwd)"

for dev in /Applications/Xcode-27.0.0-Beta.4.app /Applications/Xcode.app; do
  [ -d "$dev" ] && export DEVELOPER_DIR="$dev/Contents/Developer" && break
done

cd Packages/SopsGUIKit
# `xcrun swift run`, never bare `swift run`: three Swift compilers on this
# machine and only one of them builds this source (CLAUDE.md, "Toolchains").
xcrun swift run --quiet snapshots "$REPO/docs/images" guide-
echo
echo "guide images: $REPO/docs/images"
