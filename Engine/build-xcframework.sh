#!/usr/bin/env bash
# Builds the Go SOPS bridge as an arm64 c-archive and wraps it in an xcframework
# that SwiftPM / Xcode can link against.
set -euo pipefail

cd "$(dirname "$0")"

BUILD=build
STAGE="$BUILD/arm64"
OUT="$BUILD/SopsBridge.xcframework"

# Must match `platforms:` in Package.swift, otherwise ld warns on every object
# file. Raise this in one place once the minimum macOS version is settled.
DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-26.0}"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
# Go picks the SDK default unless cgo is told explicitly.
export CGO_CFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET"
export CGO_LDFLAGS="-mmacosx-version-min=$DEPLOYMENT_TARGET"

rm -rf "$BUILD"
mkdir -p "$STAGE/include"

echo "==> go build -buildmode=c-archive (darwin/arm64)"
CGO_ENABLED=1 GOOS=darwin GOARCH=arm64 \
  go build -buildmode=c-archive -o "$STAGE/libsopsbridge.a" ./cshim

mv "$STAGE/libsopsbridge.h" "$STAGE/include/libsopsbridge.h"

# The module map is what lets Swift `import CSopsBridge`.
cat > "$STAGE/include/module.modulemap" <<'EOF'
module CSopsBridge {
    header "libsopsbridge.h"
    export *
}
EOF

echo "==> xcodebuild -create-xcframework"
xcodebuild -create-xcframework \
  -library "$STAGE/libsopsbridge.a" \
  -headers "$STAGE/include" \
  -output "$OUT" >/dev/null

echo "==> done: $OUT"
du -sh "$OUT"
