package gobridge

import (
	"strings"
	"testing"
)

// dotenvPlain is the fixture from the task brief: a normal secret, a comment,
// and an empty value — the three shapes the dotenv store treats specially.
const dotenvPlain = "DB_URL=postgres://x\nAPI_KEY=secret\n# comment\nEMPTY=\n"

// TestDotenvEncryptDecryptRoundTrip exercises the bridge's own Encrypt/Decrypt
// against each other, with no CLI involved. It is the fast check that the new
// Format case wires into the same code path YAML already uses.
func TestDotenvEncryptDecryptRoundTrip(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if !strings.Contains(string(enc), "sops_mac=") {
		t.Errorf("encrypted dotenv is missing sops metadata (sops_mac=): %s", enc)
	}
	if strings.Contains(string(enc), "secret") {
		t.Errorf("encrypted dotenv still contains the plaintext secret value")
	}

	dec, err := Decrypt(enc, FormatDotenv, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	// The dotenv store round-trips keys and values 1:1 and keeps comments, but
	// is not guaranteed to reproduce the exact byte layout (e.g. trailing
	// newline handling), so compare the parsed line sets rather than raw bytes.
	if got, want := dotenvLines(string(dec)), dotenvLines(dotenvPlain); !equalLineSets(got, want) {
		t.Errorf("round trip did not preserve content:\n got:  %v\n want: %v", got, want)
	}
}

// TestDotenvBridgeEncryptsCLIDecrypts proves the bridge's dotenv output is a
// file the real sops CLI accepts and reads back correctly — the compatibility
// oracle used throughout this package (see document_test.go's cliDecrypt).
func TestDotenvBridgeEncryptsCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// The CLI infers dotenv from the .env suffix (formats.IsEnvFile).
	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "enc.env", enc)))

	for _, want := range []string{"DB_URL=postgres://x", "API_KEY=secret", "EMPTY="} {
		if !strings.Contains(out, want) {
			t.Errorf("CLI decrypt output missing %q; got:\n%s", want, out)
		}
	}
}

// TestDotenvCLIEncryptsBridgeDecrypts is the opposite direction: a file the
// real sops CLI produced must decrypt cleanly through the bridge.
func TestDotenvCLIEncryptsBridgeDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	in := writeTemp(t, "plain.env", []byte(dotenvPlain))
	enc := runSopsCLI(t, key, nil, "--encrypt", "--age", key.Public, in)

	dec, err := Decrypt(enc, FormatDotenv, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}

	if got, want := dotenvLines(string(dec)), dotenvLines(dotenvPlain); !equalLineSets(got, want) {
		t.Errorf("round trip did not preserve content:\n got:  %v\n want: %v", got, want)
	}
}

// -----------------------------------------------------------------------
// Task 2: the row/edit/change/recipients/leaf-summary API over dotenv
// -----------------------------------------------------------------------
//
// dotenv has no nesting — stores/dotenv.Store.LoadPlainFile always produces a
// single flat branch of string keys and string values — so every row's Path
// has exactly one segment and InList is always false. That shape, not a
// second implementation, is what these tests exist to pin down: the document
// API (document.go, documentchanges.go, recipients.go, leafencryption.go)
// takes its Format from the caller now, and the dotenv store must behave
// exactly the way the YAML tests already established for the same API.

// TestDotenvDecryptToRowsFlatPathsAndEncryptedFlags checks the row shape
// DecryptToRows produces for a dotenv document: a one-segment Path per key,
// InList always false (there are no lists in dotenv), string values, and
// Encrypted true for every non-empty value and false for the empty one — the
// same "sops never encrypts an empty string" rule the YAML tests already
// pin down in TestDecryptToRowsReportsWhichValuesAreCiphertextOnDisk.
func TestDotenvDecryptToRowsFlatPathsAndEncryptedFlags(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	rows, err := DecryptToRows(encrypted, FormatDotenv, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}

	// The comment produces no row: it has no key path, exactly like a YAML
	// comment (see document.go's walkLeaves).
	if len(rows) != 3 {
		t.Fatalf("expected 3 rows (DB_URL, API_KEY, EMPTY), got %d: %v", len(rows), rowPaths(rows))
	}

	for _, tc := range []struct {
		key       string
		value     string
		encrypted bool
	}{
		{"DB_URL", "postgres://x", true},
		{"API_KEY", "secret", true},
		{"EMPTY", "", false},
	} {
		row := rowByPath(t, rows, tc.key)
		if len(row.Path) != 1 || row.Path[0] != tc.key {
			t.Errorf("%s: Path = %v, want a single segment %q", tc.key, row.Path, tc.key)
		}
		if row.InList {
			t.Errorf("%s: InList = true, but dotenv has no lists", tc.key)
		}
		if row.Kind != KindString {
			t.Errorf("%s: Kind = %q, want %q", tc.key, row.Kind, KindString)
		}
		if row.Value != tc.value {
			t.Errorf("%s: Value = %q, want %q", tc.key, row.Value, tc.value)
		}
		if row.Encrypted != tc.encrypted {
			t.Errorf("%s: Encrypted = %v, want %v", tc.key, row.Encrypted, tc.encrypted)
		}
	}
}

