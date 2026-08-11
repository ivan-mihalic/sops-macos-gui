package gobridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"go.yaml.in/yaml/v3"
)

// update runs UpdateConfigRecipients against a .sops.yaml written into a fresh
// temp dir, with `target` interpreted relative to that dir.
func update(t *testing.T, config string, target string, recipients []string, candidates ...string) (*ConfigRecipientUpdate, string, error) {
	t.Helper()
	dir := t.TempDir()
	confPath := writeConfig(t, dir, config)
	abs := make([]string, 0, len(candidates))
	for _, c := range candidates {
		abs = append(abs, filepath.Join(dir, c))
	}
	got, err := UpdateConfigRecipients(confPath, filepath.Join(dir, target), recipients, abs)
	return got, dir, err
}

func mustUpdate(t *testing.T, config string, target string, recipients []string, candidates ...string) (*ConfigRecipientUpdate, string) {
	t.Helper()
	got, dir, err := update(t, config, target, recipients, candidates...)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	return got, dir
}

// MARK: - The rule is rewritten and nothing else in the file is

func TestUpdateConfigRecipients_RewritesTheMatchedRuleAndKeepsEverythingElse(t *testing.T) {
	a, b, c := newAgeKeyPair(t), newAgeKeyPair(t), newAgeKeyPair(t)
	config := `# Team configuration — do not commit plaintext
creation_rules:
  # staging only
  - path_regex: staging/.*\.yaml$
    age:
      - ` + c.Public + `
  # production
  - path_regex: prod/.*\.yaml$
    age:
      - ` + a.Public + ` # alice
`
	got, _ := mustUpdate(t, config, "prod/db.yaml", []string{a.Public, b.Public})

	if !got.Writable {
		t.Fatalf("Writable = false, Reason = %q", got.Reason)
	}
	if !got.Changed {
		t.Fatalf("Changed = false; the rule's age list did change")
	}
	if !equalStrings(got.CurrentRecipients, []string{a.Public}) {
		t.Errorf("CurrentRecipients = %v, want [%s]", got.CurrentRecipients, a.Public)
	}

	// Every comment survives, the unrelated staging rule survives untouched,
	// and the new recipient is in the production rule.
	for _, want := range []string{
		"# Team configuration — do not commit plaintext",
		"# staging only",
		"# production",
		"# alice",
		"staging/.*\\.yaml$",
		c.Public,
		b.Public,
	} {
		if !strings.Contains(got.Config, want) {
			t.Errorf("emitted config is missing %q:\n%s", want, got.Config)
		}
	}

	// And the emitted config really does resolve, through sops's own parser,
	// to exactly the requested set for that file.
	dir := t.TempDir()
	confPath := writeConfig(t, dir, got.Config)
	lookup, err := LookupCreationRule(confPath, filepath.Join(dir, "prod", "db.yaml"))
	if err != nil {
		t.Fatalf("re-reading the emitted config: %v", err)
	}
	if !equalStrings(sortedCopy(lookup.AgeRecipients), sortedCopy([]string{a.Public, b.Public})) {
		t.Errorf("emitted config resolves to %v, want %v", lookup.AgeRecipients, []string{a.Public, b.Public})
	}

	// The staging rule is still governed by its own key, unchanged.
	staging, err := LookupCreationRule(confPath, filepath.Join(dir, "staging", "db.yaml"))
	if err != nil {
		t.Fatalf("re-reading the emitted config for staging: %v", err)
	}
	if !equalStrings(staging.AgeRecipients, []string{c.Public}) {
		t.Errorf("staging rule now resolves to %v, want [%s]", staging.AgeRecipients, c.Public)
	}
}

