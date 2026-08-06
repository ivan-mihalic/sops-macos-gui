package gobridge

import (
	"strings"
	"testing"
)

// A modified ciphertext must be rejected via the MAC, not silently decrypted
// into wrong plaintext. This is the property that makes SOPS files tamper-evident.
func TestDecryptRejectsTamperedCiphertext(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// Flip one base64 character inside an ENC[...] payload.
	tampered := strings.Replace(string(encrypted), "data:", "data:A", 1)

	if _, err := Decrypt([]byte(tampered), FormatYAML, key.Private); err == nil {
		t.Fatal("Decrypt accepted a tampered file; expected MAC mismatch")
	}
}

func TestDecryptFailsWithWrongIdentity(t *testing.T) {
	owner := newAgeKeyPair(t)
	stranger := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{owner.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	if _, err := Decrypt(encrypted, FormatYAML, stranger.Private); err == nil {
		t.Fatal("Decrypt succeeded with an unrelated identity")
	}
}

// Every recipient must independently recover the data key — this is the whole
// basis of the "nobody holds anyone else's private key" trust model.
func TestEveryRecipientCanDecryptIndependently(t *testing.T) {
	dev := newAgeKeyPair(t)
	server := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{dev.Public, server.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	for name, key := range map[string]ageKeyPair{"dev": dev, "server": server} {
		got, err := Decrypt(encrypted, FormatYAML, key.Private)
		if err != nil {
			t.Errorf("%s could not decrypt: %v", name, err)
			continue
		}
		if string(got) != plainYAML {
			t.Errorf("%s got wrong plaintext: %q", name, got)
		}
	}

	// And the CLI agrees, using the server identity.
	path := writeTemp(t, "secrets.yaml", encrypted)
	if got := runSopsCLI(t, server, nil, "--decrypt", path); string(got) != plainYAML {
		t.Errorf("CLI decrypt mismatch: %q", got)
	}
}
