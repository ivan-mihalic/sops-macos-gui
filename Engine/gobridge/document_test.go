package gobridge

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/getsops/sops/v3/logging"
)

// richPlainYAML deliberately contains one of everything the editor has to be
// able to show without damaging: a leading comment, an inline comment, every
// YAML scalar type, a string that only stays a string because it is quoted, a
// block scalar, a value YAML would want to quote, a nested map, a list of
// maps, and an empty map and list.
const richPlainYAML = `# who this file belongs to
db:
    # the host is not a secret
    host: localhost
    port: 5432
    password: hunter2
    enabled: true
    ratio: 0.75
    nothing: null
    created: 2024-01-02T03:04:05Z
    quoted_number: "5432"
    multiline: |
        line one
        line two
    special: 'value: with colon'
api_key: sk-live-abc123
servers:
    - name: alpha
      ip: 10.0.0.1
    - name: beta
      ip: 10.0.0.2
empty_map: {}
empty_list: []
`

// encryptWithCLI builds a fixture the way a user's repository really would:
// with the sops binary, never by hand. Hand-written fixtures in this repo have
// twice encoded what the implementer believed the tool emits.
func encryptWithCLI(t *testing.T, key ageKeyPair, plain string, extraArgs ...string) []byte {
	t.Helper()
	in := writeTemp(t, "plain.yaml", []byte(plain))
	args := append([]string{"--encrypt", "--age", key.Public}, extraArgs...)
	return runSopsCLI(t, key, nil, append(args, in)...)
}

// cliDecrypt is the compatibility oracle: what the standard tool sees.
func cliDecrypt(t *testing.T, key ageKeyPair, encrypted []byte) string {
	t.Helper()
	return string(runSopsCLI(t, key, nil, "--decrypt", writeTemp(t, "enc.yaml", encrypted)))
}

func rowByPath(t *testing.T, rows []Row, path ...string) Row {
	t.Helper()
	want := strings.Join(path, "\x1f")
	for _, r := range rows {
		if strings.Join(r.Path, "\x1f") == want {
			return r
		}
	}
	t.Fatalf("no row at path %v; rows present: %v", path, rowPaths(rows))
	return Row{}
}

func rowPaths(rows []Row) []string {
	out := make([]string, 0, len(rows))
	for _, r := range rows {
		out = append(out, strings.Join(r.Path, "."))
	}
	return out
}

// -----------------------------------------------------------------------
// Reading
// -----------------------------------------------------------------------

// The row list is what the editor renders. Order is the file's order, types
// are the file's types, and the encrypted/plaintext split is the file's own.
func TestDecryptToRowsProducesTheFilesOwnOrderAndTypes(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}

	wantOrder := []string{
		"db.host", "db.port", "db.password", "db.enabled", "db.ratio",
		"db.nothing", "db.created", "db.quoted_number", "db.multiline", "db.special",
		"api_key",
		"servers.0.name", "servers.0.ip", "servers.1.name", "servers.1.ip",
		"empty_map", "empty_list",
	}
	got := rowPaths(rows)
	if strings.Join(got, ",") != strings.Join(wantOrder, ",") {
		t.Errorf("row order/paths wrong\n got: %v\nwant: %v", got, wantOrder)
	}

	for _, tc := range []struct{ path, kind, value string }{
		{"db.host", KindString, "localhost"},
		{"db.port", KindInt, "5432"},
		{"db.password", KindString, "hunter2"},
		{"db.enabled", KindBool, "true"},
		{"db.ratio", KindFloat, "0.75"},
		{"db.nothing", KindNull, ""},
		{"db.created", KindTimestamp, "2024-01-02T03:04:05Z"},
		{"db.quoted_number", KindString, "5432"},
		{"db.multiline", KindString, "line one\nline two\n"},
		{"db.special", KindString, "value: with colon"},
		{"empty_map", KindEmptyMap, ""},
		{"empty_list", KindEmptyList, ""},
	} {
		r := rowByPath(t, rows, strings.Split(tc.path, ".")...)
		if r.Kind != tc.kind {
			t.Errorf("%s: kind = %q, want %q", tc.path, r.Kind, tc.kind)
		}
		if r.Value != tc.value {
			t.Errorf("%s: value = %q, want %q", tc.path, r.Value, tc.value)
		}
	}

	// A quoted "5432" and an unquoted 5432 must not be indistinguishable to
	// the editor: that is exactly how a port number gets written back quoted.
	if rowByPath(t, rows, "db", "port").Kind == rowByPath(t, rows, "db", "quoted_number").Kind {
		t.Errorf("an int and a quoted numeric string came back with the same kind")
	}
}

