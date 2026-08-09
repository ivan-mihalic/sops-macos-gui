package gobridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The save-path exposure guard, attacked from four directions. Three of these
// are leaks the first version of it missed; the fourth is a correct save it
// must not refuse.
//
// All three leaks share one root: the guard snapshotted what was protected
// *after* the change set had already been applied to the tree, while keying
// that snapshot off `encryptedPaths`, which describes the file **as it was
// read**. Any change that moves a path — removing a list element renumbers
// every later sibling — looked the secret up under a path that no longer meant
// what it used to, found nothing, and left the guard with nothing to compare.

func writeConfigured(t *testing.T, key ageKeyPair, config, plaintext string) []byte {
	t.Helper()
	dir := t.TempDir()
	configPath := filepath.Join(dir, ".sops.yaml")
	if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(dir, "secrets.yaml")
	if err := os.WriteFile(target, []byte(plaintext), 0o600); err != nil {
		t.Fatal(err)
	}
	runSopsCLI(t, key, nil, "--config", configPath, "--encrypt", "--in-place", target)
	onDisk, err := os.ReadFile(target)
	if err != nil {
		t.Fatal(err)
	}
	return onDisk
}

// Removing an earlier list element renumbers the rest, so the secret was
// looked up under a stale path and the protected set came back empty.
func TestSaveGuardSurvivesListRenumbering(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    unencrypted_comment_regex: PUBLIC\n",
		"items:\n    # PUBLIC — the next entry is not a secret\n    - https://example.invalid\n    - fixture-value-alpha\n")

	if strings.Contains(string(onDisk), "fixture-value-alpha") {
		t.Fatalf("precondition failed: the CLI left the secret in plaintext:\n%s", onDisk)
	}

	saved, err := ApplyChangesAndEncrypt(
		onDisk, ChangeSet{Removes: []Removal{{Path: []string{"items", "1"}}}}, key.Private)
	if err != nil {
		return // a refusal is the correct outcome
	}
	if strings.Contains(string(saved), "fixture-value-alpha") {
		t.Errorf("LEAK: removing an earlier list element wrote a previously-encrypted value in cleartext")
	}
}

// A leaf that decrypts to something other than a Go string — an int here —
// never entered the protected set at all, because both halves of the guard
// began with `value.(string)`.
func TestSaveGuardCoversNonStringScalars(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    unencrypted_comment_regex: PUBLIC\n",
		"db_password: fixture-value-alpha\n# PUBLIC — this endpoint is not a secret\nendpoint: https://example.invalid\npin: 8675309\n")

	if strings.Contains(string(onDisk), "8675309") {
		t.Fatalf("precondition failed: the CLI left the pin in plaintext:\n%s", onDisk)
	}

	saved, err := ApplyChangesAndEncrypt(
		onDisk, ChangeSet{Removes: []Removal{{Path: []string{"endpoint"}}}}, key.Private)
	if err != nil {
		return
	}
	if strings.Contains(string(saved), "8675309") {
		t.Errorf("LEAK: an integer that was ciphertext on disk was written back in plain text")
	}
}

// sops encrypts comments — `Tree.walkBranch` runs the comment key through the
// cipher — and leaves them out of the MAC entirely, so a comment losing its
// protection is invisible at both levels. `walkLeaves` skips comments because
// the *editor* has no row for them; the guard is a different consumer.
func TestSaveGuardCoversEncryptedComments(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    unencrypted_comment_regex: PUBLIC\n",
		"db_password: fixture-value-alpha\n# PUBLIC — everything until the next value is public\nendpoint: https://example.invalid\n# recovery phrase fixture-comment-alpha\nplaceholder:\n")

	if strings.Contains(string(onDisk), "fixture-comment-alpha") {
		t.Fatalf("precondition failed: the CLI left the comment in plaintext:\n%s", onDisk)
	}

	saved, err := ApplyChangesAndEncrypt(
		onDisk, ChangeSet{Removes: []Removal{{Path: []string{"endpoint"}}}}, key.Private)
	if err != nil {
		return
	}
	if strings.Contains(string(saved), "fixture-comment-alpha") {
		t.Errorf("LEAK: a comment that was ciphertext on disk was written back in plain text")
	}
}

// The other half. A file where the same text sits in one encrypted row and one
// plaintext row is not a leak — it arrived that way — and a guard that matches
// on value alone refuses every save of it forever. The user cannot edit an
// unrelated key.
func TestSaveGuardDoesNotRefuseAValueThatWasAlreadyInTheClear(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    encrypted_regex: '^secret$'\n",
		"secret: shared-fixture-text\npublic: shared-fixture-text\nnote: something\n")

	if !strings.Contains(string(onDisk), "public: shared-fixture-text") {
		t.Fatalf("precondition failed: `public` should have stayed in cleartext:\n%s", onDisk)
	}
	if strings.Contains(string(onDisk), "secret: shared-fixture-text") {
		t.Fatalf("precondition failed: `secret` should have been encrypted:\n%s", onDisk)
	}

	if _, err := ApplyChangesAndEncrypt(
		onDisk,
		ChangeSet{Sets: []Edit{{Path: []string{"note"}, Value: "changed", Kind: "string"}}},
		key.Private); err != nil {
		t.Errorf("FALSE REFUSAL: editing an unrelated key was refused because a plaintext row "+
			"happens to hold the same text as an encrypted one: %v", err)
	}
}

// Non-string values are everywhere — `true`, `0`, `1` — so widening the guard
// to cover them must not start colliding them with each other.
func TestSaveGuardDoesNotCollideCommonScalars(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    encrypted_regex: '^secret_flag$'\n",
		"secret_flag: true\nverbose: true\ndebug: true\nretries: 1\nnote: something\n")

	if _, err := ApplyChangesAndEncrypt(
		onDisk,
		ChangeSet{Sets: []Edit{{Path: []string{"note"}, Value: "changed", Kind: "string"}}},
		key.Private); err != nil {
		t.Errorf("FALSE REFUSAL: a document full of ordinary booleans was refused: %v", err)
	}
}
