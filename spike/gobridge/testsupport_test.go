package gobridge

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"testing"

	"filippo.io/age"
)

// ageKeyPair is a throwaway identity generated per test. Nothing here is ever
// written to the repo — keys live in t.TempDir() and die with the test.
type ageKeyPair struct {
	Private string // AGE-SECRET-KEY-1...
	Public  string // age1...
}

func newAgeKeyPair(t *testing.T) ageKeyPair {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatalf("generate age identity: %v", err)
	}
	return ageKeyPair{Private: id.String(), Public: id.Recipient().String()}
}

// runSopsCLI invokes the real `sops` binary — our compatibility oracle.
// The age identity is handed over via SOPS_AGE_KEY_FILE so that the CLI's own
// key discovery (~/.config/sops/age/keys.txt) can never influence the result.
func runSopsCLI(t *testing.T, key ageKeyPair, stdin []byte, args ...string) []byte {
	t.Helper()

	keyFile := filepath.Join(t.TempDir(), "keys.txt")
	if err := os.WriteFile(keyFile, []byte(key.Private+"\n"), 0o600); err != nil {
		t.Fatalf("write age key file: %v", err)
	}

	cmd := exec.Command("sops", args...)
	cmd.Env = append(os.Environ(), "SOPS_AGE_KEY_FILE="+keyFile)
	cmd.Stdin = bytes.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("sops %v failed: %v\nstderr: %s", args, err, stderr.String())
	}
	return stdout.Bytes()
}

// writeTemp writes content to a uniquely named file and returns its path.
func writeTemp(t *testing.T, name string, content []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, content, 0o600); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
	return path
}
