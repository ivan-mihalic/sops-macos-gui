#!/usr/bin/env bash
# Everything a fresh clone needs before opening Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "need: brew install xcodegen"; exit 1; }

echo "==> building the SOPS bridge"
Engine/build-xcframework.sh

echo "==> generating SopsGUI.xcodeproj"
xcodegen generate

echo "==> done. Open SopsGUI.xcodeproj, or run: cd Packages/SopsGUIKit && swift test"