// Whether a value is ciphertext on disk is a property of the file, and the
// editor needs it to decide what to mask. With no encrypted_regex everything
// is encrypted except nulls, which sops never encrypts.
func TestDecryptToRowsReportsWhichValuesAreCiphertextOnDisk(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}

	if !rowByPath(t, rows, "db", "password").Encrypted {
		t.Errorf("db.password is ENC[…] on disk but was not reported as encrypted")
	}
	if rowByPath(t, rows, "db", "nothing").Encrypted {
		t.Errorf("a null is never encrypted by sops, but was reported as encrypted")
	}
}

// With encrypted_regex most of the file stays readable on disk. The editor
// must be able to tell the two halves apart, or it masks the wrong things.
func TestDecryptToRowsSeparatesEncryptedFromPlaintextByRule(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML,
		"--encrypted-regex", "^(password|api_key)$")

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}

	for path, want := range map[string]bool{
		"db.password": true,
		"api_key":     true,
		"db.host":     false,
		"db.port":     false,
	} {
		r := rowByPath(t, rows, strings.Split(path, ".")...)
		if r.Encrypted != want {
			t.Errorf("%s: Encrypted = %v, want %v", path, r.Encrypted, want)
		}
	}
}

// `sops -e` on `{}` produces a file whose only content is the sops block.
// Opening it must give an empty form, not an error and not a phantom row.
func TestDecryptToRowsOnADocumentThatIsOnlyTheSopsBlock(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, "{}\n")

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if len(rows) != 0 {
		t.Errorf("expected no rows, got %v", rowPaths(rows))
	}
}

func TestDecryptToRowsOnASingleKeyDocument(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, "only: value\n")

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if len(rows) != 1 || rows[0].Value != "value" || rows[0].Kind != KindString {
		t.Errorf("unexpected rows: %+v", rows)
	}
}

// -----------------------------------------------------------------------
// The identity guard, on the new entry points
// -----------------------------------------------------------------------

func TestDecryptToRowsRejectsAnEmptyKey(t *testing.T) {
	clearAmbientAgeEnv(t)
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)
	// Every ambient vector sops would consult is pointed at the real key.
	t.Setenv("SOPS_AGE_KEY", key.Private)

	for name, keyArg := range map[string]string{
		"empty":        "",
		"spaces":       "   ",
		"comment only": "# exported\n",
		"public key":   key.Public,
		"plugin":       "AGE-PLUGIN-YUBIKEY-1QQQQQQQQQQQQQ",
	} {
		t.Run(name, func(t *testing.T) {
			rows, err := DecryptToRows(encrypted, keyArg)
			if err == nil {
				t.Fatalf("DecryptToRows succeeded with no supplied identity and returned %d rows", len(rows))
			}
			if rows != nil {
				t.Errorf("rows returned alongside an error: %v", rowPaths(rows))
			}
			if !strings.Contains(err.Error(), "age identity") {
				t.Errorf("failed for the wrong reason: %v", err)
			}
		})
	}
}

func TestApplyEditsRejectsAnEmptyKey(t *testing.T) {
	clearAmbientAgeEnv(t)
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)
	t.Setenv("SOPS_AGE_KEY", key.Private)

	out, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"db", "host"}, Value: "elsewhere", Kind: KindString}}, "")
	if err == nil {
		t.Fatalf("ApplyEditsAndEncrypt succeeded with no supplied identity (%d bytes)", len(out))
	}
	if out != nil {
		t.Errorf("bytes returned alongside an error")
	}
	if !strings.Contains(err.Error(), "age identity") {
		t.Errorf("failed for the wrong reason: %v", err)
	}
}

// SOPS_AGE_KEY_CMD is a command line sops executes. Neither entry point may
// ever reach it.
func TestDocumentAPINeverExecutesSopsAgeKeyCmd(t *testing.T) {
	clearAmbientAgeEnv(t)
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	marker := filepath.Join(t.TempDir(), "marker")
	t.Setenv("SOPS_AGE_KEY_CMD", "/usr/bin/touch "+marker)

	if _, err := DecryptToRows(encrypted, ""); err == nil {
		t.Errorf("DecryptToRows succeeded with no identity")
	}
	if _, err := ApplyEditsAndEncrypt(encrypted, nil, ""); err == nil {
		t.Errorf("ApplyEditsAndEncrypt succeeded with no identity")
	}
	if _, statErr := os.Stat(marker); statErr == nil {
		t.Fatalf("the engine executed SOPS_AGE_KEY_CMD: %s was created", marker)
	}
}

