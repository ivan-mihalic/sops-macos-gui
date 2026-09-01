package gobridge

import (
	"strings"
	"testing"
)

// iniPlain is the fixture for this format: two sections, each holding string
// keys — the only shape the INI store can carry. Every top-level tree item
// must itself be a section (a TreeBranch); see the package doc comment at
// the bottom of this file for what happens when that invariant is violated.
const iniPlain = "[db]\nurl = postgres://x\npassword = secret\n\n[api]\nkey = secret2\n"

// normalizeIniLine collapses the whitespace gopkg.in/ini.v1's writer pads a
// "key = value" line with to align every "=" in a section on one column
// (observed directly: "url" and "password" in the same section come back as
// "url      = postgres://x" / "password = secret"). A section header line
// has no "=" and is returned trimmed and otherwise unchanged.
func normalizeIniLine(line string) string {
	line = strings.TrimSpace(line)
	key, value, ok := strings.Cut(line, "=")
	if !ok {
		return line
	}
	return strings.TrimSpace(key) + " = " + strings.TrimSpace(value)
}

// iniKeyLines splits an INI document into its normalized, non-empty lines,
// so comparisons do not depend on exact spacing or section-ordering details
// the gopkg.in/ini.v1 writer is free to choose (this mirrors dotenv_test.go's
// dotenvLines — INI, like dotenv, is not guaranteed to reproduce the exact
// byte layout across two different writers).
func iniKeyLines(s string) []string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if norm := normalizeIniLine(line); norm != "" {
			out = append(out, norm)
		}
	}
	return out
}

func containsAllLines(t *testing.T, doc string, want ...string) {
	t.Helper()
	lines := iniKeyLines(doc)
	for _, w := range want {
		wantNorm := normalizeIniLine(w)
		found := false
		for _, l := range lines {
			if l == wantNorm {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("missing line %q in document:\n%s", w, doc)
		}
	}
}

// containsIniLine is containsAllLines for a single ad-hoc check inline in a
// test body, normalizing the same way.
func containsIniLine(doc, want string) bool {
	wantNorm := normalizeIniLine(want)
	for _, l := range iniKeyLines(doc) {
		if l == wantNorm {
			return true
		}
	}
	return false
}

// TestINIEncryptDecryptRoundTrip exercises the bridge's own Encrypt/Decrypt
// against each other, with no CLI involved.
func TestINIEncryptDecryptRoundTrip(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if !strings.Contains(string(enc), "[sops]") {
		t.Errorf("encrypted INI is missing the sops metadata section: %s", enc)
	}
	if strings.Contains(string(enc), "secret") {
		t.Errorf("encrypted INI still contains a plaintext secret value")
	}

	dec, err := Decrypt(enc, FormatINI, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	containsAllLines(t, string(dec), "[db]", "url = postgres://x", "password = secret", "[api]", "key = secret2")
}

// TestINIBridgeEncryptsCLIDecrypts proves the bridge's INI output is a file
// the real sops CLI accepts and reads back correctly.
func TestINIBridgeEncryptsCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	enc, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	// The CLI infers INI from the .ini suffix (formats.IsIniFile).
	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "enc.ini", enc)))
	containsAllLines(t, out, "[db]", "url = postgres://x", "password = secret", "[api]", "key = secret2")
}

// TestINICLIEncryptsBridgeDecrypts is the opposite direction: a file the real
// sops CLI produced must decrypt cleanly through the bridge.
func TestINICLIEncryptsBridgeDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	in := writeTemp(t, "plain.ini", []byte(iniPlain))
	enc := runSopsCLI(t, key, nil, "--encrypt", "--age", key.Public, in)

	dec, err := Decrypt(enc, FormatINI, key.Private)
	if err != nil {
		t.Fatalf("Decrypt: %v", err)
	}
	containsAllLines(t, string(dec), "[db]", "url = postgres://x", "password = secret", "[api]", "key = secret2")
}

