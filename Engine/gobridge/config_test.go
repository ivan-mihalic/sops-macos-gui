package gobridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// writeConfig writes a .sops.yaml at dir/.sops.yaml and returns its path.
func writeConfig(t *testing.T, dir string, contents string) string {
	t.Helper()
	path := filepath.Join(dir, ".sops.yaml")
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		t.Fatalf("write .sops.yaml: %v", err)
	}
	return path
}

func sortedCopy(in []string) []string {
	out := append([]string(nil), in...)
	sort.Strings(out)
	return out
}

func TestLookupCreationRule_SingleLineCommaList(t *testing.T) {
	dir := t.TempDir()
	k1, k2 := newAgeKeyPair(t), newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`,`+k2.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Matched {
		t.Fatalf("expected a match")
	}
	want := sortedCopy([]string{k1.Public, k2.Public})
	if have := sortedCopy(got.AgeRecipients); !equalStrings(have, want) {
		t.Errorf("AgeRecipients = %v, want %v", have, want)
	}
	if len(got.NonAgeBackends) != 0 {
		t.Errorf("NonAgeBackends = %v, want none", got.NonAgeBackends)
	}
}

func TestLookupCreationRule_BlockList(t *testing.T) {
	dir := t.TempDir()
	k1, k2 := newAgeKeyPair(t), newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age:
      - `+k1.Public+`
      - `+k2.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := sortedCopy([]string{k1.Public, k2.Public})
	if have := sortedCopy(got.AgeRecipients); !equalStrings(have, want) {
		t.Errorf("AgeRecipients = %v, want %v", have, want)
	}
}

func TestLookupCreationRule_SingleLineFlowList(t *testing.T) {
	dir := t.TempDir()
	k1, k2 := newAgeKeyPair(t), newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: [`+k1.Public+`, `+k2.Public+`]
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := sortedCopy([]string{k1.Public, k2.Public})
	if have := sortedCopy(got.AgeRecipients); !equalStrings(have, want) {
		t.Errorf("AgeRecipients = %v, want %v", have, want)
	}
}

// The exact shape that broke the hand-rolled Swift parser twice: a flow
// sequence split across physical lines.
func TestLookupCreationRule_MultiLineFlowList(t *testing.T) {
	dir := t.TempDir()
	k1, k2, k3 := newAgeKeyPair(t), newAgeKeyPair(t), newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: [`+k1.Public+`,
          `+k2.Public+`,
          `+k3.Public+`]
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	want := sortedCopy([]string{k1.Public, k2.Public, k3.Public})
	if have := sortedCopy(got.AgeRecipients); !equalStrings(have, want) {
		t.Errorf("AgeRecipients = %v, want %v", have, want)
	}
}

func TestLookupCreationRule_CommentsAreIgnored(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `# top-level comment
creation_rules:
  # a comment before a rule
  - path_regex: secrets/.*\.yaml$  # trailing comment
    age: `+k1.Public+` # another comment
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.AgeRecipients) != 1 || got.AgeRecipients[0] != k1.Public {
		t.Errorf("AgeRecipients = %v, want [%s]", got.AgeRecipients, k1.Public)
	}
}

// The shape that produced the second silent-corruption bug in the old
// hand-rolled parser: bracket characters inside quoted path_regex values,
// in two different rules. The old parser tracked square-bracket depth as
// raw characters across the *whole document*, with no notion of "inside a
// quoted string" — so two independent character classes in two different
// rules could arithmetically cancel out and fool its balance check,
// gluing unrelated rules together. A real YAML parser scopes quoted-string
// contents correctly by construction: the brackets below are just text
// inside each rule's own quoted scalar and can never affect any other
// rule, which is what this test proves by checking the *right* rule's key
// comes back, not some hybrid of the two.
func TestLookupCreationRule_QuotedPathRegexWithBracketsInDifferentRules(t *testing.T) {
	dir := t.TempDir()
	k1, k2 := newAgeKeyPair(t), newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: 'unrelated/[a-z]+\.yaml$'
    age: `+k1.Public+`
  - path_regex: 'secrets/[0-9]+\.yaml$'
    age: `+k2.Public+`
`)
	target := filepath.Join(dir, "secrets", "42.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Matched {
		t.Fatalf("expected a match against the second rule")
	}
	if len(got.AgeRecipients) != 1 || got.AgeRecipients[0] != k2.Public {
		t.Errorf("AgeRecipients = %v, want [%s] (the second rule's key, not the first's)", got.AgeRecipients, k2.Public)
	}
}

func TestLookupCreationRule_LaterRuleMatchesWhenEarlierDoesNot(t *testing.T) {
	dir := t.TempDir()
	k1, k2 := newAgeKeyPair(t), newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: nomatch/.*
    age: `+k1.Public+`
  - path_regex: secrets/.*\.yaml$
    age: `+k2.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.AgeRecipients) != 1 || got.AgeRecipients[0] != k2.Public {
		t.Errorf("AgeRecipients = %v, want [%s]", got.AgeRecipients, k2.Public)
	}
}