// -----------------------------------------------------------------------
// Writing
// -----------------------------------------------------------------------

// The load-bearing test of the whole milestone. After an edit, everything the
// user did not touch must come back out of the standard tool unchanged:
// comments, key order, quoting, block scalars, types, and the other values.
func TestEditPreservesCommentsAndOrder(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	before := cliDecrypt(t, key, encrypted)

	edited, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"db", "password"}, Value: "correct horse", Kind: KindString}},
		key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	after := cliDecrypt(t, key, edited)

	beforeLines := strings.Split(before, "\n")
	afterLines := strings.Split(after, "\n")
	if len(beforeLines) != len(afterLines) {
		t.Fatalf("line count changed: %d -> %d\nbefore:\n%s\nafter:\n%s",
			len(beforeLines), len(afterLines), before, after)
	}
	var changed []int
	for i := range beforeLines {
		if beforeLines[i] != afterLines[i] {
			changed = append(changed, i)
		}
	}
	if len(changed) != 1 {
		t.Fatalf("expected exactly one changed line, got %d\nbefore:\n%s\nafter:\n%s",
			len(changed), before, after)
	}
	if strings.TrimSpace(afterLines[changed[0]]) != "password: correct horse" {
		t.Errorf("the changed line is not the edit: %q", afterLines[changed[0]])
	}
	if !strings.Contains(after, "# who this file belongs to") ||
		!strings.Contains(after, "# the host is not a secret") {
		t.Errorf("a comment was dropped:\n%s", after)
	}
}

func TestEditedFileDecryptsWithTheSopsCLI(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	edited, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"api_key"}, Value: "sk-live-rotated", Kind: KindString}},
		key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	// Not just "it decrypts": the MAC must verify, which sops checks for us,
	// and the new value must actually be there.
	out := cliDecrypt(t, key, edited)
	if !strings.Contains(out, "api_key: sk-live-rotated") {
		t.Errorf("the edit did not land:\n%s", out)
	}
	if strings.Contains(string(edited), "sk-live-rotated") {
		t.Errorf("the new value was written in plaintext")
	}
}

// The rule that governs saving: the file's own metadata wins. Re-deriving
// recipients from .sops.yaml during a save would change who can read the file
// without telling anyone; re-wrapping keys is `updatekeys`, which is M4.
func TestSavePreservesTheFilesOwnRecipientsNotTheConfigs(t *testing.T) {
	owner := newAgeKeyPair(t)
	colleague := newAgeKeyPair(t)

	// A file encrypted to two recipients, with a rule set that a .sops.yaml
	// might well have drifted away from.
	encrypted := encryptWithCLI(t, owner, richPlainYAML,
		"--age", owner.Public+","+colleague.Public,
		"--encrypted-regex", "^(password|api_key)$",
		"--shamir-secret-sharing-threshold", "1")

	// A .sops.yaml exists next door naming a completely different recipient.
	// Nothing in the save path may consult it.
	stranger := newAgeKeyPair(t)
	confDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(confDir, ".sops.yaml"),
		[]byte("creation_rules:\n  - age: "+stranger.Public+"\n"), 0o600); err != nil {
		t.Fatalf("write .sops.yaml: %v", err)
	}
	t.Chdir(confDir)

	edited, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"db", "password"}, Value: "rotated", Kind: KindString}},
		owner.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	out := string(edited)

	for _, recipient := range []string{owner.Public, colleague.Public} {
		if !strings.Contains(out, recipient) {
			t.Errorf("a recipient the file declared was dropped by the save")
		}
	}
	if strings.Contains(out, stranger.Public) {
		t.Errorf("the save added a recipient from .sops.yaml — that is updatekeys' job, not a save's")
	}
	if !strings.Contains(out, "encrypted_regex: ^(password|api_key)$") {
		t.Errorf("the file's own encrypted_regex was not preserved:\n%s", out)
	}
	if !strings.Contains(out, "shamir_threshold: 1") {
		t.Errorf("the file's own shamir_threshold was not preserved:\n%s", out)
	}

	// And the colleague must still be able to read the file afterwards.
	if !strings.Contains(cliDecrypt(t, colleague, edited), "password: rotated") {
		t.Errorf("the second recipient can no longer decrypt the saved file")
	}
}

