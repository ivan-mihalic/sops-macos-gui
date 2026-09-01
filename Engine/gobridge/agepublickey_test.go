package gobridge

import "testing"

// TestAgePublicKeyMatchesTheIdentityItWasGeneratedWith proves the one thing
// this function exists for: the derived public key is the same one
// age-keygen would have printed alongside this exact private key, so
// comparing it against a file's own recipient metadata means what a reader
// would expect.
func TestAgePublicKeyMatchesTheIdentityItWasGeneratedWith(t *testing.T) {
	key := newAgeKeyPair(t)

	got, err := AgePublicKey(key.Private)
	if err != nil {
		t.Fatalf("AgePublicKey: %v", err)
	}
	if got != key.Public {
		t.Errorf("AgePublicKey(%q) = %q, want %q", key.Private, got, key.Public)
	}
}

// TestAgePublicKeyRefusesGarbage checks the ordinary-error path: a string
// that is not a valid age identity at all must never panic and must never
// echo the supplied text back (it may itself be a mangled secret paste).
func TestAgePublicKeyRefusesGarbage(t *testing.T) {
	for _, tc := range []string{
		"",
		"hunter2",
		"AGE-SECRET-KEY-1" + "not-a-real-bech32-body",
	} {
		if _, err := AgePublicKey(tc); err == nil {
			t.Errorf("AgePublicKey(%q): expected an error, got none", tc)
		}
	}
}

// TestAgePublicKeyDiffersBetweenTwoIdentities is a canary against a bug that
// would make this function return a constant or ignore its argument — two
// independently generated identities must never collide.
func TestAgePublicKeyDiffersBetweenTwoIdentities(t *testing.T) {
	a := newAgeKeyPair(t)
	b := newAgeKeyPair(t)

	pubA, err := AgePublicKey(a.Private)
	if err != nil {
		t.Fatalf("AgePublicKey(a): %v", err)
	}
	pubB, err := AgePublicKey(b.Private)
	if err != nil {
		t.Fatalf("AgePublicKey(b): %v", err)
	}
	if pubA == pubB {
		t.Errorf("two distinct identities produced the same public key: %q", pubA)
	}
}
