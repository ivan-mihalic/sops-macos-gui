package gobridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The save path used to carry only a compile check on `encrypted_regex`,
// justified like this: the document arrived already encrypted under its own
// rule, so "the rule protects nothing" describes a file that was already that
// way before this app touched it.
//
// That reasoning is wrong, and this is the counterexample. The rule's *meaning*
// can change between the read and the write, so a value that was ciphertext on
// disk is written back in cleartext by an ordinary edit — with complete sops
// metadata and a MAC that verifies, because with `mac_only_encrypted` unset the
// MAC is taken over the plaintext of every leaf regardless of which ones are
// encrypted. `sops --decrypt` reads the result without complaint, so nothing
// downstream ever notices.
//
// Mechanism here: `unencrypted_comment_regex` is a supported creation-rule key,
// and sops clears its active-comment stack after each value. A comment that
// governed only the row beneath it starts governing the *next* row the moment
// that row is deleted. No attacker and no tampering — the user deleted an
// unrelated key.
func TestSaveNeverWritesAPreviouslyEncryptedValueInCleartext(t *testing.T) {
	key := newAgeKeyPair(t)
	dir := t.TempDir()

	config := "creation_rules:\n  - age: " + key.Public +
		"\n    unencrypted_comment_regex: PUBLIC\n"
	configPath := filepath.Join(dir, ".sops.yaml")
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}

	target := filepath.Join(dir, "secrets.yaml")
	plaintext := "# PUBLIC — this endpoint is not a secret\n" +
		"endpoint: https://example.invalid\n" +
		"db_password: fixture-value-alpha\n"
	if err := os.WriteFile(target, []byte(plaintext), 0o600); err != nil {
		t.Fatal(err)
	}
	runSopsCLI(t, key, nil, "--config", configPath, "--encrypt", "--in-place", target)

	onDisk, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	// The precondition the old reasoning got wrong: this value *is* ciphertext
	// on disk. Without this the test could pass over a file that was never
	// protected in the first place.
	if strings.Contains(string(onDisk), "fixture-value-alpha") {
		t.Fatalf("precondition failed: the CLI did not encrypt db_password, so this test proves nothing")
	}

	saved, err := ApplyChangesAndEncrypt(onDisk, FormatYAML, ChangeSet{Removes: []Removal{{Path: []string{"endpoint"}}}}, key.Private)
	if err != nil {
		// A refusal is the correct outcome. It must name the key at risk so the
		// user can act, and must not echo the value.
		if !strings.Contains(err.Error(), "db_password") {
			t.Errorf("the refusal does not name the key that would have been exposed: %v", err)
		}
		if strings.Contains(err.Error(), "fixture-value-alpha") {
			t.Errorf("the refusal echoed the secret value it was protecting")
		}
		return
	}
	if strings.Contains(string(saved), "fixture-value-alpha") {
		t.Errorf("LEAK: deleting an unrelated row wrote db_password to disk in cleartext")
	}
}

// The guard must not fire on an ordinary save, or it blocks every edit.
func TestSaveOfAnUnaffectedDocumentStillSucceeds(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatal(err)
	}
	saved, err := ApplyChangesAndEncrypt(encrypted, FormatYAML,
		ChangeSet{Sets: []Edit{{Path: []string{"db", "password"}, Value: "rotated-fixture-value", Kind: "string"}}},
		key.Private)
	if err != nil {
		t.Fatalf("an ordinary edit was refused: %v", err)
	}
	if strings.Contains(string(saved), "rotated-fixture-value") {
		t.Errorf("the edited value was written in cleartext")
	}
}

// Removing a value that was itself encrypted is not a leak — it is gone, not
// exposed. A guard implemented as "the set of encrypted values must not shrink"
// would refuse this, so it is pinned.
func TestSaveCanRemoveAnEncryptedRow(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ApplyChangesAndEncrypt(encrypted, FormatYAML, ChangeSet{Removes: []Removal{{Path: []string{"db", "password"}}}}, key.Private); err != nil {
		t.Fatalf("removing an encrypted row was refused: %v", err)
	}
}

// Iteration 11 added `refuseUnusableEncryptionRule` to the save path as one of
// two declared blockers, and shipped it with no test: deleting the call left
// the whole Go suite green. This is that test.
//
// The reachable shape is a `.sops.yaml` that was already broken when the file
// was first encrypted. One missing bracket, accepted by the real CLI with exit
// 0 and no warning: `sops.Tree.shouldBeEncrypted` does `matched, _ :=
// regexp.Match(...)` and drops the error, so the rule matches nothing and the
// CLI writes a file with complete sops metadata, a valid MAC, and every value
// in plain text.
//
// Corrupting the rule in an *already encrypted* file is not the shape — the MAC
// catches that on read, because the broken rule also stops sops decrypting the
// value, so the hash is taken over the ciphertext. Measured: an earlier version
// of this test asserted against that path and was refused with a MAC error,
// which is the right refusal for the wrong reason.
func TestSaveRefusesAnEncryptedRegexThatCannotCompile(t *testing.T) {
	key := newAgeKeyPair(t)
	dir := t.TempDir()

	config := "creation_rules:\n  - age: " + key.Public + "\n    encrypted_regex: '^(password|api_key$'\n"
	configPath := filepath.Join(dir, ".sops.yaml")
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "secrets.yaml")
	if err := os.WriteFile(target, []byte("host: localhost\npassword: fixture-value-alpha\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	runSopsCLI(t, key, nil, "--config", configPath, "--encrypt", "--in-place", target)

	onDisk, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	// The premise the guard exists for, checked rather than assumed: the CLI
	// accepted the broken rule and wrote the secret in plain text.
	if !strings.Contains(string(onDisk), "fixture-value-alpha") {
		t.Fatalf("premise wrong — the CLI did encrypt under an uncompilable rule:\n%s", onDisk)
	}
	if !strings.Contains(string(onDisk), "sops:") {
		t.Fatalf("premise wrong — the CLI did not write sops metadata:\n%s", onDisk)
	}

	saved, err := ApplyChangesAndEncrypt(onDisk, FormatYAML,
		ChangeSet{Sets: []Edit{{Path: []string{"host"}, Value: "db.internal", Kind: "string"}}},
		key.Private)
	if err == nil {
		t.Fatalf("the save was accepted over a rule that cannot compile; it produced:\n%s", saved)
	}
	if !strings.Contains(err.Error(), "encrypted_regex") {
		t.Errorf("the refusal does not name the rule the user has to fix: %v", err)
	}
	if strings.Contains(err.Error(), "fixture-value-alpha") {
		t.Errorf("the refusal echoed the secret value")
	}
}