func TestLookupCreationRule_NoRuleMatches(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: nomatch/.*
    age: `+k1.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("no-match must not be an error, got: %v", err)
	}
	if got.Matched {
		t.Fatalf("expected no match")
	}
}

func TestLookupCreationRule_NoCreationRulesKeyAtAllIsNotAnError(t *testing.T) {
	dir := t.TempDir()
	confPath := writeConfig(t, dir, `stores:
  yaml:
    indent: 4
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("no creation_rules key must not be an error, got: %v", err)
	}
	if got.Matched {
		t.Fatalf("expected no match")
	}
}

func TestLookupCreationRule_MalformedYAMLIsAnError(t *testing.T) {
	dir := t.TempDir()
	confPath := writeConfig(t, dir, "creation_rules:\n  - this: [is: not: valid\n")
	target := filepath.Join(dir, "secrets", "prod.yaml")

	_, err := LookupCreationRule(confPath, target)
	if err == nil {
		t.Fatalf("expected an error for malformed YAML")
	}
}

func TestLookupCreationRule_MissingConfigFileIsAnError(t *testing.T) {
	dir := t.TempDir()
	confPath := filepath.Join(dir, ".sops.yaml") // never written
	target := filepath.Join(dir, "secrets", "prod.yaml")

	_, err := LookupCreationRule(confPath, target)
	if err == nil {
		t.Fatalf("expected an error for a missing config file")
	}
}

func TestLookupCreationRule_PGPOnlyRule(t *testing.T) {
	dir := t.TempDir()
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    pgp: 0000000000000000000000000000000000AAAA
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Matched {
		t.Fatalf("expected a match")
	}
	if len(got.AgeRecipients) != 0 {
		t.Errorf("AgeRecipients = %v, want none", got.AgeRecipients)
	}
	if len(got.NonAgeBackends) != 1 || got.NonAgeBackends[0] != "pgp" {
		t.Errorf("NonAgeBackends = %v, want [pgp]", got.NonAgeBackends)
	}
}

func TestLookupCreationRule_MixedAgeAndKMSRule(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`
    kms: arn:aws:kms:us-east-1:000000000000:key/test
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.AgeRecipients) != 1 || got.AgeRecipients[0] != k1.Public {
		t.Errorf("AgeRecipients = %v, want [%s]", got.AgeRecipients, k1.Public)
	}
	if len(got.NonAgeBackends) != 1 || got.NonAgeBackends[0] != "kms" {
		t.Errorf("NonAgeBackends = %v, want [kms]", got.NonAgeBackends)
	}
}

// A creation rule that scopes encryption to specific keys via
// encrypted_regex must report that regex — Task 5 uses it to refuse
// creating files under rules this app cannot faithfully reproduce.
func TestLookupCreationRule_EncryptedRegexIsReported(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`
    encrypted_regex: '^(data|stringData)$'
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.EncryptedRegex != "^(data|stringData)$" {
		t.Errorf("EncryptedRegex = %q, want %q", got.EncryptedRegex, "^(data|stringData)$")
	}
	if got.UnencryptedRegex != "" {
		t.Errorf("UnencryptedRegex = %q, want empty", got.UnencryptedRegex)
	}
	if got.UnencryptedSuffix != "" {
		t.Errorf("UnencryptedSuffix = %q, want empty", got.UnencryptedSuffix)
	}
	if got.EncryptedSuffix != "" {
		t.Errorf("EncryptedSuffix = %q, want empty", got.EncryptedSuffix)
	}
}