// TestINIDecryptToRowsSectionKeyPathsAndEncryptedFlags checks the row shape
// DecryptToRows produces for an INI document: a two-segment [section, key]
// Path per entry, InList always false (INI has no lists), string values, and
// Encrypted true for every value (none of this fixture's values is empty).
//
// The row list starts with a "DEFAULT" row this fixture never asked for —
// see TestINILoadAlwaysCarriesAnImplicitDefaultSection below for why every
// INI document, not just this one, has it.
func TestINIDecryptToRowsSectionKeyPathsAndEncryptedFlags(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	rows, err := DecryptToRows(encrypted, FormatINI, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}

	wantOrder := []string{"DEFAULT", "db.url", "db.password", "api.key"}
	if got := rowPaths(rows); strings.Join(got, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("row order/paths wrong\n got: %v\nwant: %v", got, wantOrder)
	}

	for _, tc := range []struct {
		section, key, value string
	}{
		{"db", "url", "postgres://x"},
		{"db", "password", "secret"},
		{"api", "key", "secret2"},
	} {
		row := rowByPath(t, rows, tc.section, tc.key)
		if len(row.Path) != 2 || row.Path[0] != tc.section || row.Path[1] != tc.key {
			t.Errorf("%s.%s: Path = %v, want [%q %q]", tc.section, tc.key, row.Path, tc.section, tc.key)
		}
		if row.InList {
			t.Errorf("%s.%s: InList = true, but INI has no lists", tc.section, tc.key)
		}
		if row.Kind != KindString {
			t.Errorf("%s.%s: Kind = %q, want %q", tc.section, tc.key, row.Kind, KindString)
		}
		if row.Value != tc.value {
			t.Errorf("%s.%s: Value = %q, want %q", tc.section, tc.key, row.Value, tc.value)
		}
		if !row.Encrypted {
			t.Errorf("%s.%s: Encrypted = false, want true", tc.section, tc.key)
		}
	}
}

// TestINIApplyEditsChangesValueAndCLIDecrypts proves an edited INI value
// round-trips through the real sops CLI.
func TestINIApplyEditsChangesValueAndCLIDecrypts(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	edited, err := ApplyEditsAndEncrypt(encrypted, FormatINI,
		[]Edit{{Path: []string{"db", "password"}, Value: "rotated", Kind: KindString}}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "edited.ini", edited)))
	if !containsIniLine(out, "password = rotated") {
		t.Errorf("CLI decrypt output missing the edited value; got:\n%s", out)
	}
	if containsIniLine(out, "password = secret") {
		t.Errorf("CLI decrypt output still has the old value; got:\n%s", out)
	}
	if !containsIniLine(out, "url = postgres://x") {
		t.Errorf("editing one key disturbed another; got:\n%s", out)
	}
}

// TestINIApplyChangesAddAndRemoveKeys exercises Add and Removal within an
// existing section — the shape INI actually supports for these operations
// (see TestINIApplyChangesAddAtDocumentRootProducesCleanError below for the
// shape it does not), verified against the real CLI.
func TestINIApplyChangesAddAndRemoveKeys(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	out, err := ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
		Adds:    []Add{{Parent: []string{"db"}, Key: "host", Value: "localhost", Kind: KindString}},
		Removes: []Removal{{Path: []string{"api", "key"}}},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesAndEncrypt: %v", err)
	}

	decrypted := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "changed.ini", out)))
	if !containsIniLine(decrypted, "host = localhost") {
		t.Errorf("the added key is not in the decrypted document:\n%s", decrypted)
	}
	if strings.Contains(decrypted, "secret2") {
		t.Errorf("the removed key is still in the decrypted document:\n%s", decrypted)
	}
	if !containsIniLine(decrypted, "url = postgres://x") || !containsIniLine(decrypted, "password = secret") {
		t.Errorf("an add/remove change disturbed an untouched key:\n%s", decrypted)
	}
}

// TestINIApplyChangesAcceptsKeysDotenvWouldRefuse is the INI half of
// dotenv_test.go's TestYAMLApplyChangesAcceptsKeysDotenvWouldRefuse: a key
// containing "=" is refused for FormatDotenv only (documentchanges.go's
// validateAdd gates refuseInvalidDotenvKey on `format == FormatDotenv`), and
// this proves INI does not inherit that refusal. Unlike dotenv, INI is safe
// by construction here rather than by refusal: gopkg.in/ini.v1's writer
// quotes a key containing "=" in backticks ("`FOO=BAR` = v", observed
// directly against this app's pinned sops v3.13.3) precisely so its own
// reader — the same one `sops --decrypt` uses — does not misparse it on the
// next read, so the value round-trips through the real CLI unchanged.
func TestINIApplyChangesAcceptsKeysDotenvWouldRefuse(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	out, err := ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Key: "FOO=BAR", Value: "v", Kind: KindString}},
	}, key.Private)
	if err != nil {
		t.Fatalf("INI refused key %q that only dotenv should refuse: %v", "FOO=BAR", err)
	}

	decrypted := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "ini-equals-key.ini", out)))
	if !strings.Contains(decrypted, "= v") {
		t.Errorf("the value for the '='-containing key did not round-trip:\n%s", decrypted)
	}

	rows, err := DecryptToRows(out, FormatINI, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "db", "FOO=BAR").Value; got != "v" {
		t.Fatalf("db.\"FOO=BAR\" = %q, want %q", got, "v")
	}
}

