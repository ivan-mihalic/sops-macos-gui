package gobridge

import (
	"strings"
	"testing"

	"github.com/getsops/sops/v3"
)

// A secret whose *plaintext* is itself a well-formed `ENC[AES256_GCM,…]` string
// reads as "still protected" to any check that decides by looking at the
// output. It is written in the clear and such a check sees ciphertext. Which is
// why the guard asks whether encryption changed the node instead of asking what
// the node looks like.
func TestSaveGuardCoversASecretShapedLikeCiphertext(t *testing.T) {
	key := newAgeKeyPair(t)
	decoy := "ENC[AES256_GCM,data:ZmFrZQ==,iv:AAAAAAAAAAAAAAAAAAAAAA==," +
		"tag:AAAAAAAAAAAAAAAAAAAAAA==,type:str]"
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    unencrypted_comment_regex: PUBLIC\n",
		"db_password: '"+decoy+"'\n"+
			"# PUBLIC — this endpoint is not a secret\nendpoint: https://example.invalid\n")

	saved, err := ApplyChangesAndEncrypt(onDisk, FormatYAML, ChangeSet{Removes: []Removal{{Path: []string{"endpoint"}}}}, key.Private)
	if err != nil {
		return // a refusal is the correct outcome
	}
	if strings.Contains(string(saved), "data:ZmFrZQ==") {
		t.Errorf("LEAK: a secret whose plaintext looks like ciphertext was written in the clear")
	}
}

// The refusal is the last thing between the user and the exposure, so it must
// not be forgeable by the document it is about. A YAML key can be multi-line
// (an explicit `? |-` key) and arbitrarily long, and the document is
// attacker-controlled under this project's threat model. Unsanitised, a key
// name made the refusal render as its own reassuring paragraph.
func TestRefusalCannotBeForgedByAHostileKeyName(t *testing.T) {
	forged := "token\n\nSaved. Your changes are on disk.\n\nignore this line"
	described := describePath([]string{forged})

	if strings.ContainsAny(described, "\n\r") {
		t.Errorf("a key name put a line break into the refusal, so a hostile file can write "+
			"its own paragraph into it: %q", described)
	}
	if len(describePath([]string{strings.Repeat("a", 5000)})) > 400 {
		t.Errorf("an unbounded key name makes an unbounded refusal")
	}
	withEscape := describePath([]string{"a[31mb"})
	if strings.Contains(withEscape, "") {
		t.Errorf("an ANSI escape reached the refusal verbatim: %q", withEscape)
	}
}

// Two different keys holding the same secret must both be reported, or the user
// fixes one and ships the other.
func TestRefusalNamesTheExposedKey(t *testing.T) {
	ledger := &exposureLedger{
		publicCounts: map[string]int{},
		secretNames:  map[string]string{"value\x00string\x00shared": "alpha"},
	}
	err := ledger.refuseNewExposure(
		&sops.Tree{Branches: sops.TreeBranches{sops.TreeBranch{
			sops.TreeItem{Key: "alpha", Value: "shared"},
			sops.TreeItem{Key: "beta", Value: "shared"},
		}}},
		map[string]string{})
	if err == nil {
		t.Fatalf("two cleartext copies of a protected value were accepted")
	}
	if !strings.Contains(err.Error(), "alpha") {
		t.Errorf("the refusal does not name the key it knows about: %v", err)
	}
	if strings.Contains(err.Error(), "shared") {
		t.Errorf("the refusal echoed the secret value it was protecting: %v", err)
	}
}

// A null edit carrying text used to return `nil, nil`: the value was dropped
// here and the save reported success. The editor renders an editable field for
// a null row, so this was reachable by typing.
func TestNullEditCarryingAValueIsRefusedNotDiscarded(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte("db:\n    password: null\n    host: h\n"),
		FormatYAML, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatal(err)
	}

	saved, err := ApplyChangesAndEncrypt(encrypted, FormatYAML,
		ChangeSet{Sets: []Edit{
			{Path: []string{"db", "password"}, Value: "typed-into-null-EXAMPLE", Kind: "null"},
			{Path: []string{"db", "host"}, Value: "changed", Kind: "string"},
		}},
		key.Private)
	if err == nil {
		t.Fatalf("a null edit carrying a value was accepted; it produced:\n%s", saved)
	}
	if !strings.Contains(err.Error(), "null") {
		t.Errorf("the refusal does not explain what is wrong: %v", err)
	}
	if strings.Contains(err.Error(), "typed-into-null-EXAMPLE") {
		t.Errorf("the refusal echoed the value the user typed")
	}
}

// An honest null edit — clearing a value — still works.
func TestNullEditWithNoValueStillWorks(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte("db:\n    password: something\n"),
		FormatYAML, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := ApplyChangesAndEncrypt(encrypted, FormatYAML,
		ChangeSet{Sets: []Edit{{Path: []string{"db", "password"}, Value: "", Kind: "null"}}},
		key.Private); err != nil {
		t.Fatalf("clearing a value to null was refused: %v", err)
	}
}