func TestUpdateConfigRecipients_UnchangedWhenTheSetAlreadyMatches(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: .*\.yaml$
    age:
      - ` + a.Public + `
      - ` + b.Public + `
`
	// Same set, different order: still nothing to write.
	got, _ := mustUpdate(t, config, "db.yaml", []string{b.Public, a.Public})
	if !got.Writable {
		t.Fatalf("Writable = false, Reason = %q", got.Reason)
	}
	if got.Changed {
		t.Errorf("Changed = true for a set that already matches; Config:\n%s", got.Config)
	}
	if got.Config != config {
		t.Errorf("Config was rewritten for a no-op change:\n%s", got.Config)
	}
}

func TestUpdateConfigRecipients_MatchedFilesAreTheOnesTheSameRuleGoverns(t *testing.T) {
	a := newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: prod/.*\.yaml$
    age: ` + a.Public + `
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	got, dir := mustUpdate(t, config, "prod/db.yaml", []string{a.Public},
		"prod/db.yaml", "prod/api.yaml", "staging/db.yaml", "notes.txt")

	want := []string{filepath.Join(dir, "prod/db.yaml"), filepath.Join(dir, "prod/api.yaml")}
	if !equalStrings(got.MatchedFiles, want) {
		t.Errorf("MatchedFiles = %v, want %v", got.MatchedFiles, want)
	}
	if got.RuleIndex != 0 {
		t.Errorf("RuleIndex = %d, want 0", got.RuleIndex)
	}
}

// A scalar `age:` with one recipient stays a scalar; growing past one becomes
// a block list rather than a comma-joined line nobody can read.
func TestUpdateConfigRecipients_ScalarStaysScalarForOneRecipient(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	got, _ := mustUpdate(t, config, "db.yaml", []string{b.Public})
	if !got.Writable || !got.Changed {
		t.Fatalf("Writable=%v Changed=%v Reason=%q", got.Writable, got.Changed, got.Reason)
	}
	if !strings.Contains(got.Config, "age: "+b.Public) {
		t.Errorf("a one-recipient scalar should stay a scalar:\n%s", got.Config)
	}
}

func TestUpdateConfigRecipients_FlowSequenceStaysFlow(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: .*\.yaml$
    age: [` + a.Public + `]
`
	got, _ := mustUpdate(t, config, "db.yaml", []string{a.Public, b.Public})
	if !got.Writable {
		t.Fatalf("Reason = %q", got.Reason)
	}
	if !strings.Contains(got.Config, "age: ["+a.Public+", "+b.Public+"]") {
		t.Errorf("a flow list should stay a flow list:\n%s", got.Config)
	}
}

