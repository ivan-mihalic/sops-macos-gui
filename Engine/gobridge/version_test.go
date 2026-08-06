package gobridge

import (
	"regexp"
	"strings"
	"testing"
)

// The freshness check compares these against upstream releases, so they must be
// bare semver with no "v" prefix and no build metadata.
func TestEngineVersionsAreBareSemver(t *testing.T) {
	semver := regexp.MustCompile(`^\d+\.\d+\.\d+$`)

	for name, got := range map[string]string{
		"sops": SopsVersion(),
		"age":  AgeVersion(),
	} {
		if !semver.MatchString(got) {
			t.Errorf("%s version %q is not bare semver", name, got)
		}
	}
}

// A stale hand-maintained constant is worse than no check at all, so the sops
// version must come from the module we actually linked.
func TestSopsVersionMatchesLinkedModule(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	want := "version: " + SopsVersion()
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