// Everything the file declares about itself survives, including the settings
// that decide what gets encrypted at all.
func TestSavePreservesMacOnlyEncryptedAndUnencryptedSuffix(t *testing.T) {
	key := newAgeKeyPair(t)
	const src = "kept_unencrypted: visible\nsecret: hidden\n"
	encrypted := encryptWithCLI(t, key, src,
		"--unencrypted-suffix", "_unencrypted",
		"--mac-only-encrypted")

	edited, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"secret"}, Value: "rotated", Kind: KindString}}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	out := string(edited)

	if !strings.Contains(out, "mac_only_encrypted: true") {
		t.Errorf("mac_only_encrypted was not preserved:\n%s", out)
	}
	if !strings.Contains(out, "unencrypted_suffix: _unencrypted") {
		t.Errorf("unencrypted_suffix was not preserved:\n%s", out)
	}
	if !strings.Contains(cliDecrypt(t, key, edited), "secret: rotated") {
		t.Errorf("the edit did not survive a CLI decrypt")
	}
}

// The file records the sops version that wrote it. A save preserves the
// file's own metadata, and that includes this — it is not ours to bump.
func TestSaveDoesNotRewriteTheFilesRecordedVersion(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	wantVersion := ""
	for _, line := range strings.Split(string(encrypted), "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "version:") {
			wantVersion = strings.TrimSpace(line)
		}
	}
	if wantVersion == "" {
		t.Fatalf("fixture has no version line")
	}

	edited, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"api_key"}, Value: "x", Kind: KindString}}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	if !strings.Contains(string(edited), wantVersion) {
		t.Errorf("the file's recorded %q was rewritten by a save", wantVersion)
	}
}

// -----------------------------------------------------------------------
// Types, structure and awkward values
// -----------------------------------------------------------------------

// A port number that comes back as the string "5432" and is written back
// quoted has changed the file. Each kind must survive being edited as itself.
func TestEditingANonStringScalarKeepsItsType(t *testing.T) {
	for _, tc := range []struct {
		name, path, kind, value, wantLine string
	}{
		{"int", "port", KindInt, "6543", "port: 6543"},
		{"float", "ratio", KindFloat, "0.5", "ratio: 0.5"},
		{"bool", "enabled", KindBool, "false", "enabled: false"},
		{"timestamp", "created", KindTimestamp, "2030-12-25T10:00:00Z", "created: 2030-12-25T10:00:00Z"},
		{"quoted numeric string", "quoted_number", KindString, "9999", `quoted_number: "9999"`},
		{"string", "host", KindString, "elsewhere", "host: elsewhere"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			key := newAgeKeyPair(t)
			encrypted := encryptWithCLI(t, key, richPlainYAML)

			edited, err := ApplyEditsAndEncrypt(encrypted,
				[]Edit{{Path: []string{"db", tc.path}, Value: tc.value, Kind: tc.kind}},
				key.Private)
			if err != nil {
				t.Fatalf("ApplyEditsAndEncrypt: %v", err)
			}
			out := cliDecrypt(t, key, edited)
			if !strings.Contains(out, tc.wantLine) {
				t.Errorf("expected %q in the CLI decrypt, got:\n%s", tc.wantLine, out)
			}

			// And the row model agrees on the type afterwards.
			rows, err := DecryptToRows(edited, key.Private)
			if err != nil {
				t.Fatalf("DecryptToRows: %v", err)
			}
			r := rowByPath(t, rows, "db", tc.path)
			if r.Kind != tc.kind {
				t.Errorf("kind after edit = %q, want %q", r.Kind, tc.kind)
			}
			if r.Value != tc.value {
				t.Errorf("value after edit = %q, want %q", r.Value, tc.value)
			}
		})
	}
}

