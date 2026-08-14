package gobridge

import (
	"strings"
	"testing"
)

// Ticket #5, claim 1: `refuseUnusableEncryptionRule` (documentchanges.go)
// refuses a document whose `encrypted_regex` cannot compile, but only on
// *this app's own save path*. The real sops CLI has no such guard — it
// discards the compile error and falls back to writing every value in
// plaintext, with a complete, valid `sops:` metadata block and a valid MAC
// over that plaintext. `InspectLeafEncryption` is what lets a health check
// tell that file apart from a genuinely encrypted one, without decrypting
// it and without an age identity.

func TestLeafEncryptionSummaryOnAFullyEncryptedDocument(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	// plainYAML has three leaves: db.host, db.password, api_key.
	if summary.LeafCount != 3 {
		t.Errorf("LeafCount = %d, want 3", summary.LeafCount)
	}
	if summary.EncryptedLeafCount != summary.LeafCount {
		t.Errorf("EncryptedLeafCount = %d, want %d (every leaf encrypted)",
			summary.EncryptedLeafCount, summary.LeafCount)
	}
	if summary.NarrowingDeclared {
		t.Errorf("NarrowingDeclared = true, want false (no rule was configured)")
	}
	if summary.UncompilableRuleDeclared {
		t.Errorf("UncompilableRuleDeclared = true, want false")
	}
}

// Measured directly, not assumed: a file encrypted with no rule at all still
// carries `unencrypted_suffix: _unencrypted` in its own metadata — sops's
// compiled-in fallback, not a declared choice. `NarrowingDeclared` has to see
// through that or it would report `true` for nearly every encrypted file
// this app or the CLI has ever produced.
func TestLeafEncryptionSummaryDefaultSuffixIsNotNarrowing(t *testing.T) {
	key := newAgeKeyPair(t)
	in := writeTemp(t, "secrets.yaml", []byte(plainYAML))

	encrypted := runSopsCLI(t, key, nil, "--encrypt", "--age", key.Public, in)
	if !strings.Contains(string(encrypted), "unencrypted_suffix: _unencrypted") {
		t.Fatalf("test premise not met: sops did not write the default suffix; output:\n%s", encrypted)
	}

	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.NarrowingDeclared {
		t.Errorf("NarrowingDeclared = true for a file with only the default suffix, want false")
	}
}

func TestLeafEncryptionSummaryCustomUnencryptedSuffixIsNarrowing(t *testing.T) {
	key := newAgeKeyPair(t)
	in := writeTemp(t, "secrets.yaml", []byte("password_do_not_encrypt: shown\nsecret: hunter2\n"))

	encrypted := runSopsCLI(t, key, nil,
		"--encrypt", "--age", key.Public, "--unencrypted-suffix", "_do_not_encrypt", in)

	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if !summary.NarrowingDeclared {
		t.Errorf("NarrowingDeclared = false for a genuinely custom unencrypted_suffix, want true")
	}
	if summary.UncompilableRuleDeclared {
		t.Errorf("UncompilableRuleDeclared = true, want false — a suffix is not a regex")
	}
}

// The reproduction of the actual bug, against the real `sops` binary rather
// than a hand-written fixture — `(unclosed` is a genuinely invalid regular
// expression. Verified directly against sops 3.13.3: it exits 0, writes a
// complete metadata block with the invalid pattern recorded verbatim as
// `encrypted_regex: (unclosed`, and every value stays in cleartext.
func TestLeafEncryptionSummaryDetectsARegexThatFailedToCompile(t *testing.T) {
	key := newAgeKeyPair(t)
	in := writeTemp(t, "secrets.yaml", []byte(plainYAML))

	encrypted := runSopsCLI(t, key, nil,
		"--encrypt", "--age", key.Public, "--encrypted-regex", "(unclosed", in)

	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.LeafCount == 0 {
		t.Fatalf("LeafCount = 0, want > 0 (plainYAML has values)")
	}
	if summary.EncryptedLeafCount != 0 {
		t.Errorf("EncryptedLeafCount = %d, want 0 (encrypted_regex never compiled, so sops encrypted nothing)",
			summary.EncryptedLeafCount)
	}
	if !summary.NarrowingDeclared {
		t.Errorf("NarrowingDeclared = false, want true — the file's metadata does name an encrypted_regex")
	}
	if !summary.UncompilableRuleDeclared {
		t.Errorf("UncompilableRuleDeclared = false, want true — %q is not a valid regular expression", "(unclosed")
	}
}

// A rule that genuinely narrows encryption to some keys is not this bug —
// the ground truth this function reports has to distinguish "some leaves are
// deliberately left in cleartext" from "every leaf is, because the rule
// never took effect". Both are LeafCount > 0, EncryptedLeafCount == 0's
// sibling shapes; this pins that a partial match reports a partial count,
// not zero and not the full count either.
func TestLeafEncryptionSummaryOnAPartiallyEncryptedDocument(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients:  []string{key.Public},
		EncryptedRegex: secretKeyRegex, // matches "password" and "api_key", not "host"
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.LeafCount != 3 {
		t.Errorf("LeafCount = %d, want 3", summary.LeafCount)
	}
	if summary.EncryptedLeafCount != 2 {
		t.Errorf("EncryptedLeafCount = %d, want 2 (password, api_key — not host)", summary.EncryptedLeafCount)
	}
	if !summary.NarrowingDeclared {
		t.Errorf("NarrowingDeclared = false, want true")
	}
	if summary.UncompilableRuleDeclared {
		t.Errorf("UncompilableRuleDeclared = true, want false — %q compiles fine", secretKeyRegex)
	}
}

// An empty document has nothing to encrypt at all; this must read as "zero
// leaves", never as the LeafCount>0/EncryptedLeafCount==0 shape the other
// tests here treat as the bug signature — an empty file is not a broken one.
func TestLeafEncryptionSummaryOnAnEmptyDocument(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte("{}\n"), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.LeafCount != 0 {
		t.Errorf("LeafCount = %d, want 0", summary.LeafCount)
	}
	if summary.EncryptedLeafCount != 0 {
		t.Errorf("EncryptedLeafCount = %d, want 0", summary.EncryptedLeafCount)
	}
}

// This is read metadata, not a decrypt — no age identity is required or
// even accepted by the signature. A file this app has never seen a key for
// (this test imports no identity at all) must still be inspectable.
func TestLeafEncryptionSummaryNeedsNoIdentity(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// No identity anywhere in this test — InspectLeafEncryption's signature
	// takes only the document bytes, which is the point.
	if _, err := InspectLeafEncryption(encrypted); err != nil {
		t.Fatalf("InspectLeafEncryption should need no key: %v", err)
	}
}

func TestLeafEncryptionSummaryRefusesANonSopsDocument(t *testing.T) {
	if _, err := InspectLeafEncryption([]byte(plainYAML)); err == nil {
		t.Fatalf("expected an error for a document with no sops metadata")
	}
}
