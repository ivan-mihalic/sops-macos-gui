package gobridge

import (
	"strings"
	"testing"
)

const secretKeyRegex = `^(password|api_key)$`

// With encrypted_regex only matching keys are ciphertext; everything else must
// stay readable. Getting this wrong silently leaks or silently over-encrypts.
func TestEncryptedRegexLeavesNonMatchingValuesInPlaintext(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: secretKeyRegex,
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	out := string(encrypted)

	if !strings.Contains(out, "host: localhost") {
		t.Errorf("non-matching key was encrypted; output:\n%s", out)
	}
	if strings.Contains(out, "hunter2") || strings.Contains(out, "sk-live-abc123") {
		t.Errorf("matching key left in plaintext; output:\n%s", out)
	}
	if !strings.Contains(out, "encrypted_regex: "+secretKeyRegex) {
		t.Errorf("encrypted_regex not recorded in sops metadata; output:\n%s", out)
	}
}

func TestSopsCLIDecryptsBridgeEncryptedRegexFile(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: secretKeyRegex,
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	path := writeTemp(t, "secrets.yaml", encrypted)
	got := runSopsCLI(t, key, nil, "--decrypt", path)

	if string(got) != plainYAML {
		t.Errorf("CLI decrypt mismatch\n got: %q\nwant: %q", got, plainYAML)
	}
}

func TestDecryptsCLIEncryptedRegexFile(t *testing.T) {
	key := newAgeKeyPair(t)
	in := writeTemp(t, "secrets.yaml", []byte(plainYAML))
	encrypted := runSopsCLI(t, key, nil,
		"--encrypt", "--age", key.Public, "--encrypted-regex", secretKeyRegex, in)

	got, err := Decrypt(encrypted, FormatYAML, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	if string(got) != plainYAML {
		t.Errorf("round-trip mismatch\n got: %q\nwant: %q", got, plainYAML)
	}
}
