package gobridge

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
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
