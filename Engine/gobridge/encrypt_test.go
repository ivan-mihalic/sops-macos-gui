package gobridge

import "testing"

func TestSopsCLIDecryptsFileEncryptedByBridge(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
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
