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

# And the SDK, explicitly — the same pin, for the same reason, as
# `snapshots.sh`: `DEVELOPER_DIR` alone leaves SwiftPM deriving an `-sdk` from
# `xcode-select`, which on this machine points at a beta whose SDK the chosen
# toolchain then refuses. The error names the Swift standard library and looks
# nothing like a problem with this project (SOPS-39 task 10).
export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

cd Packages/SopsGUIKit
# `xcrun swift run`, never bare `swift run`: three Swift compilers on this
# machine and only one of them builds this source (CLAUDE.md, "Toolchains").
# `--build-system swiftbuild`, and this is not optional: `swift run`'s
# default engine (llbuild) copies `Localizable.xcstrings` into the module
# bundle **uncompiled**, so every `LocalizedKey` resolves to its own raw key
# and the images come out reading `access.keys.title` instead of "Keys". The
# same disagreement `Scripts/test.sh` documents at length, in the one place
# where it is silent rather than red: a snapshot of raw keys still renders
# (SOPS-39 task 10).
xcrun swift run --build-system swiftbuild --quiet snapshots "$REPO/docs/images" guide-
echo
echo "guide images: $REPO/docs/images"
