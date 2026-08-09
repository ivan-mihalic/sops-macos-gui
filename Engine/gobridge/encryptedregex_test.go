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

// A rule that compiles perfectly and matches nothing in *this* document
// produces a file with complete sops metadata, a valid MAC, and every value
// in cleartext. `sops --decrypt` reads it back without complaint, so nothing
// downstream ever notices. From the user's side it is indistinguishable from
// a successful encryption, which is the app claiming a protection it did not
// deliver.
//
// The compile guard cannot see this case: `^nothing_here$` is a valid regex.
func TestEncryptRefusesARuleThatEncryptsNothingInThisDocument(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: `^no_key_in_this_file_matches_this$`,
	})
	if err == nil {
		t.Fatalf("Encrypt accepted a rule that encrypted nothing; it produced:\n%s", encrypted)
	}
	if !strings.Contains(err.Error(), "no_key_in_this_file_matches_this") {
		t.Errorf("the refusal does not name the rule the user has to fix: %v", err)
	}
	// The whole point of the refusal is that the plaintext must not be
	// written anywhere, including into the error a caller may log.
	for _, secret := range []string{"hunter2", "sk-live-abc123"} {
		if strings.Contains(err.Error(), secret) {
			t.Errorf("the refusal echoed a secret value from the document")
		}
	}
}

// The guard must not fire on a rule that matches *some* keys — partial
// encryption is what encrypted_regex is for, and refusing it would break
// every correct use. This is the same document as the test above with a rule
// that does match, so a guard implemented as "always refuse" fails here.
func TestEncryptAcceptsARuleThatMatchesSomeKeys(t *testing.T) {
	key := newAgeKeyPair(t)

	if _, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: secretKeyRegex,
	}); err != nil {
		t.Fatalf("a rule matching two of this document's keys was refused: %v", err)
	}
}

// A document with no values at all has nothing to encrypt, and that is not a
// failure of the rule. Refusing it would turn "you have an empty file" into
// "your .sops.yaml is broken".
func TestEncryptAcceptsADocumentWithNoValues(t *testing.T) {
	key := newAgeKeyPair(t)

	if _, err := Encrypt([]byte("{}\n"), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: secretKeyRegex,
	}); err != nil {
		t.Fatalf("an empty document was refused: %v", err)
	}
}