// TestINIRecipientsJSONReadsWithoutKey checks that recipient metadata is
// readable for an INI document without any age identity.
func TestINIRecipientsJSONReadsWithoutKey(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	recipients, err := Recipients(encrypted, FormatINI)
	if err != nil {
		t.Fatalf("Recipients: %v", err)
	}
	if len(recipients) != 1 || recipients[0] != key.Public {
		t.Fatalf("Recipients = %v, want [%s]", recipients, key.Public)
	}
}

// TestINIUpdateRecipientsRewrapsAndCLIVerifies mirrors the dotenv/YAML/JSON
// equivalents: rewrap for exactly the requested people, verified against the
// real CLI rather than the bridge's own Decrypt.
func TestINIUpdateRecipientsRewrapsAndCLIVerifies(t *testing.T) {
	owner := newAgeKeyPair(t)
	kept := newAgeKeyPair(t)
	added := newAgeKeyPair(t)
	removed := newAgeKeyPair(t)

	encrypted := runSopsCLI(t, owner, nil,
		"--encrypt", "--age", owner.Public+","+removed.Public,
		writeTemp(t, "plain.ini", []byte(iniPlain)))

	rewrapped, err := UpdateRecipients(encrypted, FormatINI, []string{kept.Public, added.Public}, owner.Private)
	if err != nil {
		t.Fatalf("UpdateRecipients: %v", err)
	}

	for _, k := range []ageKeyPair{kept, added} {
		out := string(runSopsCLI(t, k, nil, "--decrypt", writeTemp(t, "rewrapped.ini", rewrapped)))
		containsAllLines(t, out, "[db]", "url = postgres://x", "password = secret", "[api]", "key = secret2")
	}

	if _, err := runSopsCLIAllowFailDoc(t, removed, "--decrypt", writeTemp(t, "rewrapped2.ini", rewrapped)); err == nil {
		t.Fatal("the removed recipient can still decrypt via CLI")
	}
}

// TestINILeafEncryptionSummary checks InspectLeafEncryption's leaf counts
// over an INI document: three leaves, all three encrypted (none is empty).
func TestINILeafEncryptionSummary(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	summary, err := InspectLeafEncryption(encrypted, FormatINI)
	if err != nil {
		t.Fatalf("InspectLeafEncryption: %v", err)
	}
	if summary.LeafCount != 3 {
		t.Errorf("LeafCount = %d, want 3", summary.LeafCount)
	}
	if summary.EncryptedLeafCount != 3 {
		t.Errorf("EncryptedLeafCount = %d, want 3", summary.EncryptedLeafCount)
	}
}

