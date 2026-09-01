package gobridge

import (
	"strings"
	"testing"
)

// dotenvPlain is the fixture from the task brief: a normal secret, a comment,
// and an empty value — the three shapes the dotenv store treats specially.
const dotenvPlain = "DB_URL=postgres://x\nAPI_KEY=secret\n# comment\nEMPTY=\n"

// TestDotenvEncryptDecryptRoundTrip exercises the bridge's own Encrypt/Decrypt
// against each other, with no CLI involved. It is the fast check that the new
// Format case wires into the same code path YAML already uses.
func TestDotenvEncryptDecryptRoundTrip(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if !strings.Contains(string(enc), "sops_mac=") {
		t.Errorf("encrypted dotenv is missing sops metadata (sops_mac=): %s", enc)
	}
	if strings.Contains(string(enc), "secret") {
		t.Errorf("encrypted dotenv still contains the plaintext secret value")
	}

	dec, err := Decrypt(enc, FormatDotenv, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	// The dotenv store round-trips keys and values 1:1 and keeps comments, but
	// is not guaranteed to reproduce the exact byte layout (e.g. trailing
	// newline handling), so compare the parsed line sets rather than raw bytes.
	if got, want := dotenvLines(string(dec)), dotenvLines(dotenvPlain); !equalLineSets(got, want) {
		t.Errorf("round trip did not preserve content:\n got:  %v\n want: %v", got, want)
	}
}

// TestDotenvBridgeEncryptsCLIDecrypts proves the bridge's dotenv output is a
// file the real sops CLI accepts and reads back correctly — the compatibility
// oracle used throughout this package (see document_test.go's cliDecrypt).
func TestDotenvBridgeEncryptsCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// The CLI infers dotenv from the .env suffix (formats.IsEnvFile).
	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "enc.env", enc)))

	for _, want := range []string{"DB_URL=postgres://x", "API_KEY=secret", "EMPTY="} {
		if !strings.Contains(out, want) {
			t.Errorf("CLI decrypt output missing %q; got:\n%s", want, out)
		}
	}
}

// TestDotenvCLIEncryptsBridgeDecrypts is the opposite direction: a file the
// real sops CLI produced must decrypt cleanly through the bridge.
func TestDotenvCLIEncryptsBridgeDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	in := writeTemp(t, "plain.env", []byte(dotenvPlain))
	enc := runSopsCLI(t, key, nil, "--encrypt", "--age", key.Public, in)

	dec, err := Decrypt(enc, FormatDotenv, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	if got, want := dotenvLines(string(dec)), dotenvLines(dotenvPlain); !equalLineSets(got, want) {
		t.Errorf("round trip did not preserve content:\n got:  %v\n want: %v", got, want)
	}
}

// dotenvLines splits a dotenv document into its non-empty lines, so
// comparisons do not depend on trailing-newline details either side of the
// round trip is free to differ on.
func dotenvLines(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

func equalLineSets(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