// A rule that scopes encryption via unencrypted_suffix instead must report
// that suffix, with the other three new fields left empty.
func TestLookupCreationRule_UnencryptedSuffixIsReported(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`
    unencrypted_suffix: "_plain"
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.UnencryptedSuffix != "_plain" {
		t.Errorf("UnencryptedSuffix = %q, want %q", got.UnencryptedSuffix, "_plain")
	}
	if got.EncryptedRegex != "" {
		t.Errorf("EncryptedRegex = %q, want empty", got.EncryptedRegex)
	}
	if got.UnencryptedRegex != "" {
		t.Errorf("UnencryptedRegex = %q, want empty", got.UnencryptedRegex)
	}
	if got.EncryptedSuffix != "" {
		t.Errorf("EncryptedSuffix = %q, want empty", got.EncryptedSuffix)
	}
}

// A rule that sets none of the four new fields must report all of them as
// empty strings — the encoding for "this rule does not set this field".
func TestLookupCreationRule_NoScopingFieldsAreEmptyStrings(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.EncryptedRegex != "" || got.UnencryptedRegex != "" || got.UnencryptedSuffix != "" || got.EncryptedSuffix != "" {
		t.Errorf("expected all four scoping fields empty, got: EncryptedRegex=%q UnencryptedRegex=%q UnencryptedSuffix=%q EncryptedSuffix=%q",
			got.EncryptedRegex, got.UnencryptedRegex, got.UnencryptedSuffix, got.EncryptedSuffix)
	}
}

// The JSON that crosses the C boundary must carry the four new fields under
// their camelCase keys so the Swift Decodable struct picks them up.
func TestLookupCreationRuleJSON_ScopingFieldsArePresent(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`
    encrypted_regex: '^(data|stringData)$'
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	raw, err := LookupCreationRuleJSON(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var decoded struct {
		EncryptedRegex    string `json:"encryptedRegex"`
		UnencryptedRegex  string `json:"unencryptedRegex"`
		UnencryptedSuffix string `json:"unencryptedSuffix"`
		EncryptedSuffix   string `json:"encryptedSuffix"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal: %v\nraw: %s", err, raw)
	}
	if decoded.EncryptedRegex != "^(data|stringData)$" {
		t.Errorf("encryptedRegex = %q, want %q", decoded.EncryptedRegex, "^(data|stringData)$")
	}
	if decoded.UnencryptedRegex != "" || decoded.UnencryptedSuffix != "" || decoded.EncryptedSuffix != "" {
		t.Errorf("expected the other three scoping fields empty, got: %+v", decoded)
	}
}

func TestLookupCreationRule_KeyGroups(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - pgp:
          - 0000000000000000000000000000000000AAAA
        age:
          - `+k1.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(got.AgeRecipients) != 1 || got.AgeRecipients[0] != k1.Public {
		t.Errorf("AgeRecipients = %v, want [%s]", got.AgeRecipients, k1.Public)
	}
	if len(got.NonAgeBackends) != 1 || got.NonAgeBackends[0] != "pgp" {
		t.Errorf("NonAgeBackends = %v, want [pgp]", got.NonAgeBackends)
	}
}

// LookupCreationRuleJSON is what actually crosses the C boundary; prove its
// JSON shape decodes into exactly what a Swift Decodable struct expects —
// non-null arrays even when empty, matched/ageRecipients/nonAgeBackends
// keys present.
func TestLookupCreationRuleJSON_ShapeIsStableForSwiftDecoding(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k1.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	raw, err := LookupCreationRuleJSON(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	var decoded struct {
		Matched        bool     `json:"matched"`
		AgeRecipients  []string `json:"ageRecipients"`
		NonAgeBackends []string `json:"nonAgeBackends"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal: %v\nraw: %s", err, raw)
	}
	if !decoded.Matched {
		t.Errorf("Matched = false, want true")
	}
	if decoded.AgeRecipients == nil {
		t.Errorf("AgeRecipients decoded as nil, want a present (possibly empty) array")
	}
	if decoded.NonAgeBackends == nil {
		t.Errorf("NonAgeBackends decoded as nil, want a present (possibly empty) array")
	}
}

func TestLookupCreationRuleJSON_NoMatchStillProducesNonNullArrays(t *testing.T) {
	dir := t.TempDir()
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: nomatch/.*
    age: `+newAgeKeyPair(t).Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")

	raw, err := LookupCreationRuleJSON(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var decoded struct {
		Matched        bool     `json:"matched"`
		AgeRecipients  []string `json:"ageRecipients"`
		NonAgeBackends []string `json:"nonAgeBackends"`
	}
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatalf("json.Unmarshal: %v\nraw: %s", err, raw)
	}
	if decoded.Matched {
		t.Errorf("Matched = true, want false")
	}
	if decoded.AgeRecipients == nil || decoded.NonAgeBackends == nil {
		t.Errorf("arrays must never decode as nil even on no-match: %+v", decoded)
	}
}

func equalStrings(a, b []string) bool {
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

// Sanity: the config path resolution must work with the target file given as
// an absolute path under the config's own directory, which is how
// ProjectHealthCheck will always call this (see gobridge/config.go's doc
// comment on why an absolute target path matters).
func TestLookupCreationRule_TargetMustBeAbsoluteToMatchRelativePathRegex(t *testing.T) {
	dir := t.TempDir()
	k1 := newAgeKeyPair(t)
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: ^secrets/prod\.yaml$
    age: `+k1.Public+`
`)
	target := filepath.Join(dir, "secrets", "prod.yaml")
	if !filepath.IsAbs(target) {
		t.Fatalf("test setup bug: target must be absolute")
	}
	if !strings.HasPrefix(target, dir) {
		t.Fatalf("test setup bug: target must be under dir")
	}

	got, err := LookupCreationRule(confPath, target)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !got.Matched {
		t.Fatalf("expected a match — path_regex is anchored to the path relative to the config file")
	}
}