// A rule with a path_regex and no keys at all is still a flat, age-only rule —
// vacuously — so it can gain an `age:` key.
func TestUpdateConfigRecipients_AddsAgeToARuleThatHasNone(t *testing.T) {
	a := newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: .*\.yaml$
    encrypted_regex: ^(data|stringData)$
`
	got, _ := mustUpdate(t, config, "db.yaml", []string{a.Public})
	if !got.Writable {
		t.Fatalf("Reason = %q", got.Reason)
	}
	if !strings.Contains(got.Config, a.Public) || !strings.Contains(got.Config, "encrypted_regex") {
		t.Errorf("expected the age key added beside the existing settings:\n%s", got.Config)
	}
}

func TestUpdateConfigRecipients_CRLFConfigStaysCRLF(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	config := strings.ReplaceAll(`creation_rules:
  - path_regex: .*\.yaml$
    age: `+a.Public+`
`, "\n", "\r\n")
	got, _ := mustUpdate(t, config, "db.yaml", []string{b.Public})
	if !got.Writable {
		t.Fatalf("Reason = %q", got.Reason)
	}
	if strings.Contains(strings.ReplaceAll(got.Config, "\r\n", ""), "\n") {
		t.Errorf("a CRLF config must come back CRLF throughout: %q", got.Config)
	}
}

// MARK: - Shapes this app refuses to rewrite

func refusal(t *testing.T, config string, target string) string {
	t.Helper()
	a := newAgeKeyPair(t)
	got, _, err := update(t, config, target, []string{a.Public})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Writable {
		t.Fatalf("Writable = true for a shape this app must refuse; Config:\n%s", got.Config)
	}
	if got.Config != "" {
		t.Errorf("a refusal must carry no config text, got:\n%s", got.Config)
	}
	if strings.TrimSpace(got.Reason) == "" {
		t.Fatalf("a refusal must carry an explanation")
	}
	return got.Reason
}

func TestUpdateConfigRecipients_RefusesKeyGroups(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, `creation_rules:
  - path_regex: .*\.yaml$
    key_groups:
      - age:
          - `+a.Public+`
`, "db.yaml")
	if !strings.Contains(r, "key_groups") {
		t.Errorf("the reason must name the shape it found, got %q", r)
	}
}

func TestUpdateConfigRecipients_RefusesAMixedBackendRule(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, `creation_rules:
  - path_regex: .*\.yaml$
    age: `+a.Public+`
    pgp: 0000000000000000000000000000000000AAAA
`, "db.yaml")
	if !strings.Contains(r, "pgp") {
		t.Errorf("the reason must name the other backend, got %q", r)
	}
}

func TestUpdateConfigRecipients_RefusesShamirThreshold(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	r := refusal(t, `creation_rules:
  - path_regex: .*\.yaml$
    shamir_threshold: 2
    key_groups:
      - age:
          - `+a.Public+`
      - age:
          - `+b.Public+`
`, "db.yaml")
	if !strings.Contains(r, "shamir_threshold") && !strings.Contains(r, "key_groups") {
		t.Errorf("the reason must name the shape it found, got %q", r)
	}
}

func TestUpdateConfigRecipients_RefusesAnchorsInTheMatchedRule(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, `shared: &team
  - `+a.Public+`
creation_rules:
  - path_regex: .*\.yaml$
    age: *team
`, "db.yaml")
	if !strings.Contains(strings.ToLower(r), "anchor") && !strings.Contains(strings.ToLower(r), "alias") {
		t.Errorf("the reason must name the anchor/alias, got %q", r)
	}
}

func TestUpdateConfigRecipients_RefusesMergeKeys(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, `defaults: &d
  age: `+a.Public+`
creation_rules:
  - path_regex: .*\.yaml$
    <<: *d
`, "db.yaml")
	if !strings.Contains(r, "<<") && !strings.Contains(strings.ToLower(r), "merge") {
		t.Errorf("the reason must name the merge key, got %q", r)
	}
}

func TestUpdateConfigRecipients_RefusesAMultiDocumentConfig(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, `creation_rules:
  - path_regex: .*\.yaml$
    age: `+a.Public+`
---
unrelated: true
`, "db.yaml")
	if !strings.Contains(strings.ToLower(r), "document") {
		t.Errorf("the reason must say the file holds more than one document, got %q", r)
	}
}

func TestUpdateConfigRecipients_RefusesMixedLineEndings(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, "creation_rules:\r\n  - path_regex: .*\\.yaml$\n    age: "+a.Public+"\r\n", "db.yaml")
	if !strings.Contains(strings.ToLower(r), "line ending") {
		t.Errorf("the reason must name the line endings, got %q", r)
	}
}

func TestUpdateConfigRecipients_ReportsNoMatchingRule(t *testing.T) {
	a := newAgeKeyPair(t)
	got, _, err := update(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+a.Public+`
`, "elsewhere/db.yaml", []string{a.Public})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Writable {
		t.Fatalf("Writable = true for a file no rule governs")
	}
	if got.RuleIndex != -1 {
		t.Errorf("RuleIndex = %d, want -1", got.RuleIndex)
	}
	if !strings.Contains(got.Reason, "creation rule") {
		t.Errorf("Reason = %q", got.Reason)
	}
}

// MARK: - Errors, as opposed to refusals

func TestUpdateConfigRecipients_MalformedConfigIsAnError(t *testing.T) {
	a := newAgeKeyPair(t)
	if _, _, err := update(t, "creation_rules:\n  - [unclosed\n", "db.yaml", []string{a.Public}); err == nil {
		t.Fatal("expected an error for a config that is not valid YAML")
	}
}

func TestUpdateConfigRecipients_MissingConfigIsAnError(t *testing.T) {
	a := newAgeKeyPair(t)
	dir := t.TempDir()
	if _, err := UpdateConfigRecipients(
		filepath.Join(dir, ".sops.yaml"), filepath.Join(dir, "db.yaml"), []string{a.Public}, nil); err == nil {
		t.Fatal("expected an error for a config that does not exist")
	}
}

// The recipient guards Task 1 established hold here too, and the messages
// never carry the value that was rejected.
func TestUpdateConfigRecipients_RefusesInvalidRecipients(t *testing.T) {
	a := newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	// An *empty* list is not in this table: it is the inspect call, covered by
	// TestUpdateConfigRecipients_EmptyRecipientListInspectsWithoutProposing.
	// What must still be an error is a list holding something that is not a
	// native age public key, including a blank entry.
	cases := map[string]string{
		"blank":   "   ",
		"private": a.Private,
		"garbage": "not-an-age-key",
	}
	for name, recipient := range cases {
		_, _, err := update(t, config, "db.yaml", []string{recipient})
		if err == nil {
			t.Errorf("%s: expected an error", name)
			continue
		}
		if strings.TrimSpace(recipient) != "" && strings.Contains(err.Error(), recipient) {
			t.Errorf("%s: the error quoted the rejected value", name)
		}
	}
}

// MARK: - Nothing is written

func TestUpdateConfigRecipients_NeverTouchesTheConfigOnDisk(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	dir := t.TempDir()
	config := `creation_rules:
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	confPath := writeConfig(t, dir, config)
	before, err := os.ReadFile(confPath)
	if err != nil {
		t.Fatal(err)
	}

	got, err := UpdateConfigRecipients(confPath, filepath.Join(dir, "db.yaml"), []string{a.Public, b.Public}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !got.Changed {
		t.Fatal("expected a change to be proposed")
	}

	after, err := os.ReadFile(confPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(before) != string(after) {
		t.Errorf(".sops.yaml changed on disk; this call must only ever compute text:\n%s", after)
	}
	// The directory has nothing staged in it either.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 {
		names := []string{}
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("the config's directory gained entries: %v", names)
	}
}

// MARK: - The C boundary

func TestUpdateConfigRecipientsJSON_RoundTrips(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	dir := t.TempDir()
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: .*\.yaml$
    age: `+a.Public+`
`)
	recipients, err := json.Marshal([]string{a.Public, b.Public})
	if err != nil {
		t.Fatal(err)
	}
	candidates, err := json.Marshal([]string{filepath.Join(dir, "db.yaml")})
	if err != nil {
		t.Fatal(err)
	}

	payload, err := UpdateConfigRecipientsJSON(confPath, filepath.Join(dir, "db.yaml"), recipients, candidates)
	if err != nil {
		t.Fatal(err)
	}
	var got ConfigRecipientUpdate
	if err := json.Unmarshal(payload, &got); err != nil {
		t.Fatalf("payload is not a ConfigRecipientUpdate: %v", err)
	}
	if !got.Writable || !got.Changed {
		t.Errorf("Writable=%v Changed=%v Reason=%q", got.Writable, got.Changed, got.Reason)
	}
	// Marshalled as [] and never null, so Swift's Decodable for [String]
	// accepts it — the same guarantee CreationRuleLookup makes.
	if !strings.Contains(string(payload), `"matchedFiles":[`) {
		t.Errorf("matchedFiles must marshal as an array: %s", payload)
	}
}

// MARK: - Inspecting without proposing

// An empty recipient list is the inspect call: everything except the text.
// A panel has to be able to show what a config declares, and whether it could
// be rewritten at all, before the user has staged anything.
func TestUpdateConfigRecipients_EmptyRecipientListInspectsWithoutProposing(t *testing.T) {
	a := newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: prod/.*\.yaml$
    age: ` + a.Public + `
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	got, dir := mustUpdate(t, config, "prod/db.yaml", nil, "prod/db.yaml", "staging/db.yaml")

	if !got.Writable {
		t.Fatalf("Writable = false, Reason = %q", got.Reason)
	}
	if got.Changed {
		t.Errorf("Changed = true for an inspection")
	}
	if got.Config != "" {
		t.Errorf("an inspection must propose no text, got:\n%s", got.Config)
	}
	if !equalStrings(got.CurrentRecipients, []string{a.Public}) {
		t.Errorf("CurrentRecipients = %v", got.CurrentRecipients)
	}
	if !equalStrings(got.MatchedFiles, []string{filepath.Join(dir, "prod/db.yaml")}) {
		t.Errorf("MatchedFiles = %v", got.MatchedFiles)
	}
	if got.RuleIndex != 0 {
		t.Errorf("RuleIndex = %d, want 0", got.RuleIndex)
	}
}

func TestUpdateConfigRecipients_InspectionStillRefusesAnUnsupportedShape(t *testing.T) {
	a := newAgeKeyPair(t)
	got, _, err := update(t, `creation_rules:
  - path_regex: .*\.yaml$
    key_groups:
      - age:
          - `+a.Public+`
`, "db.yaml", nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if got.Writable {
		t.Fatal("an inspection must still report an unsupported shape as unwritable")
	}
	if !strings.Contains(got.Reason, "key_groups") {
		t.Errorf("Reason = %q", got.Reason)
	}
}

// MARK: - Fix round 1: shapes and guarantees that had no test

// I2. `creation_rules` present but not a list of rules. Before the fix this
// never reached reasonCreationRulesNotAList at all: the narrow struct decode
// ran first and failed, so the user got `cannot unmarshal !!map into
// []gobridge.writeCreationRule` — this package's own Go type name — as a red
// "could not be read" error rather than the orange "will not be rewritten"
// sentence the shape table promises.
func TestUpdateConfigRecipients_RefusesCreationRulesThatAreNotAList(t *testing.T) {
	a := newAgeKeyPair(t)
	for name, config := range map[string]string{
		"a mapping":         "creation_rules:\n  foo: bar\n",
		"a scalar":          "creation_rules: nonsense\n",
		"a list of scalars": "creation_rules:\n  - nonsense\n",
	} {
		got, _, err := update(t, config, "db.yaml", []string{a.Public})
		if err != nil {
			t.Errorf("%s: expected a refusal, got the error %v", name, err)
			continue
		}
		if got.Writable {
			t.Errorf("%s: Writable = true", name)
			continue
		}
		if got.Reason != reasonCreationRulesNotAList {
			t.Errorf("%s: Reason = %q, want the not-a-list sentence", name, got.Reason)
		}
	}
}

// No error this entry point can produce may name one of this package's own Go
// types: it is read out loud to a user who has never heard of gobridge.
func TestUpdateConfigRecipients_ErrorsNeverNameThisPackagesTypes(t *testing.T) {
	a := newAgeKeyPair(t)
	for name, config := range map[string]string{
		"not a list":          "creation_rules:\n  foo: bar\n",
		"rule is not a map":   "creation_rules:\n  - nonsense\n",
		"path_regex is a map": "creation_rules:\n  - path_regex:\n      a: b\n",
	} {
		got, _, err := update(t, config, "db.yaml", []string{a.Public})
		text := ""
		if err != nil {
			text = err.Error()
		} else {
			text = got.Reason
		}
		if strings.Contains(text, "gobridge") || strings.Contains(text, "writeCreationRule") {
			t.Errorf("%s: user-facing text names this package's own types: %q", name, text)
		}
	}
}

// M2. shamir_threshold on a rule that has *no* key_groups. The existing shamir
// test supplied key_groups as well, and the key_groups check runs first, so
// reasonShamir was documented but never exercised.
func TestUpdateConfigRecipients_RefusesShamirThresholdWithoutKeyGroups(t *testing.T) {
	a := newAgeKeyPair(t)
	r := refusal(t, `creation_rules:
  - path_regex: .*\.yaml$
    shamir_threshold: 2
    age: `+a.Public+`
`, "db.yaml")
	if r != reasonShamir {
		t.Errorf("Reason = %q, want the shamir sentence", r)
	}
}

// M2. A config with other top-level keys but no creation_rules at all.
func TestUpdateConfigRecipients_RefusesAConfigWithNoCreationRules(t *testing.T) {
	r := refusal(t, `stores:
  yaml:
    indent: 2
`, "db.yaml")
	if r != reasonNoCreationRules {
		t.Errorf("Reason = %q, want the no-creation_rules sentence", r)
	}
}

// I4 + M2. A rewrite must leave the whole rest of the file byte for byte as it
// was — not "contains the same substrings". Written as an exact expected
// document so a reordering, a re-indentation or a moved comment fails it.
func TestUpdateConfigRecipients_RewriteIsByteForByteExceptTheAgeList(t *testing.T) {
	a, b, c := newAgeKeyPair(t), newAgeKeyPair(t), newAgeKeyPair(t)
	config := `# Team configuration — do not commit plaintext
stores:
  yaml:
    indent: 2
creation_rules:
  # staging only
  - path_regex: staging/.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age:
      - ` + c.Public + ` # carol
  # production
  - path_regex: prod/.*\.yaml$
    age:
      - ` + a.Public + ` # alice
destination_rules:
  - path_regex: published/.*
    s3_bucket: releases
`
	want := `# Team configuration — do not commit plaintext
stores:
  yaml:
    indent: 2
creation_rules:
  # staging only
  - path_regex: staging/.*\.yaml$
    encrypted_regex: ^(data|stringData)$
    age:
      - ` + c.Public + ` # carol
  # production
  - path_regex: prod/.*\.yaml$
    age:
      - ` + a.Public + ` # alice
      - ` + b.Public + `
destination_rules:
  - path_regex: published/.*
    s3_bucket: releases
`
	got, _ := mustUpdate(t, config, "prod/db.yaml", []string{a.Public, b.Public})
	if !got.Writable || !got.Changed {
		t.Fatalf("Writable=%v Changed=%v Reason=%q", got.Writable, got.Changed, got.Reason)
	}
	if got.Config != want {
		t.Errorf("emitted config is not byte-for-byte what was expected.\n--- got ---\n%s\n--- want ---\n%s", got.Config, want)
	}
}

// I3/M1. A scalar `age: age1… # alice` grown to two recipients used to drop
// `# alice` silently: newAgeNode copied LineComment only when the existing node
// was already a sequence.
func TestUpdateConfigRecipients_AScalarsTrailingCommentSurvivesGrowingTheList(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	got, _ := mustUpdate(t, `creation_rules:
  - path_regex: .*\.yaml$
    age: `+a.Public+` # alice
`, "db.yaml", []string{a.Public, b.Public})

	want := `creation_rules:
  - path_regex: .*\.yaml$
    age:
      - ` + a.Public + ` # alice
      - ` + b.Public + `
`
	if got.Config != want {
		t.Errorf("the scalar's own trailing comment did not travel with its recipient.\n--- got ---\n%s\n--- want ---\n%s", got.Config, want)
	}
}

// ...and when the recipient it belonged to is the one being removed, the
// comment goes with it. That is the right answer, not a loss.
func TestUpdateConfigRecipients_ACommentGoesWithTheRecipientItLabels(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	got, _ := mustUpdate(t, `creation_rules:
  - path_regex: .*\.yaml$
    age: `+a.Public+` # alice
`, "db.yaml", []string{b.Public})
	if strings.Contains(got.Config, "alice") {
		t.Errorf("alice's comment outlived alice's key:\n%s", got.Config)
	}
}

// MARK: - The two defensive nets
//
// Neither reasonRuleDisagreement nor reasonRewriteChangedSomethingElse can be
// reached by any .sops.yaml: every shape that could make the two readings
// differ is caught by an earlier check or by sops's own loader first (probed
// directly — a duplicated age key, a non-list creation_rules, a mapping-valued
// path_regex and an int-valued age all fail earlier). That is the point of a
// net, and it is also why the predicates behind them are tested here directly
// rather than through a fixture that cannot exist.

func TestReadingsDisagree_DetectsEachWayTheTwoReadingsCanDiffer(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	source := `creation_rules:
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	var root yaml.Node
	if err := yaml.Unmarshal([]byte(source), &root); err != nil {
		t.Fatal(err)
	}
	var decoded writeConfigFile
	if err := yaml.Unmarshal([]byte(source), &decoded); err != nil {
		t.Fatal(err)
	}
	document := documentMapping(&root)
	rulesNode := mappingValue(document, "creation_rules")
	agreeing := &CreationRuleLookup{Matched: true, AgeRecipients: []string{a.Public}}

	if readingsDisagree(rulesNode, decoded.CreationRules, 0, agreeing) {
		t.Fatal("the two readings of an ordinary config must agree")
	}

	// sops did not match a rule this reading did.
	if !readingsDisagree(rulesNode, decoded.CreationRules, 0, &CreationRuleLookup{Matched: false}) {
		t.Error("an unmatched sops lookup must count as a disagreement")
	}
	// sops resolved a different key list than the rule declares.
	if !readingsDisagree(rulesNode, decoded.CreationRules, 0,
		&CreationRuleLookup{Matched: true, AgeRecipients: []string{b.Public}}) {
		t.Error("a different resolved key list must count as a disagreement")
	}
	// The node list and the decoded list are not the same list.
	if !readingsDisagree(rulesNode, append(decoded.CreationRules, writeCreationRule{}), 0, agreeing) {
		t.Error("a length mismatch between the two readings must count as a disagreement")
	}
	// The rule about to be edited is not the rule sops selected.
	shifted := append([]writeCreationRule(nil), decoded.CreationRules...)
	shifted[0].PathRegex = "something-else"
	if !readingsDisagree(rulesNode, shifted, 0, agreeing) {
		t.Error("a path_regex that reads differently in the two readings must count as a disagreement")
	}
	// The rule's own age field is a shape neither reading can make sense of.
	unreadable := append([]writeCreationRule(nil), decoded.CreationRules...)
	unreadable[0].Age = 42
	if !readingsDisagree(rulesNode, unreadable, 0, &CreationRuleLookup{Matched: true}) {
		t.Error("an unreadable age field must count as a disagreement")
	}
	// An index outside the list.
	if !readingsDisagree(rulesNode, decoded.CreationRules, 7, agreeing) {
		t.Error("an out-of-range rule index must count as a disagreement")
	}
}

func TestOnlyTheAgeListChanged_RejectsAnyChangeOutsideTheRulesAgeList(t *testing.T) {
	a, b := newAgeKeyPair(t), newAgeKeyPair(t)
	before := `stores:
  yaml:
    indent: 2
creation_rules:
  - path_regex: staging/.*\.yaml$
    age: ` + a.Public + `
  - path_regex: .*\.yaml$
    age: ` + a.Public + `
`
	var decoded writeConfigFile
	if err := yaml.Unmarshal([]byte(before), &decoded); err != nil {
		t.Fatal(err)
	}

	good := strings.Replace(before,
		"  - path_regex: .*\\.yaml$\n    age: "+a.Public,
		"  - path_regex: .*\\.yaml$\n    age: "+b.Public, 1)
	if !onlyTheAgeListChanged([]byte(before), good, decoded, 1, []string{b.Public}) {
		t.Error("a rewrite that touched only the selected rule's age list must pass")
	}

	for name, mangled := range map[string]string{
		"an unrelated rule's keys changed":    strings.Replace(before, "staging/.*\\.yaml$\n    age: "+a.Public, "staging/.*\\.yaml$\n    age: "+b.Public, 1),
		"an unrelated rule's regex changed":   strings.Replace(before, "staging/", "stagingX/", 1),
		"a rule disappeared":                  strings.Replace(before, "  - path_regex: staging/.*\\.yaml$\n    age: "+a.Public+"\n", "", 1),
		"an unrelated top-level key changed":  strings.Replace(before, "indent: 2", "indent: 4", 1),
		"an unrelated top-level key vanished": strings.Replace(before, "stores:\n  yaml:\n    indent: 2\n", "", 1),
		"a top-level key appeared":            "destination_rules: []\n" + before,
		"the selected rule kept its old keys": before,
		"the emitted text is not valid YAML":  "creation_rules: [\n",
	} {
		if onlyTheAgeListChanged([]byte(before), mangled, decoded, 1, []string{b.Public}) {
			t.Errorf("%s: the verification passed a rewrite it must refuse", name)
		}
	}
}

// MARK: - Disclosing what the fallback scope quietly includes

// I2. When no rule governs the target file the caller's scope falls back to
// every encrypted file it found — including files other creation rules govern,
// whose key sets this call was never asked about. MatchedFiles is empty in
// exactly this case, so it cannot carry that disclosure; without
// FilesGovernedByOtherRules the panel re-wrapped them and said nothing.
func TestUpdateConfigRecipients_NoMatchingRuleNamesTheFilesOtherRulesGovern(t *testing.T) {
	a := newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: ^prod/.*\.yaml$
    age: ` + a.Public + `
`
	got, dir := mustUpdate(t, config, "dev/local.yaml", []string{a.Public},
		"dev/local.yaml", "prod/db.yaml", "prod/api.yaml")

	if got.Writable {
		t.Fatalf("Writable = true for a config whose rules govern nothing here")
	}
	if got.RuleIndex != -1 {
		t.Errorf("RuleIndex = %d, want -1", got.RuleIndex)
	}
	if len(got.MatchedFiles) != 0 {
		t.Errorf("MatchedFiles = %v, want empty", got.MatchedFiles)
	}
	want := []string{filepath.Join(dir, "prod/db.yaml"), filepath.Join(dir, "prod/api.yaml")}
	if !equalStrings(got.FilesGovernedByOtherRules, want) {
		t.Errorf("FilesGovernedByOtherRules = %v, want %v", got.FilesGovernedByOtherRules, want)
	}
}

// The complement of MatchedFiles, never overlapping it, and never naming a
// file no rule governs at all — "a different rule decides this file's keys" is
// the disclosure, and "nothing decides them" is not that.
func TestUpdateConfigRecipients_FilesGovernedByOtherRulesExcludesTheSelectedRule(t *testing.T) {
	a := newAgeKeyPair(t)
	config := `creation_rules:
  - path_regex: ^prod/.*\.yaml$
    age: ` + a.Public + `
  - path_regex: ^staging/.*\.yaml$
    age: ` + a.Public + `
`
	got, dir := mustUpdate(t, config, "prod/db.yaml", []string{a.Public},
		"prod/db.yaml", "staging/db.yaml", "dev/local.yaml")

	if !got.Writable {
		t.Fatalf("Writable = false, Reason = %q", got.Reason)
	}
	if !equalStrings(got.MatchedFiles, []string{filepath.Join(dir, "prod/db.yaml")}) {
		t.Errorf("MatchedFiles = %v", got.MatchedFiles)
	}
	if !equalStrings(got.FilesGovernedByOtherRules, []string{filepath.Join(dir, "staging/db.yaml")}) {
		t.Errorf("FilesGovernedByOtherRules = %v, want just the staging file", got.FilesGovernedByOtherRules)
	}
}

// A config with no usable rules governs nothing, so there is nothing to
// disclose — and the field still has to marshal as [] rather than null, or
// Swift's non-optional [String] refuses the whole payload.
func TestUpdateConfigRecipients_FilesGovernedByOtherRulesIsAlwaysAnArray(t *testing.T) {
	a := newAgeKeyPair(t)
	dir := t.TempDir()
	confPath := writeConfig(t, dir, `creation_rules:
  - path_regex: ^prod/.*\.yaml$
    age: `+a.Public+`
`)
	recipients, err := json.Marshal([]string{a.Public})
	if err != nil {
		t.Fatal(err)
	}
	candidates, err := json.Marshal([]string{filepath.Join(dir, "dev/local.yaml")})
	if err != nil {
		t.Fatal(err)
	}

	payload, err := UpdateConfigRecipientsJSON(confPath, filepath.Join(dir, "dev/local.yaml"), recipients, candidates)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payload), `"filesGovernedByOtherRules":[`) {
		t.Errorf("filesGovernedByOtherRules must marshal as an array: %s", payload)
	}
}