// A null is a value, not an absence: it must be settable and clearable, and
// sops never encrypts one, so an emptied secret is readable in the file. That
// is sops's own behaviour and the editor should not pretend otherwise.
func TestEditingToAndFromNull(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	// A value becomes null.
	cleared, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"db", "password"}, Kind: KindNull}}, key.Private)
	if err != nil {
		t.Fatalf("clearing to null: %v", err)
	}
	if !strings.Contains(cliDecrypt(t, key, cleared), "password: null") {
		t.Errorf("the value was not cleared to null:\n%s", cliDecrypt(t, key, cleared))
	}
	rows, err := DecryptToRows(cleared, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	cell := rowByPath(t, rows, "db", "password")
	if cell.Kind != KindNull || cell.Value != "" {
		t.Errorf("cleared row = %+v, want a null", cell)
	}
	if cell.Encrypted {
		t.Errorf("sops does not encrypt nulls, so the row must not claim it is encrypted")
	}

	// And a null becomes a value again, which is encrypted this time.
	filled, err := ApplyEditsAndEncrypt(cleared,
		[]Edit{{Path: []string{"db", "nothing"}, Value: "now set", Kind: KindString}}, key.Private)
	if err != nil {
		t.Fatalf("setting a null: %v", err)
	}
	if strings.Contains(string(filled), "now set") {
		t.Errorf("the new value was written in plaintext")
	}
	rows, err = DecryptToRows(filled, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	cell = rowByPath(t, rows, "db", "nothing")
	if cell.Kind != KindString || cell.Value != "now set" || !cell.Encrypted {
		t.Errorf("filled row = %+v", cell)
	}
}

// A path is not a flat key. Nested maps and list elements must be reachable,
// and editing one must not disturb its siblings.
func TestEditingThroughNestedMapsAndLists(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	edited, err := ApplyEditsAndEncrypt(encrypted, []Edit{
		{Path: []string{"servers", "1", "ip"}, Value: "10.0.0.99", Kind: KindString},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	out := cliDecrypt(t, key, edited)
	if !strings.Contains(out, "ip: 10.0.0.99") {
		t.Errorf("the nested list edit did not land:\n%s", out)
	}
	if !strings.Contains(out, "ip: 10.0.0.1") {
		t.Errorf("editing servers[1] disturbed servers[0]:\n%s", out)
	}
	if !strings.Contains(out, "name: beta") {
		t.Errorf("editing servers[1].ip disturbed servers[1].name:\n%s", out)
	}
}

// A map key that is a decimal number is not a list index. Resolving the path
// against the tree, rather than guessing from the text, is what keeps these
// apart.
func TestADecimalMapKeyIsNotAListIndex(t *testing.T) {
	key := newAgeKeyPair(t)
	const src = "ports:\n    \"0\": first\n    \"1\": second\nlist:\n    - zeroth\n    - oneth\n"
	encrypted := encryptWithCLI(t, key, src)

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "ports", "0").Value; got != "first" {
		t.Errorf(`ports."0" = %q, want "first"`, got)
	}
	if got := rowByPath(t, rows, "list", "0").Value; got != "zeroth" {
		t.Errorf("list[0] = %q, want %q", got, "zeroth")
	}

	edited, err := ApplyEditsAndEncrypt(encrypted, []Edit{
		{Path: []string{"ports", "1"}, Value: "changed", Kind: KindString},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	out := cliDecrypt(t, key, edited)
	if !strings.Contains(out, `"1": changed`) {
		t.Errorf(`the map key "1" was not the one edited:\n%s`, out)
	}
	if !strings.Contains(out, "- oneth") {
		t.Errorf("list[1] was edited instead of the map key:\n%s", out)
	}
}

// Both sides of an encrypted_regex must be editable, and each must stay on
// its own side afterwards.
func TestEditingBothSidesOfEncryptedRegex(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML,
		"--encrypted-regex", "^(password|api_key)$")

	edited, err := ApplyEditsAndEncrypt(encrypted, []Edit{
		{Path: []string{"db", "password"}, Value: "new-secret-value", Kind: KindString},
		{Path: []string{"db", "host"}, Value: "new-public-host", Kind: KindString},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	out := string(edited)

	if strings.Contains(out, "new-secret-value") {
		t.Errorf("the edited secret was written in plaintext:\n%s", out)
	}
	if !strings.Contains(out, "host: new-public-host") {
		t.Errorf("the edited plaintext-by-rule value was encrypted:\n%s", out)
	}

	rows, err := DecryptToRows(edited, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if !rowByPath(t, rows, "db", "password").Encrypted {
		t.Errorf("the edited secret is no longer encrypted")
	}
	if rowByPath(t, rows, "db", "host").Encrypted {
		t.Errorf("the edited plaintext value became encrypted")
	}
}

// Values a YAML emitter has opinions about: newlines, leading '#', something
// that looks like a bool, trailing whitespace, unicode.
func TestEditingToQuotingHostileAndMultilineValues(t *testing.T) {
	for _, tc := range []struct{ name, value string }{
		{"newlines", "line one\nline two\n"},
		{"leading hash", "#not a comment"},
		{"looks boolean", "true"},
		{"looks null", "null"},
		{"looks numeric", "0755"},
		{"trailing space", "padded "},
		{"colon space", "key: value"},
		{"unicode", "příliš žluťoučký kůň 🐴"},
		{"tab", "a\tb"},
		{"empty", ""},
		{"yaml document marker", "---\nnot: a document\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			key := newAgeKeyPair(t)
			encrypted := encryptWithCLI(t, key, richPlainYAML)

			edited, err := ApplyEditsAndEncrypt(encrypted,
				[]Edit{{Path: []string{"db", "password"}, Value: tc.value, Kind: KindString}},
				key.Private)
			if err != nil {
				t.Fatalf("ApplyEditsAndEncrypt: %v", err)
			}

			// The CLI must accept it, and reading it back must give exactly
			// the string that went in.
			if _, err := runSopsCLIAllowFailDoc(t, key, "--decrypt",
				writeTemp(t, "e.yaml", edited)); err != nil {
				t.Fatalf("the sops CLI could not decrypt the result: %v", err)
			}
			rows, err := DecryptToRows(edited, key.Private)
			if err != nil {
				t.Fatalf("DecryptToRows: %v", err)
			}
			if got := rowByPath(t, rows, "db", "password").Value; got != tc.value {
				t.Errorf("value did not survive: got %q, want %q", got, tc.value)
			}
		})
	}
}

// A file with several YAML documents carries one sops block per document but
// a single set of metadata. Rows have to say which document they came from,
// or an edit lands in the wrong one.
func TestMultiDocumentFilesAddressEachDocumentSeparately(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, "shared: first\n---\nshared: second\n")

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if len(rows) != 2 {
		t.Fatalf("expected 2 rows, got %v", rowPaths(rows))
	}
	if rows[0].Document != 0 || rows[1].Document != 1 {
		t.Errorf("document indices wrong: %+v", rows)
	}
	if rows[0].Value != "first" || rows[1].Value != "second" {
		t.Errorf("values wrong: %+v", rows)
	}

	edited, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Document: 1, Path: []string{"shared"}, Value: "changed", Kind: KindString}},
		key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	out := cliDecrypt(t, key, edited)
	if !strings.Contains(out, "shared: first") {
		t.Errorf("the first document was changed:\n%s", out)
	}
	if !strings.Contains(out, "shared: changed") {
		t.Errorf("the second document was not changed:\n%s", out)
	}
}

// -----------------------------------------------------------------------
// Refusals
// -----------------------------------------------------------------------

func TestEditsAreRefusedRatherThanGuessedAt(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	for name, edit := range map[string]Edit{
		"unknown key":        {Path: []string{"db", "nonexistent"}, Value: "x", Kind: KindString},
		"unknown top level":  {Path: []string{"nope"}, Value: "x", Kind: KindString},
		"through a scalar":   {Path: []string{"db", "host", "deeper"}, Value: "x", Kind: KindString},
		"list index too big": {Path: []string{"servers", "9", "ip"}, Value: "x", Kind: KindString},
		"negative index":     {Path: []string{"servers", "-1", "ip"}, Value: "x", Kind: KindString},
		"empty path":         {Path: nil, Value: "x", Kind: KindString},
		"a whole map":        {Path: []string{"db"}, Value: "x", Kind: KindString},
		"a whole list":       {Path: []string{"servers"}, Value: "x", Kind: KindString},
		"an empty map":       {Path: []string{"empty_map"}, Value: "x", Kind: KindString},
		"unknown document":   {Document: 7, Path: []string{"api_key"}, Value: "x", Kind: KindString},
		"missing kind":       {Path: []string{"db", "host"}, Value: "x"},
		"unknown kind":       {Path: []string{"db", "host"}, Value: "x", Kind: "octopus"},
		"int that is not":    {Path: []string{"db", "port"}, Value: "not a number", Kind: KindInt},
		"bool that is not":   {Path: []string{"db", "enabled"}, Value: "perhaps", Kind: KindBool},
		"float that is not":  {Path: []string{"db", "ratio"}, Value: "nearly", Kind: KindFloat},
		"time that is not":   {Path: []string{"db", "created"}, Value: "yesterday", Kind: KindTimestamp},
	} {
		t.Run(name, func(t *testing.T) {
			out, err := ApplyEditsAndEncrypt(encrypted, []Edit{edit}, key.Private)
			if err == nil {
				t.Fatalf("the edit was accepted; %d bytes written", len(out))
			}
			if out != nil {
				t.Errorf("bytes returned alongside an error")
			}
		})
	}
}

// Two edits for the same row mean the caller lost track of its own state.
// Silently applying one of them is how a save writes a value nobody chose.
func TestDuplicateEditsForOneRowAreRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	_, err := ApplyEditsAndEncrypt(encrypted, []Edit{
		{Path: []string{"db", "host"}, Value: "one", Kind: KindString},
		{Path: []string{"db", "host"}, Value: "two", Kind: KindString},
	}, key.Private)
	if err == nil {
		t.Fatalf("duplicate edits for one path were accepted")
	}
}

// A refusal must be diagnosable — which row failed — without ever naming what
// the user typed into it.
func TestEditErrorsNameThePathAndNeverTheValue(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	const secretish = "hunter2-correct-horse-battery-staple"
	for _, edit := range []Edit{
		{Path: []string{"db", "port"}, Value: secretish, Kind: KindInt},
		{Path: []string{"db", "nonexistent"}, Value: secretish, Kind: KindString},
		{Path: []string{"db"}, Value: secretish, Kind: KindString},
		{Path: []string{"db", "host"}, Value: secretish, Kind: "octopus"},
	} {
		_, err := ApplyEditsAndEncrypt(encrypted, []Edit{edit}, key.Private)
		if err == nil {
			t.Fatalf("expected a refusal for %v", edit.Path)
		}
		if strings.Contains(err.Error(), secretish) {
			t.Errorf("the error carries the value the user typed: %v", err)
		}
		if len(edit.Path) > 0 && !strings.Contains(err.Error(), edit.Path[len(edit.Path)-1]) {
			t.Errorf("the error does not name the key that failed: %v", err)
		}
	}
}

// A wrong identity must fail, and the failure must not leak any of the
// document it could not read.
func TestDocumentAPIWithAnUnrelatedIdentityFails(t *testing.T) {
	owner := newAgeKeyPair(t)
	stranger := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, owner, richPlainYAML)

	if rows, err := DecryptToRows(encrypted, stranger.Private); err == nil {
		t.Fatalf("an unrelated identity produced %d rows", len(rows))
	}
	if _, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"db", "host"}, Value: "x", Kind: KindString}},
		stranger.Private); err == nil {
		t.Fatalf("an unrelated identity produced a saved file")
	}
}

