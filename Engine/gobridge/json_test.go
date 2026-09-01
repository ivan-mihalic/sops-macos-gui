package gobridge

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

// jsonPlain is the fixture for this format: nested maps, a list, and one of
// each Kind the JSON store can carry (string/int/bool/float/null) — the shape
// the task brief asks the row tests to pin.
const jsonPlain = `{
  "db": {
    "url": "postgres://x",
    "port": 5432,
    "ssl": true,
    "ratio": 0.5,
    "note": null
  },
  "tags": ["a", "b"]
}
`

// decodeJSONDoc parses a JSON document into a generic map for structural
// comparison. Byte-for-byte comparison is the wrong tool here — the bridge's
// store reindents with sops's own JSON emitter (encoding/json.Indent with a
// tab), which is not guaranteed to match the real CLI's own formatting choices
// byte for byte — so round trips are compared by decoded structure, the same
// way dotenv_test.go compares by line set rather than raw bytes.
func decodeJSONDoc(t *testing.T, s string) map[string]interface{} {
	t.Helper()
	var v map[string]interface{}
	if err := json.Unmarshal([]byte(s), &v); err != nil {
		t.Fatalf("decode json %q: %v", s, err)
	}
	return v
}

func equalJSONDocs(t *testing.T, got, want string) bool {
	t.Helper()
	return reflect.DeepEqual(decodeJSONDoc(t, got), decodeJSONDoc(t, want))
}

// TestJSONEncryptDecryptRoundTrip exercises the bridge's own Encrypt/Decrypt
// against each other, with no CLI involved — the fast check that the new
// Format case wires into the same code path YAML and dotenv already use.
func TestJSONEncryptDecryptRoundTrip(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if !strings.Contains(string(enc), `"sops"`) {
		t.Errorf("encrypted JSON is missing the sops metadata block: %s", enc)
	}
	if strings.Contains(string(enc), "postgres://x") {
		t.Errorf("encrypted JSON still contains the plaintext value")
	}

	dec, err := Decrypt(enc, FormatJSON, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !equalJSONDocs(t, string(dec), jsonPlain) {
		t.Errorf("round trip did not preserve content:\n got:  %s\n want: %s", dec, jsonPlain)
	}
}

// TestJSONBridgeEncryptsCLIDecrypts proves the bridge's JSON output is a file
// the real sops CLI accepts and reads back correctly.
func TestJSONBridgeEncryptsCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// The CLI infers JSON from the .json suffix (formats.IsJSONFile).
	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "enc.json", enc)))
	if !equalJSONDocs(t, out, jsonPlain) {
		t.Errorf("CLI decrypt output did not match the plaintext:\n got:  %s\n want: %s", out, jsonPlain)
	}
}

// TestJSONCLIEncryptsBridgeDecrypts is the opposite direction: a file the real
// sops CLI produced must decrypt cleanly through the bridge.
func TestJSONCLIEncryptsBridgeDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	in := writeTemp(t, "plain.json", []byte(jsonPlain))
	enc := runSopsCLI(t, key, nil, "--encrypt", "--age", key.Public, in)

	dec, err := Decrypt(enc, FormatJSON, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	if !equalJSONDocs(t, string(dec), jsonPlain) {
		t.Errorf("round trip did not preserve content:\n got:  %s\n want: %s", dec, jsonPlain)
	}
}

// TestJSONDecryptToRowsNestedPathsListsAndKinds checks the row shape
// DecryptToRows produces for a JSON document: multi-segment paths for nested
// maps, InList true for list members, and every Kind the fixture carries.
func TestJSONDecryptToRowsNestedPathsListsAndKinds(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	rows, err := DecryptToRows(encrypted, FormatJSON, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}

	wantOrder := []string{"db.url", "db.port", "db.ssl", "db.ratio", "db.note", "tags.0", "tags.1"}
	if got := rowPaths(rows); strings.Join(got, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("row order/paths wrong\n got: %v\nwant: %v", got, wantOrder)
	}

	for _, tc := range []struct {
		path      []string
		kind      string
		value     string
		inList    bool
		encrypted bool
	}{
		{[]string{"db", "url"}, KindString, "postgres://x", false, true},
		{[]string{"db", "port"}, KindInt, "5432", false, true},
		{[]string{"db", "ssl"}, KindBool, "true", false, true},
		{[]string{"db", "ratio"}, KindFloat, "0.5", false, true},
		{[]string{"db", "note"}, KindNull, "", false, false},
		{[]string{"tags", "0"}, KindString, "a", true, true},
		{[]string{"tags", "1"}, KindString, "b", true, true},
	} {
		r := rowByPath(t, rows, tc.path...)
		if r.Kind != tc.kind {
			t.Errorf("%s: Kind = %q, want %q", strings.Join(tc.path, "."), r.Kind, tc.kind)
		}
		if r.Value != tc.value {
			t.Errorf("%s: Value = %q, want %q", strings.Join(tc.path, "."), r.Value, tc.value)
		}
		if r.InList != tc.inList {
			t.Errorf("%s: InList = %v, want %v", strings.Join(tc.path, "."), r.InList, tc.inList)
		}
		if r.Encrypted != tc.encrypted {
			t.Errorf("%s: Encrypted = %v, want %v", strings.Join(tc.path, "."), r.Encrypted, tc.encrypted)
		}
	}
}