// TestINILoadAlwaysCarriesAnImplicitDefaultSection pins a quirk found while
// writing the tests above: gopkg.in/ini.v1's Sections() always includes an
// implicit "DEFAULT" section, even when the source document has no top-level
// key outside a [section] header and even when the document is completely
// empty. LoadPlainFile therefore turns *any* INI document into a tree whose
// first top-level item is "DEFAULT" — empty (KindEmptyMap) when nothing
// precedes the first section, populated with real keys when something does.
//
// This is not the store.go:42 failure the tests below pin — loading such a
// file never errors, and the phantom item round-trips through
// EmitPlainFile's DeleteSection(ini.DefaultSection) + re-add without ever
// printing a "[DEFAULT]" header, so the CLI reads it back unchanged. What it
// does affect is DecryptToRows: every INI document's row list carries this
// leading phantom row, and a caller (the Swift editor) needs to know to
// either hide a Kind-KindEmptyMap row literally named "DEFAULT", or accept
// that it renders as an always-present, always-empty section.
func TestINILoadAlwaysCarriesAnImplicitDefaultSection(t *testing.T) {
	key := newAgeKeyPair(t)

	// This fixture has a real top-level key before its only section header —
	// the shape the DEFAULT section exists to hold.
	const withTopLevelKey = "standalone = value\n[section]\nkey = val\n"

	encrypted, err := Encrypt([]byte(withTopLevelKey), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	rows, err := DecryptToRows(encrypted, FormatINI, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	wantOrder := []string{"DEFAULT.standalone", "section.key"}
	if got := rowPaths(rows); strings.Join(got, ",") != strings.Join(wantOrder, ",") {
		t.Fatalf("row order/paths wrong\n got: %v\nwant: %v", got, wantOrder)
	}

	// And it round-trips through the real CLI: the "DEFAULT" section name
	// never appears as literal text — ini.v1 special-cases it away.
	out := string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "default-section.ini", encrypted)))
	if !containsIniLine(out, "standalone = value") || !containsIniLine(out, "key = val") {
		t.Errorf("the top-level key or the sectioned key did not round-trip:\n%s", out)
	}
	if strings.Contains(out, "DEFAULT") {
		t.Errorf("the implicit DEFAULT section name leaked into the emitted file:\n%s", out)
	}
}

// -----------------------------------------------------------------------
// Pinned edge behaviour: the INI store's section invariant
// -----------------------------------------------------------------------
//
// stores/ini/store.go (sops v3.13.3) requires every top-level tree item to
// be a section — a TreeBranch of keys — never a scalar. encodeTree asserts
// this directly (store.go:42, "Section values should always be
// TreeBranches") and returns a plain Go error, not a panic, when it is not
// true.
//
// Loading a real INI file can never produce a tree that violates this: a
// key written before any [section] header lands in an implicit "DEFAULT"
// section (still a TreeBranch), which sops's ini.v1 writer round-trips
// without even printing a "[DEFAULT]" header — verified empirically against
// this app's pinned sops v3.13.3 (LoadPlainFile → EmitPlainFile on
// "foo=bar\n[section]\nkey=val\n" reproduces "foo = bar" ungrouped, then
// "[section]\nkey = val", with no error). So the invariant is never at risk
// from a file a human or the CLI could have written.
//
// It CAN be violated through this app's own Add API, though: Add only ever
// creates a scalar leaf (see documentchanges.go's parseAddValue — there is
// no way to add a container), and the document root is a valid Add target
// (Parent: []string{} addresses the root map, same as every other format).
// Adding a scalar directly at the INI root therefore builds exactly the tree
// shape the store refuses to encode. This is pinned here as the boundary
// this format actually has, rather than an invariant the caller has to know
// about ini.v1 to avoid.

// TestINIApplyChangesAddAtDocumentRootProducesCleanError proves that a
// root-level Add — the one shape that can build a non-section top-level tree
// item — is refused with a plain error, never a panic, and that the error
// does not echo the value that would have been written (CLAUDE.md: no
// secret values in errors).
func TestINIApplyChangesAddAtDocumentRootProducesCleanError(t *testing.T) {
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("ApplyChangesAndEncrypt panicked on a root-level INI add: %v", r)
			}
		}()
		_, err = ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
			Adds: []Add{{Key: "top_level_secret", Value: "s3cr3t", Kind: KindString}},
		}, key.Private)
	}()

	if err == nil {
		t.Fatal("a root-level scalar add on an INI document was accepted")
	}
	if strings.Contains(err.Error(), "s3cr3t") {
		t.Errorf("refusal echoes the value that would have been written: %q", err.Error())
	}
}

// -----------------------------------------------------------------------
// SOPS-38 phase F2 task 4: refuseInvalidINIKey
// -----------------------------------------------------------------------
//
// These four shapes were found by probing gopkg.in/ini.v1's real writer
// directly (a throwaway test, not committed) rather than assumed from
// dotenv's own rule — see refuseInvalidINIKey's doc comment
// (documentchanges.go) for exactly what each shape does when it is not
// refused. The two negative-side tests below (TestINIApplyChangesAcceptsKeys
// DotenvWouldRefuse above, and TestINIApplyChangesAcceptsBracketsAndBacktick
// below) are the discriminating half: if this guard were accidentally wider
// than these four shapes, one of them would fail instead of passing for the
// wrong reason.