// A tampered document must be rejected, not read past.
func TestDocumentAPIRejectsATamperedMAC(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)
	tampered := strings.Replace(string(encrypted), "port: ENC[", "porx: ENC[", 1)

	if _, err := DecryptToRows([]byte(tampered), key.Private); err == nil {
		t.Fatalf("a tampered document was accepted")
	}
}

func TestDocumentAPIRejectsAPlaintextFile(t *testing.T) {
	key := newAgeKeyPair(t)
	if _, err := DecryptToRows([]byte(richPlainYAML), key.Private); err == nil {
		t.Fatalf("an unencrypted file was accepted as a sops document")
	}
}

// -----------------------------------------------------------------------
// What sops's own stores do and do not preserve
// -----------------------------------------------------------------------

// With no edits at all, a save must reproduce the file it was given, byte for
// byte, apart from the two fields sops rewrites on every encrypt: the
// timestamp and the MAC that is bound to it. This is the strongest available
// statement that we are not quietly reformatting anyone's document.
func TestSavingWithNoEditsRewritesOnlyTheTimestampAndMAC(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML,
		"--encrypted-regex", "^(password|api_key)$")

	out, err := ApplyEditsAndEncrypt(encrypted, nil, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	beforeLines := strings.Split(string(encrypted), "\n")
	afterLines := strings.Split(string(out), "\n")
	if len(beforeLines) != len(afterLines) {
		t.Fatalf("line count changed: %d -> %d\nbefore:\n%s\nafter:\n%s",
			len(beforeLines), len(afterLines), encrypted, out)
	}
	for i := range beforeLines {
		if beforeLines[i] == afterLines[i] {
			continue
		}
		field := strings.TrimSpace(beforeLines[i])
		if strings.HasPrefix(field, "lastmodified:") || strings.HasPrefix(field, "mac:") {
			continue
		}
		t.Errorf("line %d changed and is neither lastmodified nor mac:\n  before: %s\n  after:  %s",
			i+1, beforeLines[i], afterLines[i])
	}
}

