#!/usr/bin/env bash
# Renders the view catalog to PNG snapshots (`Packages/SopsGUIKit/.snapshots/`).
#
#   ./Scripts/snapshots.sh            — everything
#   ./Scripts/snapshots.sh wizard     — only snapshots with "wizard" in the name
#
# Why this instead of screenshotting the running app: see the header comment
# of `Packages/SopsGUIKit/Sources/SnapshotTool/Snapshot.swift`. Short version —
# it needs no window server, no display, and no permissions, so it works
# headless (including over SSH, in a `Background` launchd session, or in CI)
# and is deterministic enough to diff between commits.
set -euo pipefail
cd "$(dirname "$0")/../Packages/SopsGUIKit"

for dev in /Applications/Xcode-27.0.0-Beta.4.app /Applications/Xcode.app; do
  [ -d "$dev" ] && export DEVELOPER_DIR="$dev/Contents/Developer" && break
done

# And the SDK, explicitly. `DEVELOPER_DIR` alone is not enough: SwiftPM
# compiles Package.swift with an `-sdk` it derives from the environment, and
# on a machine whose `xcode-select` points at an Xcode beta that inherits the
# *beta's* SDK — which the chosen toolchain then refuses ("this SDK is not
# supported by the compiler … built with Apple Swift version 6.4, while this
# compiler is 6.3.3"). The failure names the Swift standard library and looks
# nothing like a problem with this project.
export SDKROOT="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"

# `xcrun swift run`, never bare `swift run`: this machine has three Swift
# compilers (see this repo's CLAUDE.md, "Toolchains" section). Bare `swift`
# resolves through PATH to a swiftly-managed open-source toolchain that is
# not the one this project builds and tests with, and it fails on this exact
# source with errors like "initializer is inaccessible due to 'private'" that
# neither Xcode-bundled compiler on this machine raises. `xcrun` picks the
# right toolchain regardless of what a shell's PATH happens to resolve first.
xcrun swift run --quiet snapshots .snapshots "$@"
echo
echo "snapshots: $(pwd)/.snapshots"