// TestINIApplyChangesRefusesKeyContainingNewline proves the "\n" case: an
// embedded newline is not escaped by ini.v1's key-name quoting at all, so it
// lands raw in the middle of a "key = value" line — probed directly, the
// resulting file fails to decrypt afterwards with "this file could not be
// read as a SOPS document", not just for this entry but for the whole file.
func TestINIApplyChangesRefusesKeyContainingNewline(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	_, err = ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Key: "weird\nnewline", Value: "v", Kind: KindString}},
	}, key.Private)
	if err == nil {
		t.Fatal("an INI key containing a line break was accepted")
	}
	if strings.Contains(err.Error(), "v") && strings.Contains(err.Error(), "weird\nnewline=v") {
		t.Fatalf("refusal echoes more than the key: %q", err.Error())
	}
}

// TestINIApplyChangesRefusesKeyContainingCarriageReturn proves the "\r"
// case: probed directly, ini.v1's writer silently drops the "\r" from the
// key it writes — "weird\rcr" saves and reads back as "weirdcr", with no
// error at any stage — so the entry would end up under a name other than
// the one the user just typed. This is refused even though nothing here
// makes the *file* undecryptable, for the same reason
// refuseInvalidDotenvKey refuses dotenv's newline case: the key that comes
// back is not the key that went in.
func TestINIApplyChangesRefusesKeyContainingCarriageReturn(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	_, err = ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Key: "weird\rcr", Value: "v", Kind: KindString}},
	}, key.Private)
	if err == nil {
		t.Fatal("an INI key containing a carriage return was accepted")
	}
}

// TestINIApplyChangesRefusesKeyStartingWithHashOrSemicolon proves the "#"/
// ";" case: both are INI comment markers, so a key starting with either is
// written as a comment line — probed directly, the save itself reports no
// error, but decrypting the result afterwards fails with "this file does
// not match its own message authentication code", because the bytes the MAC
// covers and the key/value pair rendered on screen have desynced. Worse than
// the dotenv equivalent (TestDotenvApplyChangesRefusesKeyStartingWithHash,
// where only the one entry silently disappears): here the whole file stops
// decrypting.
func TestINIApplyChangesRefusesKeyStartingWithHashOrSemicolon(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	for _, name := range []string{"#hashprefix", ";semiprefix"} {
		_, err = ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
			Adds: []Add{{Parent: []string{"db"}, Key: name, Value: "v", Kind: KindString}},
		}, key.Private)
		if err == nil {
			t.Fatalf("an INI key starting with a comment marker (%q) was accepted", name)
		}
	}
}

// TestINIApplyChangesAcceptsBracketsAndBacktick is the discriminating
// negative case for the two tests above: "[", "]" and a backtick round-trip
// through the real CLI unchanged, because a *key* line inside a section has
// no bracket syntax of its own (only a section *header* line does, and this
// app's Add API can never create one — see refuseInvalidINIKey's doc
// comment) and ini.v1's writer triple-quotes a key containing a backtick.
// If refuseInvalidINIKey were accidentally refusing these too, this test
// would fail instead of the two above passing for the wrong reason.
func TestINIApplyChangesAcceptsBracketsAndBacktick(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(iniPlain), FormatINI, EncryptOpts{AgeRecipients: []string{key.Public}})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}

	out, err := ApplyChangesAndEncrypt(encrypted, FormatINI, ChangeSet{
		Adds: []Add{
			{Parent: []string{"db"}, Key: "weird]bracket", Value: "v1", Kind: KindString},
			{Parent: []string{"db"}, Key: "weird[bracket", Value: "v2", Kind: KindString},
			{Parent: []string{"db"}, Key: "weird`tick", Value: "v3", Kind: KindString},
		},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesAndEncrypt refused a key this format can hold safely: %v", err)
	}

	rows, err := DecryptToRows(out, FormatINI, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	for _, tc := range []struct{ key, value string }{
		{"weird]bracket", "v1"}, {"weird[bracket", "v2"}, {"weird`tick", "v3"},
	} {
		if got := rowByPath(t, rows, "db", tc.key).Value; got != tc.value {
			t.Errorf("db.%q = %q, want %q", tc.key, got, tc.value)
		}
	}
}
