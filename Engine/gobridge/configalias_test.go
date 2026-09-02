package gobridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeAliasConfig(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	conf := filepath.Join(dir, ".sops.yaml")
	if err := os.WriteFile(conf, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return conf
}

func TestAddAliasRecipientAppendsToFirstAgeSequenceAndKeepsComments(t *testing.T) {
	conf := writeAliasConfig(t, "# header\nkeys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  # rule comment\n  - path_regex: x$\n    key_groups:\n      - age: [*a]\n")

	out, err := AddAliasRecipient(conf, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"# header", "# rule comment", "*a", "*b"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in:\n%s", want, out)
		}
	}
	if _, err := AddAliasRecipient(conf, 0, "zzz"); err == nil {
		t.Fatal("unknown anchor must fail")
	}
	if _, err := AddAliasRecipient(conf, 0, "a"); err == nil {
		t.Fatal("duplicate alias must fail")
	}
	if _, err := AddAliasRecipient(conf, 5, "b"); err == nil {
		t.Fatal("rule index out of range must fail")
	}
	if _, err := AddAliasRecipient(conf, -1, "b"); err == nil {
		t.Fatal("negative rule index must fail")
	}
}

// The emitted text has to be readable by the very inspection the Access page
// renders — an alias the page cannot then see is not an addition.
func TestAddAliasRecipientOutputReparsesWithTheNewName(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &studio age1aaa\n  - &vps age1bbb\ncreation_rules:\n  - path_regex: x$\n    age:\n      - *studio\n")

	out, err := AddAliasRecipient(conf, 0, "vps")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(conf, []byte(out), 0o600); err != nil {
		t.Fatal(err)
	}
	rules, err := InspectConfigRules(conf, nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, r := range rules.Rules[0].Recipients {
		names = append(names, r.Name)
	}
	if len(names) != 2 || names[0] != "studio" || names[1] != "vps" {
		t.Fatalf("got %v, want [studio vps]\n%s", names, out)
	}
}

func TestAddAliasRecipientConvertsScalarAgeAndAddsMissingAge(t *testing.T) {
	scalar := writeAliasConfig(t, "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    age: age1aaa,age1ccc\n")
	out, err := AddAliasRecipient(scalar, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "*b") || !strings.Contains(out, "age1ccc") {
		t.Fatalf("scalar age was not converted intact:\n%s", out)
	}
	if err := os.WriteFile(scalar, []byte(out), 0o600); err != nil {
		t.Fatal(err)
	}
	rules, err := InspectConfigRules(scalar, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got := len(rules.Rules[0].Recipients); got != 3 {
		t.Fatalf("got %d recipients, want 3:\n%s", got, out)
	}

	none := writeAliasConfig(t, "keys:\n  - &a age1aaa\ncreation_rules:\n  - path_regex: x$\n    pgp: DEADBEEF\n")
	out, err = AddAliasRecipient(none, 0, "a")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "age:") || !strings.Contains(out, "*a") {
		t.Fatalf("a rule without age: did not get one:\n%s", out)
	}
}

// Several key groups mean several possible destinations, and picking one is
// a guess about who may read what. Refused rather than guessed.
func TestAddAliasRecipientRefusesSeveralKeyGroups(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    key_groups:\n      - age: [*a]\n      - age: [*b]\n")
	_, err := AddAliasRecipient(conf, 0, "b")
	if err == nil {
		t.Fatal("a rule with more than one key group must be refused")
	}
	if !strings.Contains(err.Error(), "key group") {
		t.Fatalf("refusal does not say why: %v", err)
	}
}

func TestAddAliasRecipientKeepsTheFilesIndentAndLineEndings(t *testing.T) {
	four := writeAliasConfig(t, "keys:\n    - &a age1aaa\n    - &b age1bbb\ncreation_rules:\n    - path_regex: x$\n      age:\n          - *a\n")
	out, err := AddAliasRecipient(four, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "\n    - path_regex") {
		t.Fatalf("four-space config came back re-indented:\n%s", out)
	}

	crlf := writeAliasConfig(t, "keys:\r\n  - &a age1aaa\r\n  - &b age1bbb\r\ncreation_rules:\r\n  - path_regex: x$\r\n    age:\r\n      - *a\r\n")
	out, err = AddAliasRecipient(crlf, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ReplaceAll(out, "\r\n", ""), "\n") {
		t.Fatalf("CRLF file came back with bare LF lines:\n%q", out)
	}
}

func TestAddAliasRecipientNeverWrites(t *testing.T) {
	body := "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    age: [*a]\n"
	conf := writeAliasConfig(t, body)
	if _, err := AddAliasRecipient(conf, 0, "b"); err != nil {
		t.Fatal(err)
	}
	after, err := os.ReadFile(conf)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != body {
		t.Fatalf("the config on disk changed:\n%s", after)
	}
}
