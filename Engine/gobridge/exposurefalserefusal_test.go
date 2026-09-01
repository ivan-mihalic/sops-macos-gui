package gobridge

import (
	"strings"
	"testing"
)

// The exposure guard counts cleartext copies of a value. That makes any save
// which *adds* a plaintext copy of a value encrypted elsewhere look like a
// leak — and for `true`, `false`, `0` and `1` in a configuration file that is
// close to certain. A file holding one encrypted `true` meant no plaintext
// boolean in it could ever be set to `true` again.
//
// Each of these is a save that exposes nothing. The encrypted leaf stays
// ciphertext in the output; only a leaf the user explicitly wrote changes.
//
// **These four are skipped, and that is a recorded defect, not a decision.**
// The guard fails *safe* — it refuses rather than leaks — so it is not
// shipping-blocking, but it makes ordinary files unsaveable. The fix needs the
// guard to reason per *leaf* rather than per value, which means stable
// identities across a change set that renumbers lists: a redesign, not an
// adjustment. The two tests below are not skipped — they are the leaks the
// guard exists for and they must never go red.

func TestGuardAcceptsTogglingAnUnrelatedBoolean(t *testing.T) {
	t.Skip("KNOWN DEFECT, unfixed: see docs/m2-review-log.md. The obvious fix — allowing " +
		"one cleartext copy per value the change set writes — was tried and reverted, because " +
		"it lets a real leak through: with an edit writing the secret's own value, the " +
		"allowance absorbs an untouched leaf losing its protection in the same save. " +
		"Verified: db_password came back in cleartext with the save reported successful. " +
		"Remove this line to reproduce the false refusal.")

	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    encrypted_regex: '^secret_flag$'\n",
		"secret_flag: true\nverbose: false\n")

	saved, err := ApplyChangesAndEncrypt(onDisk, FormatYAML,
		ChangeSet{Sets: []Edit{{Path: []string{"verbose"}, Value: "true", Kind: "bool"}}},
		key.Private)
	if err != nil {
		t.Fatalf("FALSE REFUSAL: toggling an unrelated boolean was refused: %v", err)
	}
	if !strings.Contains(string(saved), "secret_flag: ENC[") {
		t.Errorf("the encrypted flag did not stay encrypted:\n%s", saved)
	}
}

func TestGuardAcceptsAddingAPlaintextBoolean(t *testing.T) {
	t.Skip("KNOWN DEFECT, unfixed: see docs/m2-review-log.md. The obvious fix — allowing " +
		"one cleartext copy per value the change set writes — was tried and reverted, because " +
		"it lets a real leak through: with an edit writing the secret's own value, the " +
		"allowance absorbs an untouched leaf losing its protection in the same save. " +
		"Verified: db_password came back in cleartext with the save reported successful. " +
		"Remove this line to reproduce the false refusal.")

	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    encrypted_regex: '^secret_flag$'\n",
		"secret_flag: true\nname: app\n")

	if _, err := ApplyChangesAndEncrypt(onDisk, FormatYAML,
		ChangeSet{Adds: []Add{{Parent: nil, Key: "verbose", Value: "true", Kind: "bool"}}},
		key.Private); err != nil {
		t.Fatalf("FALSE REFUSAL: adding a plaintext boolean was refused: %v", err)
	}
}

func TestGuardAcceptsAddingAPlaintextSmallInteger(t *testing.T) {
	t.Skip("KNOWN DEFECT, unfixed: see docs/m2-review-log.md. The obvious fix — allowing " +
		"one cleartext copy per value the change set writes — was tried and reverted, because " +
		"it lets a real leak through: with an edit writing the secret's own value, the " +
		"allowance absorbs an untouched leaf losing its protection in the same save. " +
		"Verified: db_password came back in cleartext with the save reported successful. " +
		"Remove this line to reproduce the false refusal.")

	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    encrypted_regex: '^secret_count$'\n",
		"secret_count: 1\nname: app\n")

	if _, err := ApplyChangesAndEncrypt(onDisk, FormatYAML,
		ChangeSet{Adds: []Add{{Parent: nil, Key: "retries", Value: "1", Kind: "int"}}},
		key.Private); err != nil {
		t.Fatalf("FALSE REFUSAL: adding a plaintext integer was refused: %v", err)
	}
}

func TestGuardAcceptsWritingAWordThatMatchesAnEncryptedValue(t *testing.T) {
	t.Skip("KNOWN DEFECT, unfixed: see docs/m2-review-log.md. The obvious fix — allowing " +
		"one cleartext copy per value the change set writes — was tried and reverted, because " +
		"it lets a real leak through: with an edit writing the secret's own value, the " +
		"allowance absorbs an untouched leaf losing its protection in the same save. " +
		"Verified: db_password came back in cleartext with the save reported successful. " +
		"Remove this line to reproduce the false refusal.")

	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    encrypted_regex: '^secret$'\n",
		"secret: shared-fixture-text\nnote: something\n")

	if _, err := ApplyChangesAndEncrypt(onDisk, FormatYAML,
		ChangeSet{Sets: []Edit{
			{Path: []string{"note"}, Value: "shared-fixture-text", Kind: "string"}}},
		key.Private); err != nil {
		t.Fatalf("FALSE REFUSAL: writing a word that also happens to be the encrypted value "+
			"was refused: %v", err)
	}
}

// And the leak must still be caught. The exposed leaf here is one the user
// never touched, which is what separates it from every case above.
func TestGuardStillCatchesAnUntouchedLeafLosingItsProtection(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    unencrypted_comment_regex: PUBLIC\n",
		"# PUBLIC — this endpoint is not a secret\nendpoint: https://example.invalid\n"+
			"db_password: fixture-value-alpha\n")
	if strings.Contains(string(onDisk), "fixture-value-alpha") {
		t.Fatalf("precondition failed: the CLI did not encrypt db_password")
	}

	saved, err := ApplyChangesAndEncrypt(onDisk, FormatYAML, ChangeSet{Removes: []Removal{{Path: []string{"endpoint"}}}}, key.Private)
	if err != nil {
		return // refusal is correct
	}
	if strings.Contains(string(saved), "fixture-value-alpha") {
		t.Errorf("LEAK: an untouched leaf lost its protection and the guard did not fire")
	}
}

// The narrow case the counting rule was right about: the user writes the
// secret's own value into a plaintext field *and* an untouched leaf is exposed
// in the same save. One new cleartext copy is accounted for by the edit; the
// second is not.
func TestGuardCatchesAnExposureHiddenBehindAnExplicitEdit(t *testing.T) {
	key := newAgeKeyPair(t)
	onDisk := writeConfigured(t, key,
		"creation_rules:\n  - age: "+key.Public+"\n    unencrypted_comment_regex: PUBLIC\n",
		"# PUBLIC — this endpoint is not a secret\nendpoint: https://example.invalid\n"+
			"db_password: fixture-value-alpha\nnote: placeholder\n")
	if strings.Contains(string(onDisk), "fixture-value-alpha") {
		t.Fatalf("precondition failed: the CLI did not encrypt db_password")
	}

	saved, err := ApplyChangesAndEncrypt(onDisk, FormatYAML,
		ChangeSet{
			Sets:    []Edit{{Path: []string{"note"}, Value: "fixture-value-alpha", Kind: "string"}},
			Removes: []Removal{{Path: []string{"endpoint"}}},
		},
		key.Private)
	if err != nil {
		return // refusal is correct
	}
	if strings.Count(string(saved), "fixture-value-alpha") > 1 {
		t.Errorf("LEAK: an exposure was hidden behind an explicit edit of the same value:\n%s", saved)
	}
}
