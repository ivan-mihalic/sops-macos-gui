package gobridge

import (
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"testing"
)

// A version this bridge could not determine must never be reported as a
// number, because every consumer of it does a *comparison*. "0.0.0" is the
// worst possible sentinel: an embedded sops of 0.0.0 makes any installed sops
// look newer, so ExternalToolCheck's "warn if older than the embedded engine"
// silently becomes "always OK", and EngineFreshnessCheck compares 0.0.0
// against upstream and reports a confident warning about a version that was
// never actually read. UnknownVersion is not parseable as semver, so a
// consumer must handle it explicitly rather than accidentally comparing
// favourably against it.
func TestUnknownVersionIsNotAParseableVersionNumber(t *testing.T) {
	if UnknownVersion == "" {
		t.Fatal("UnknownVersion is empty; it must be a legible marker, not a blank string")
	}
	semver := regexp.MustCompile(`^v?\d+(\.\d+)*$`)
	if semver.MatchString(UnknownVersion) {
		t.Errorf("UnknownVersion %q parses as a version number; a consumer would compare against it instead of noticing it is unknown", UnknownVersion)
	}
}

// goModVersions reads the versions this module actually declares. Independent
// of debug.ReadBuildInfo, which is what SopsVersion/AgeVersion use — so a
// regression that hardcodes, truncates or falls back to a constant in either
// of those shows up as a mismatch here.
func goModVersions(t *testing.T) map[string]string {
	t.Helper()
	_, thisFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("runtime.Caller: could not determine this file's path")
	}
	engineDir := filepath.Dir(filepath.Dir(thisFile))

	data, err := os.ReadFile(filepath.Join(engineDir, "go.mod"))
	if err != nil {
		t.Fatalf("read go.mod: %v", err)
	}

	want := map[string]string{
		"github.com/getsops/sops/v3": "",
		"filippo.io/age":             "",
	}
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if _, tracked := want[fields[0]]; tracked && want[fields[0]] == "" {
			want[fields[0]] = strings.TrimPrefix(fields[1], "v")
		}
	}
	for path, version := range want {
		if version == "" {
			t.Fatalf("go.mod does not declare a version for %s", path)
		}
	}
	return want
}

// The load-bearing half of I2's coverage. Before this test, AgeVersion()
// could be replaced wholesale with `return "0.0.0"` and the whole Go suite
// stayed green — TestEngineVersionsAreBareSemver only asserted the *shape*,
// which "0.0.0" satisfies. Pinning the probed output to what go.mod declares
// means the fallback path cannot be mistaken for the real one.
func TestProbedVersionsMatchTheModulesActuallyDeclared(t *testing.T) {
	declared := goModVersions(t)
	sopsVersion, ageVersion := probeEngineVersions(t)

	if sopsVersion != declared["github.com/getsops/sops/v3"] {
		t.Errorf("SopsVersion() reported %q, but go.mod declares %q", sopsVersion, declared["github.com/getsops/sops/v3"])
	}
	if ageVersion != declared["filippo.io/age"] {
		t.Errorf("AgeVersion() reported %q, but go.mod declares %q", ageVersion, declared["filippo.io/age"])
	}
}

// The same regression stated as the property that actually matters: neither
// version may come back as the unknown marker in a real build. If it ever
// does, the app has no business claiming to know what it embeds.
func TestProbedVersionsAreNeverUnknownInARealBuild(t *testing.T) {
	sopsVersion, ageVersion := probeEngineVersions(t)
	for name, got := range map[string]string{"sops": sopsVersion, "age": ageVersion} {
		if got == UnknownVersion {
			t.Errorf("%s version came back as %q from a real `go build` binary", name, UnknownVersion)
		}
	}
}

// The two functions must not be wired to the same dependency — a copy-paste
// that made AgeVersion() read the sops module would still produce a valid
// semver and pass every shape check.
func TestSopsAndAgeVersionsAreReadFromDifferentModules(t *testing.T) {
	sopsVersion, ageVersion := probeEngineVersions(t)
	if sopsVersion == ageVersion {
		t.Errorf("sops and age both report %q; the two lookups are probably reading the same module", sopsVersion)
	}
}