// TestJSONApplyEditsChangesValueAndCLIDecrypts proves an edited JSON value
// round-trips through the real sops CLI.
func TestJSONApplyEditsChangesValueAndCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	edited, err := ApplyEditsAndEncrypt(encrypted, FormatJSON,
		[]Edit{{Path: []string{"db", "port"}, Value: "6543", Kind: KindInt}}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "edited.json", edited)))
	if !strings.Contains(out, `"port": 6543`) {
		t.Errorf("CLI decrypt output missing the edited value; got:\n%s", out)
	}
	if !strings.Contains(out, "postgres://x") {
		t.Errorf("editing one key disturbed another; got:\n%s", out)
	}
}

// TestJSONApplyChangesAddAndRemoveKeys exercises Add and Removal over JSON's
// nested shape — a nested add under an existing map, and a leaf removal — the
// structural half of the document API, verified against the real CLI.
func TestJSONApplyChangesAddAndRemoveKeys(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	out, err := ApplyChangesAndEncrypt(encrypted, FormatJSON, ChangeSet{
		Adds:    []Add{{Parent: []string{"db"}, Key: "region", Value: "us-east", Kind: KindString}},
		Removes: []Removal{{Path: []string{"db", "note"}}},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesAndEncrypt: %v", err)
	}

	decrypted := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "changed.json", out)))
	if !strings.Contains(decrypted, `"region": "us-east"`) {
		t.Errorf("the added key is not in the decrypted document:\n%s", decrypted)
	}
	if strings.Contains(decrypted, "note") {
		t.Errorf("the removed key is still in the decrypted document:\n%s", decrypted)
	}
	if !strings.Contains(decrypted, "postgres://x") {
		t.Errorf("an add/remove change disturbed an untouched key:\n%s", decrypted)
	}
}

// TestJSONApplyChangesAcceptsKeysDotenvWouldRefuse is the JSON half of
// dotenv_test.go's TestYAMLApplyChangesAcceptsKeysDotenvWouldRefuse: a key
// name containing "=" or starting with "#" is refused when the target format
// is FormatDotenv (refuseInvalidDotenvKey, gated `if format == FormatDotenv`
// in documentchanges.go's validateAdd) precisely because the dotenv store's
// own line grammar cannot round-trip it. JSON has no such grammar hazard —
// object keys are JSON strings, and any string is a valid one — so the same
// names must be accepted here. This is the discriminating half: if the guard
// were accidentally format-blind rather than dotenv-specific, this test
// would fail instead of dotenv's refusal tests passing for the wrong reason.
func TestJSONApplyChangesAcceptsKeysDotenvWouldRefuse(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	for _, name := range []string{"FOO=BAR", "#X"} {
		out, err := ApplyChangesAndEncrypt(encrypted, FormatJSON, ChangeSet{
			Adds: []Add{{Key: name, Value: "v", Kind: KindString}},
		}, key.Private)
		if err != nil {
			t.Fatalf("JSON refused key %q that only dotenv should refuse: %v", name, err)
		}
		rows, err := DecryptToRows(out, FormatJSON, key.Private)
		if err != nil {
			t.Fatalf("DecryptToRows: %v", err)
		}
		if got := rowByPath(t, rows, name).Value; got != "v" {
			t.Fatalf("%s = %q, want %q", name, got, "v")
		}
	}
}

// TestJSONRecipientsJSONReadsWithoutKey checks that recipient metadata is
// readable for a JSON document without any age identity.
func TestJSONRecipientsJSONReadsWithoutKey(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	recipients, err := Recipients(encrypted, FormatJSON)
	if err != nil {
		t.Fatalf("Recipients: %v", err)
	}
	if len(recipients) != 1 || recipients[0] != key.Public {
		t.Fatalf("Recipients = %v, want [%s]", recipients, key.Public)
	}
}

