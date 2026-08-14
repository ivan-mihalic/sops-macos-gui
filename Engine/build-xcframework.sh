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

# A hash of every Go source file that fed this build, so a later caller
# (`Scripts/check-xcframework-freshness.sh`, run from `Scripts/test.sh`) can
# tell whether the archive still matches what is on disk without relying on
# anyone remembering to re-run this script by hand — see that script's own
# header comment for the incident this closes (#26 item 1). `find | sort |
# shasum` per file, then `shasum` of the whole sorted list: sorting makes the
# result independent of directory-enumeration order, and hashing per file
# rather than concatenating raw bytes means a file that starts identically to
# where another one used to end can't produce a matching digest by accident.
# Kept in lockstep with `Scripts/check-xcframework-freshness.sh`'s own copy of
# this exact pipeline by a comment in both places, not by a shared library
# file — the two callers are a bash script that `cd`s into `Engine/` and one
# that runs from the repo root, and duplicating five lines is cheaper than a
# sourcing convention that has to work from both.
find . \( -name '*.go' -o -name 'go.mod' -o -name 'go.sum' \) -not -path './build/*' -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 \
  | shasum -a 256 \
  | awk '{print $1}' > "$BUILD/.source-fingerprint"

echo "==> done: $OUT"
du -sh "$OUT"
