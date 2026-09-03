package gobridge

import (
	"encoding/json"
	"strings"
	"testing"

	"filippo.io/age"
)

func decodeGenerated(t *testing.T) GeneratedAgeKey {
	t.Helper()
	payload, err := GenerateAgeKey()
	if err != nil {
		t.Fatalf("GenerateAgeKey() failed: %v", err)
	}
	var key GeneratedAgeKey
	if err := json.Unmarshal(payload, &key); err != nil {
		t.Fatalf("GenerateAgeKey() did not produce JSON: %v", err)
	}
	return key
}

// The generated pair must be usable by age itself — not merely shaped like a
// key. Parsing the private line and comparing the recipient it derives with
// the public line is what proves the two halves belong together.
func TestGenerateAgeKeyProducesAMatchingUsablePair(t *testing.T) {
	key := decodeGenerated(t)

	if !strings.HasPrefix(key.PrivateKey, "AGE-SECRET-KEY-1") {
		t.Errorf("private key does not carry age's own prefix")
	}
	if !strings.HasPrefix(key.PublicKey, "age1") {
		t.Errorf("public key %q does not carry age's own prefix", key.PublicKey)
	}

	identity, err := age.ParseX25519Identity(key.PrivateKey)
	if err != nil {
		t.Fatalf("the generated private key does not parse as an age identity: %v", err)
	}
	if got := identity.Recipient().String(); got != key.PublicKey {
		t.Errorf("public key %q is not the one the private key derives (%q)", key.PublicKey, got)
	}
	if _, err := validAgeRecipients([]string{key.PublicKey}); err != nil {
		t.Errorf("the generated public key is not accepted as a recipient: %v", err)
	}
}

// Two calls must not return the same key. A generator that answered a
// constant would pass every shape check above and hand every user of this app
// the same identity.
func TestGenerateAgeKeyIsNotAConstant(t *testing.T) {
	first := decodeGenerated(t)
	second := decodeGenerated(t)
	if first.PrivateKey == second.PrivateKey || first.PublicKey == second.PublicKey {
		t.Fatalf("two generated keys are identical")
	}
}

// AgePublicKey is the app's existing private → public derivation. A key made
// here must be understood by it, or the two halves of the app disagree about
// what a key is.
func TestGeneratedKeyRoundTripsThroughAgePublicKey(t *testing.T) {
	key := decodeGenerated(t)
	derived, err := AgePublicKey(key.PrivateKey)
	if err != nil {
		t.Fatalf("AgePublicKey rejected a freshly generated key: %v", err)
	}
	if derived != key.PublicKey {
		t.Errorf("AgePublicKey derived %q, generation reported %q", derived, key.PublicKey)
	}
}