// TestJSONUpdateRecipientsRewrapsAndCLIVerifies mirrors the dotenv/YAML
// equivalents: rewrap for exactly the requested people, verified against the
// real CLI rather than the bridge's own Decrypt.
func TestJSONUpdateRecipientsRewrapsAndCLIVerifies(t *testing.T) {
	owner := newAgeKeyPair(t)
	kept := newAgeKeyPair(t)
	added := newAgeKeyPair(t)
	removed := newAgeKeyPair(t)

	encrypted := runSopsCLI(t, owner, nil,
		"--encrypt", "--age", owner.Public+","+removed.Public,
		writeTemp(t, "plain.json", []byte(jsonPlain)))

	rewrapped, err := UpdateRecipients(encrypted, FormatJSON, []string{kept.Public, added.Public}, owner.Private)
	if err != nil {
		t.Fatalf("UpdateRecipients: %v", err)
	}

	for _, k := range []ageKeyPair{kept, added} {
		out := string(runSopsCLI(t, k, nil, "--decrypt", writeTemp(t, "rewrapped.json", rewrapped)))
		if !equalJSONDocs(t, out, jsonPlain) {
			t.Errorf("%s cannot decrypt the rewrapped document via CLI:\n got:  %s\n want: %s",
				k.Public, out, jsonPlain)
		}
	}

	if _, err := runSopsCLIAllowFailDoc(t, removed, "--decrypt", writeTemp(t, "rewrapped2.json", rewrapped)); err == nil {
		t.Fatal("the removed recipient can still decrypt via CLI")
	}
}

// TestJSONLeafEncryptionSummary checks InspectLeafEncryption's leaf counts
// over a JSON document: seven leaves, six encrypted (db.note is a null,
// which sops never encrypts).
func TestJSONLeafEncryptionSummary(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(jsonPlain), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	summary, err := InspectLeafEncryption(encrypted, FormatJSON)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.LeafCount != 7 {
		t.Errorf("LeafCount = %d, want 7", summary.LeafCount)
	}
	if summary.EncryptedLeafCount != 6 {
		t.Errorf("EncryptedLeafCount = %d, want 6 (db.note is never encrypted)", summary.EncryptedLeafCount)
	}
}

// -----------------------------------------------------------------------
// Pinned edge behaviours: JSON store over an empty document and a
// non-object top level.
//
// stores/json/store.go (sops v3.13.3) requires a top-level '{' — its own
// decoder reads the first JSON token and refuses anything else with a
// message that names what it got instead (treeBranchFromJSON). That refusal
// text can name the offending value verbatim for a top-level scalar
// ("Got \"hello\" of type string instead"), which would be a plaintext leak
// if it reached the caller — but bridge.Encrypt never propagates a
// LoadPlainFile error's own text (see describeYAMLFailure's doc comment),
// so the two tests below also pin that the leaking half of the upstream
// message never surfaces here.
// -----------------------------------------------------------------------

// TestJSONEncryptAcceptsEmptyObject pins that "{}" is a valid, if empty, JSON
// document: LoadPlainFile succeeds with a single empty branch, and the bridge
// encrypts it to a file with sops metadata and no data rows.
func TestJSONEncryptAcceptsEmptyObject(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte("{}\n"), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt of an empty JSON object: %v", err)
	}

	rows, err := DecryptToRows(enc, FormatJSON, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected no rows for an empty document, got %v", rowPaths(rows))
	}
}

// TestJSONEncryptRefusesEmptyDocument pins that a zero-byte "document" is a
// clean error, not a panic — the JSON decoder returns io.EOF from the very
// first token read, and the bridge turns that into a plain refusal.
func TestJSONEncryptRefusesEmptyDocument(t *testing.T) {
	key := newAgeKeyPair(t)

	_, err := Encrypt([]byte(""), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err == nil {
		t.Fatal("an empty JSON document was accepted")
	}
}

// TestJSONEncryptRefusesTopLevelArray pins that a top-level array is a clean
// error, and that the refusal does not repeat the document's own content back
// (CLAUDE.md: no secret values in errors).
func TestJSONEncryptRefusesTopLevelArray(t *testing.T) {
	key := newAgeKeyPair(t)

	_, err := Encrypt([]byte(`["top", "secret"]`), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err == nil {
		t.Fatal("a top-level JSON array was accepted")
	}
	if strings.Contains(err.Error(), "top") || strings.Contains(err.Error(), "secret") {
		t.Errorf("refusal echoes document content: %q", err.Error())
	}
}

// TestJSONEncryptRefusesTopLevelScalar pins the same for a bare scalar —
// upstream's own message for this case quotes the value verbatim
// ("Got \"hello\" of type string instead"), so this is the case most likely
// to leak if the wrapping in bridge.Encrypt ever regressed.
func TestJSONEncryptRefusesTopLevelScalar(t *testing.T) {
	key := newAgeKeyPair(t)

	_, err := Encrypt([]byte(`"a-secret-value"`), FormatJSON, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err == nil {
		t.Fatal("a top-level JSON scalar was accepted")
	}
	if strings.Contains(err.Error(), "a-secret-value") {
		t.Fatalf("refusal echoes the document's own scalar value: %q", err.Error())
	}
}