// TestDotenvApplyEditsChangesValueAndCLIDecrypts proves an edited dotenv
// value round-trips through the real sops CLI, the same compatibility oracle
// document_test.go and documentchanges_test.go use throughout.
func TestDotenvApplyEditsChangesValueAndCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	edited, err := ApplyEditsAndEncrypt(encrypted, FormatDotenv,
		[]Edit{{Path: []string{"API_KEY"}, Value: "rotated", Kind: KindString}}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "edited.env", edited)))
	if !strings.Contains(out, "API_KEY=rotated") {
		t.Errorf("CLI decrypt output missing the edited value; got:\n%s", out)
	}
	if strings.Contains(out, "API_KEY=secret") {
		t.Errorf("CLI decrypt output still has the old value; got:\n%s", out)
	}
	// Untouched keys survive the edit.
	if !strings.Contains(out, "DB_URL=postgres://x") {
		t.Errorf("editing one key disturbed another; got:\n%s", out)
	}
}

// TestDotenvApplyChangesAddAndRemoveKeys exercises the structural half of the
// document API — Add and Removal — over dotenv's flat root, verified against
// the real CLI.
func TestDotenvApplyChangesAddAndRemoveKeys(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	out, err := ApplyChangesAndEncrypt(encrypted, FormatDotenv, ChangeSet{
		Adds:    []Add{{Key: "NEW_VAR", Value: "added", Kind: KindString}},
		Removes: []Removal{{Path: []string{"EMPTY"}}},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesAndEncrypt: %v", err)
	}

	decrypted := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "changed.env", out)))
	if !strings.Contains(decrypted, "NEW_VAR=added") {
		t.Errorf("the added key is not in the decrypted document:\n%s", decrypted)
	}
	if strings.Contains(decrypted, "EMPTY") {
		t.Errorf("the removed key is still in the decrypted document:\n%s", decrypted)
	}
	for _, want := range []string{"DB_URL=postgres://x", "API_KEY=secret"} {
		if !strings.Contains(decrypted, want) {
			t.Errorf("an add/remove change disturbed an untouched key %q:\n%s", want, decrypted)
		}
	}
}

// TestDotenvRecipientsJSONReadsWithoutKey checks that recipient metadata is
// readable for a dotenv document without any age identity — RecipientsJSON
// only reads the file's sops metadata block, never its ciphertext.
func TestDotenvRecipientsJSONReadsWithoutKey(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	recipients, err := Recipients(encrypted, FormatDotenv)
	if err != nil {
		t.Fatalf("Recipients: %v", err)
	}
	if len(recipients) != 1 || recipients[0] != key.Public {
		t.Fatalf("Recipients = %v, want [%s]", recipients, key.Public)
	}
}

// TestDotenvUpdateRecipientsRewrapsAndCLIVerifies mirrors
// recipients_test.go's TestUpdateRecipientsRewrapsForExactlyTheRequestedPeople,
// verified against the real CLI rather than the bridge's own Decrypt so the
// re-wrap is checked against the compatibility oracle, not against itself.
func TestDotenvUpdateRecipientsRewrapsAndCLIVerifies(t *testing.T) {
	owner := newAgeKeyPair(t)
	kept := newAgeKeyPair(t)
	added := newAgeKeyPair(t)
	removed := newAgeKeyPair(t)

	encrypted := runSopsCLI(t, owner, nil,
		"--encrypt", "--age", owner.Public+","+removed.Public,
		writeTemp(t, "plain.env", []byte(dotenvPlain)))

	rewrapped, err := UpdateRecipients(encrypted, FormatDotenv, []string{kept.Public, added.Public}, owner.Private)
	if err != nil {
		t.Fatalf("UpdateRecipients: %v", err)
	}

	for _, k := range []ageKeyPair{kept, added} {
		out := string(runSopsCLI(t, k, nil, "--decrypt", writeTemp(t, "rewrapped.env", rewrapped)))
		if got, want := dotenvLines(out), dotenvLines(dotenvPlain); !equalLineSets(got, want) {
			t.Errorf("%s cannot decrypt the rewrapped document via CLI:\n got:  %v\n want: %v",
				k.Public, got, want)
		}
	}

	// runSopsCLIAllowFailDoc (document_test.go) is runSopsCLI without the
	// t.Fatalf on a CLI failure — exactly what checking a refusal needs.
	if _, err := runSopsCLIAllowFailDoc(t, removed, "--decrypt", writeTemp(t, "rewrapped2.env", rewrapped)); err == nil {
		t.Fatal("the removed recipient can still decrypt via CLI")
	}
}

// TestDotenvLeafEncryptionSummary checks InspectLeafEncryption's leaf counts
// over a dotenv document: three leaves (DB_URL, API_KEY, EMPTY), the comment
// contributing none, and EMPTY excluded from the encrypted count because
// sops never encrypts an empty string.
func TestDotenvLeafEncryptionSummary(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(dotenvPlain), FormatDotenv, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	summary, err := InspectLeafEncryption(encrypted, FormatDotenv)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.LeafCount != 3 {
		t.Errorf("LeafCount = %d, want 3", summary.LeafCount)
	}
	if summary.EncryptedLeafCount != 2 {
		t.Errorf("EncryptedLeafCount = %d, want 2 (EMPTY is never encrypted)", summary.EncryptedLeafCount)
	}
}

// dotenvLines splits a dotenv document into its non-empty lines, so
// comparisons do not depend on trailing-newline details either side of the
// round trip is free to differ on.
func dotenvLines(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

func equalLineSets(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