// The one thing sops's stores do NOT round-trip, pinned so it cannot change
// silently: an end-of-line comment is re-anchored onto its own line, because
// sops's decrypt path rebuilds a Comment from the cipher's "comment" datatype
// and drops the Inline flag while doing it.
//
// This is not something this bridge introduces. `sops set` — the CLI's own
// edit path, which loads, decrypts, changes a value, re-encrypts and emits,
// exactly as we do — produces the identical move. The assertion below is
// against the CLI, so if upstream ever fixes it, this test tells us rather
// than leaving us silently different from the tool we wrap.
func TestInlineCommentsMoveExactlyAsTheSopsCLIMovesThem(t *testing.T) {
	key := newAgeKeyPair(t)
	const src = "host: localhost\napi_key: sk-live-abc123 # rotate me\n"
	encrypted := encryptWithCLI(t, key, src)

	if !inlineCommentIsOnTheSameLineAs(string(encrypted), "api_key:") {
		t.Fatalf("fixture assumption broken: sops -e did not keep the comment inline:\n%s", encrypted)
	}

	// What the CLI's own edit path does.
	cliEdited := writeTemp(t, "cli.yaml", encrypted)
	runSopsCLI(t, key, nil, "set", cliEdited, `["host"]`, `"elsewhere"`)
	cliOut, err := os.ReadFile(cliEdited)
	if err != nil {
		t.Fatalf("read back: %v", err)
	}

	// What we do.
	ourOut, err := ApplyEditsAndEncrypt(encrypted,
		[]Edit{{Path: []string{"host"}, Value: "elsewhere", Kind: KindString}}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}

	cliInline := inlineCommentIsOnTheSameLineAs(string(cliOut), "api_key:")
	ourInline := inlineCommentIsOnTheSameLineAs(string(ourOut), "api_key:")
	if cliInline != ourInline {
		t.Errorf("this bridge and `sops set` disagree about inline comments: cli=%v ours=%v\n"+
			"cli output:\n%s\nour output:\n%s", cliInline, ourInline, cliOut, ourOut)
	}
	if cliInline {
		t.Logf("upstream now preserves inline comments; the documented caveat can be retired")
	}

	// Whichever way it goes, the comment itself must still be in the file and
	// still decrypt to the same text.
	if !strings.Contains(cliDecrypt(t, key, ourOut), "# rotate me") {
		t.Errorf("the comment was lost entirely")
	}
}

