package gobridge

import (
	"bytes"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"testing"
)

var (
	probeOnce  sync.Once
	probedSops string
	probedAge  string
	probeErr   error
)

// probeEngineVersions returns the real SopsVersion()/AgeVersion() output, as
// observed from an ordinary `go build` binary rather than this `go test`
// process. That distinction matters: `debug.ReadBuildInfo()` never
// populates info.Deps inside a `go test` binary (golang/go#33976, still open
// on the go1.26 toolchain this module builds with -- info.Main.Path gets
// populated, info.Deps does not). Calling SopsVersion()/AgeVersion()
// directly from *this* process would therefore only ever observe their
// "0.0.0" not-found fallback, regardless of whether the real implementation
// is correct -- exercising nothing. `go build` output does not have this
// gap, and it is also the build shape that ships (build-xcframework.sh runs
// `go build -buildmode=c-archive`, not `go test`), so building and running
// Engine/internal/versionprobe is what actually verifies the linked module
// versions.
func probeEngineVersions(t *testing.T) (sopsVersion, ageVersion string) {
	t.Helper()
	probeOnce.Do(func() {
		_, thisFile, _, ok := runtime.Caller(0)
		if !ok {
			probeErr = fmt.Errorf("runtime.Caller: could not determine this file's path")
			return
		}
		engineDir := filepath.Dir(filepath.Dir(thisFile)) // Engine/gobridge -> Engine

		// `t.TempDir()`, not `os.MkdirTemp`: cleanup is registered with the
		// test itself (`t.Cleanup`, removed once the test that triggered
		// this `sync.Once` completes) rather than depending on a
		// package-level `TestMain` to `RemoveAll` a hand-tracked path after
		// every test in the package has finished — one mechanism instead of
		// two, and the idiomatic one. (`Scripts/clean-test-temp.sh` is
		// specifically the Swift-side `swift test` backstop for
		// `$TMPDIR/<label>-<UUID>` fixtures and was never scoped to this Go
		// module's own temp dirs either way — `t.TempDir()`'s own
		// `<TestName><random>` naming doesn't change that.) Safe to let
		// expire with this test's own lifetime: `dir` and `bin` are only
		// ever used inside this closure, to build and run the probe binary
		// and capture its output into `probedSops`/`probedAge` before
		// returning — nothing outside this closure, including a later test
		// that hits the memoized `sync.Once`, ever touches the directory
		// again.
		dir := t.TempDir()

		bin := filepath.Join(dir, "versionprobe")
		build := exec.Command("go", "build", "-o", bin, "./internal/versionprobe")
		build.Dir = engineDir
		var buildOut bytes.Buffer
		build.Stdout = &buildOut
		build.Stderr = &buildOut
		if err := build.Run(); err != nil {
			probeErr = fmt.Errorf("go build versionprobe: %w\n%s", err, buildOut.String())
			return
		}

		run := exec.Command(bin)
		out, err := run.Output()
		if err != nil {
			probeErr = fmt.Errorf("run versionprobe: %w", err)
			return
		}
		fields := strings.Fields(string(out))
		if len(fields) != 2 {
			probeErr = fmt.Errorf("versionprobe printed %q, want two space-separated versions", out)
			return
		}
		probedSops, probedAge = fields[0], fields[1]
	})
	if probeErr != nil {
		t.Fatalf("probeEngineVersions: %v", probeErr)
	}
	return probedSops, probedAge
}

// The freshness check compares these against upstream releases, so they must be
// bare semver with no "v" prefix and no build metadata.
func TestEngineVersionsAreBareSemver(t *testing.T) {
	semver := regexp.MustCompile(`^\d+\.\d+\.\d+$`)
	sopsVersion, ageVersion := probeEngineVersions(t)

	for name, got := range map[string]string{
		"sops": sopsVersion,
		"age":  ageVersion,
	} {
		if !semver.MatchString(got) {
			t.Errorf("%s version %q is not bare semver", name, got)
		}
	}
}

// A stale hand-maintained constant is worse than no check at all, so the sops
// version must come from the module we actually linked (SopsVersion, probed
// above) -- not from sops's own version.Version, which is a hand-maintained
// literal in upstream sops's source and is what this test's "actual output"
// side (Encrypt) draws from. That keeps the two sides of this comparison
// genuinely independent: one from the module system, one from sops's own
// hand-maintained constant. A mismatch is exactly the release-automation
// failure mode -- sops tagging a release without bumping that internal
// constant -- worth catching.
func TestSopsVersionMatchesLinkedModule(t *testing.T) {
	sopsVersion, _ := probeEngineVersions(t)

	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	want := "version: " + sopsVersion
	if !containsTrimmedLine(string(encrypted), want) {
		t.Errorf("encrypted file does not carry %q", want)
	}
}

// containsTrimmedLine reports whether haystack has a line whose
// leading/trailing whitespace-trimmed content equals needle exactly.
func containsTrimmedLine(haystack, needle string) bool {
	for _, line := range strings.Split(haystack, "\n") {
		if strings.TrimSpace(line) == needle {
			return true
		}
	}
	return false
}
