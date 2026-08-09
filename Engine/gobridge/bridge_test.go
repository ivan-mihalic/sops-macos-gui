package gobridge

import (
	"strings"
	"testing"
)


// TestEncryptRefusesRecipientsThatWouldLeakOrExecute covers the three ways the
// encrypt path could betray the user through its recipients argument.
//
// The decrypt path has guarded all three since M0 (`parseDecryptionIdentities`).
// The encrypt path had none of them, which is an asymmetry rather than an
// oversight in reasoning — and `sops_encrypt_yaml` is an exported C symbol, so
// M3's "create a new encrypted file" will reach it.
func TestEncryptRefusesRecipientsThatWouldLeakOrExecute(t *testing.T) {
	const canary = "AGE-SECRET-KEY-1SHOULDNEVERAPPEARINANERRORMESSAGE0000000000000000"

	t.Run("a private key pasted into the recipients field never reaches the message", func(t *testing.T) {
		_, err := Encrypt([]byte("a: b\n"), FormatYAML, EncryptOpts{
			AgeRecipients: []string{canary},
		})
		if err == nil {
			t.Fatal("a private key was accepted as a recipient")
		}
		if strings.Contains(err.Error(), canary) {
			t.Fatalf("the private key is in the error message: %v", err)
		}
		// Upstream's own wording quotes the whole input; make sure we are not
		// simply relaying a shorter slice of it.
		if strings.Contains(err.Error(), "SHOULDNEVERAPPEAR") {
			t.Fatalf("a fragment of the private key is in the error message: %v", err)
		}
	})

	t.Run("a plugin-shaped recipient is refused rather than executed", func(t *testing.T) {
		// `age1<name>1<data>` makes upstream exec `age-plugin-<name>` from
		// $PATH, with no absolute path and no timeout, on a name that can come
		// from a cloned repository's .sops.yaml.
		_, err := Encrypt([]byte("a: b\n"), FormatYAML, EncryptOpts{
			AgeRecipients: []string{"age1yubikey1qwbmkfqzrqzc4dm5dqrgcnpq6r0dsmrpqzr"},
		})
		if err == nil {
			t.Fatal("a plugin recipient was accepted")
		}
		if !strings.Contains(err.Error(), "plugin") {
			t.Fatalf("refused for the wrong reason: %v", err)
		}
	})

	t.Run("a real recipient still works", func(t *testing.T) {
		key := newAgeKeyPair(t)
		if _, err := Encrypt([]byte("a: b\n"), FormatYAML, EncryptOpts{
			AgeRecipients: []string{key.Public},
		}); err != nil {
			t.Fatalf("a native recipient was refused: %v", err)
		}
	})
}

// TestEncryptRefusesARegexThatWouldEncryptNothing is the one that matters most.
//
// `sops.Tree.shouldBeEncrypted` does `matched, _ := regexp.Match(...)` and
// drops the error, so a regex that does not compile makes every value "not
// matched". The result is a file with complete sops metadata, a valid MAC, and
// every secret in cleartext — which `sops --decrypt` reads back without
// complaint, because as far as the format is concerned nothing is wrong.
func TestEncryptRefusesARegexThatWouldEncryptNothing(t *testing.T) {
	key := newAgeKeyPair(t)

	_, err := Encrypt([]byte("password: hunter2\n"), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: "(",
	})
	if err == nil {
		t.Fatal("an uncompilable encrypted_regex was accepted; the file would have been " +
			"written in plaintext with a valid MAC")
	}
	if !strings.Contains(err.Error(), "not a valid regular expression") {
		t.Fatalf("refused for the wrong reason: %v", err)
	}
}