func inlineCommentIsOnTheSameLineAs(doc, prefix string) bool {
	for _, line := range strings.Split(doc, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), prefix) {
			return strings.Contains(line, "#")
		}
	}
	return false
}

// -----------------------------------------------------------------------
// Logging hygiene
// -----------------------------------------------------------------------

// sops's Tree.Decrypt logs the *text of a comment* it could not decrypt, at
// warn level, to stderr. In a GUI that is a secret in a crash report. Every
// sops logger is muted at init.
func TestSopsLoggersAreMuted(t *testing.T) {
	if len(logging.Loggers) == 0 {
		t.Fatalf("no sops loggers registered — this test is not measuring anything")
	}
	for name, l := range logging.Loggers {
		if l.Out != io.Discard {
			t.Errorf("sops logger %q still writes to %v", name, l.Out)
		}
	}
}

// -----------------------------------------------------------------------
// JSON, the shape the C boundary carries
// -----------------------------------------------------------------------

func TestRowsJSONIsAnArrayEvenWhenEmpty(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, "{}\n")

	payload, err := DecryptToRowsJSON(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRowsJSON: %v", err)
	}
	if string(payload) != "[]" {
		t.Errorf("empty row list encoded as %q, want %q", payload, "[]")
	}
}

func TestApplyEditsJSONRoundTrip(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	edits := `[{"path":["db","port"],"value":"6543","kind":"int"}]`
	out, err := ApplyEditsJSON(encrypted, []byte(edits), key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsJSON: %v", err)
	}
	if !strings.Contains(cliDecrypt(t, key, out), "port: 6543") {
		t.Errorf("the edit did not land")
	}

	if _, err := ApplyEditsJSON(encrypted, []byte("not json"), key.Private); err == nil {
		t.Errorf("malformed edit JSON was accepted")
	}
}

// runSopsCLIAllowFailDoc is runSopsCLI without the t.Fatalf, for the cases
// that are checking whether the CLI accepts something at all.
func runSopsCLIAllowFailDoc(t *testing.T, key ageKeyPair, args ...string) ([]byte, error) {
	t.Helper()
	keyFile := filepath.Join(t.TempDir(), "keys.txt")
	if err := os.WriteFile(keyFile, []byte(key.Private+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command("sops", args...)
	cmd.Env = append(os.Environ(), "SOPS_AGE_KEY_FILE="+keyFile)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return out, fmt.Errorf("sops %v: %w: %s", args, err, out)
	}
	return out, nil
}
