package gobridge

import "testing"

const plainYAML = `db:
    host: localhost
    password: hunter2
api_key: sk-live-abc123
`

func TestDecryptsFileEncryptedBySopsCLI(t *testing.T) {
	key := newAgeKeyPair(t)
	in := writeTemp(t, "secrets.yaml", []byte(plainYAML))
	encrypted := runSopsCLI(t, key, nil, "--encrypt", "--age", key.Public, in)

	got, err := Decrypt(encrypted, FormatYAML, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	if string(got) != plainYAML {
		t.Errorf("round-trip mismatch\n got: %q\nwant: %q", got, plainYAML)
	}
}
