// Command versionprobe prints the sops and age versions gobridge reports,
// space-separated, and exits.
//
// It exists solely so Engine/gobridge/version_test.go can observe real
// SopsVersion()/AgeVersion() output. Those functions read
// runtime/debug.ReadBuildInfo().Deps, and Go test binaries never populate
// that field -- see https://github.com/golang/go/issues/33976, still open
// as of the go1.26 toolchain this module builds with (info.Main gets
// populated for a test binary, info.Deps does not). Ordinary `go build`
// output does not have this gap, which is also the build shape that ships
// (Engine/build-xcframework.sh runs `go build -buildmode=c-archive`, not
// `go test`). So the test builds and runs this program instead of calling
// the functions in-process.
package main

import (
	"fmt"

	"github.com/ivan-mihalic/sops-macos-gui/engine/gobridge"
)

func main() {
	fmt.Printf("%s %s\n", gobridge.SopsVersion(), gobridge.AgeVersion())
}
