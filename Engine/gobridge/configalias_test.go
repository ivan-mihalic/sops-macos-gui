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

// The rule already names the key, spelled out literally rather than through
// the anchor — what a config looks like when the key was pasted into the rule
// by hand and declared under `keys:` afterwards. Only the alias spelling was
// refused before, so this case appended a second entry for a recipient the
// rule already grants: no extra access, and a rule that reads as if two
// people can decrypt it.
func TestAddAliasRecipientRefusesAKeyTheRuleAlreadyNamesLiterally(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    age:\n      - age1bbb\n")
	out, err := AddAliasRecipient(conf, 0, "b")
	if err == nil {
		t.Fatalf("a key the rule already names literally must be refused, got:\n%s", out)
	}
	if !strings.Contains(err.Error(), `"b"`) {
		t.Fatalf("the refusal must name the anchor: %v", err)
	}
	// Never the key material: the refusal is about a public key sitting in
	// the rule, and this bridge does not quote key values into messages.
	if strings.Contains(err.Error(), "age1bbb") {
		t.Fatalf("a refusal must not quote a key: %v", err)
	}
	// The anchor that is genuinely absent still goes in, so the new check
	// refuses the duplicate rather than every addition.
	if _, err := AddAliasRecipient(conf, 0, "a"); err != nil {
		t.Fatalf("an anchor the rule does not name must still be addable: %v", err)
	}
}

// MARK: - RemoveAliasRecipient (SOPS-42)

func TestRemoveAliasRecipientDropsTheAliasAndKeepsComments(t *testing.T) {
	conf := writeAliasConfig(t, "# header\nkeys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  # rule comment\n  - path_regex: x$\n    age:\n      - *a\n      - *b\n")
	out, err := RemoveAliasRecipient(conf, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"# header", "# rule comment", "*a", "&b age1bbb"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in:\n%s", want, out)
		}
	}
	if strings.Contains(out, "*b") {
		t.Fatalf("the alias is still there:\n%s", out)
	}
}

func TestRemoveAliasRecipientOutputReparsesWithoutTheName(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &studio age1aaa\n  - &vps age1bbb\ncreation_rules:\n  - path_regex: x$\n    age:\n      - *studio\n      - *vps\n")
	out, err := RemoveAliasRecipient(conf, 0, "vps")
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
	names := []string{}
	for _, r := range rules.Rules[0].Recipients {
		names = append(names, r.Name)
	}
	if strings.Join(names, ",") != "studio" {
		t.Fatalf("rule recipients after removal: %v", names)
	}
	if len(rules.Keys) != 2 {
		t.Fatalf("keys: must keep the declaration, got %d", len(rules.Keys))
	}
}

func TestRemoveAliasRecipientRefusesUnknownAbsentLiteralAndLastRecipient(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &a age1aaa\n  - &b age1bbb\n  - &c age1ccc\ncreation_rules:\n  - path_regex: x$\n    age:\n      - *a\n      - age1bbb\n  - path_regex: y$\n    age:\n      - *a\n")
	if _, err := RemoveAliasRecipient(conf, 0, "zzz"); err == nil {
		t.Fatal("unknown anchor must fail")
	}
	if _, err := RemoveAliasRecipient(conf, 0, "c"); err == nil || !strings.Contains(err.Error(), `"c"`) {
		t.Fatalf("an anchor the rule does not name must fail naming it: %v", err)
	}
	err := func() error { _, err := RemoveAliasRecipient(conf, 0, "b"); return err }()
	if err == nil || !strings.Contains(err.Error(), "literally") {
		t.Fatalf("a literal must be refused as such: %v", err)
	}
	if strings.Contains(err.Error(), "age1bbb") {
		t.Fatalf("a refusal must not quote a key: %v", err)
	}
	if _, err := RemoveAliasRecipient(conf, 1, "a"); err == nil || !strings.Contains(err.Error(), "no age recipient") {
		t.Fatalf("removing the last recipient must be refused: %v", err)
	}
	if _, err := RemoveAliasRecipient(conf, 7, "a"); err == nil {
		t.Fatal("rule index out of range must fail")
	}
}

func TestRemoveAliasRecipientRefusesSeveralKeyGroupsAndHandlesOne(t *testing.T) {
	several := writeAliasConfig(t, "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    key_groups:\n      - age: [*a, *b]\n      - age: [*b]\n")
	if _, err := RemoveAliasRecipient(several, 0, "b"); err == nil {
		t.Fatal("several key groups must be refused")
	}
	one := writeAliasConfig(t, "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    key_groups:\n      - age: [*a, *b]\n")
	out, err := RemoveAliasRecipient(one, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(out, "*b") || !strings.Contains(out, "*a") {
		t.Fatalf("single group not edited:\n%s", out)
	}
}

func TestRemoveAliasRecipientKeepsIndentAndLineEndings(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\r\n    - &a age1aaa\r\n    - &b age1bbb\r\ncreation_rules:\r\n    - path_regex: x$\r\n      age:\r\n          - *a\r\n          - *b\r\n")
	out, err := RemoveAliasRecipient(conf, 0, "b")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(strings.ReplaceAll(out, "\r\n", ""), "\n") {
		t.Fatalf("CRLF file came back with bare LF lines:\n%q", out)
	}
	if !strings.Contains(out, "    - &a") {
		t.Fatalf("four-space indent lost:\n%s", out)
	}
}

func TestRemoveAliasRecipientNeverWrites(t *testing.T) {
	body := "keys:\n  - &a age1aaa\n  - &b age1bbb\ncreation_rules:\n  - path_regex: x$\n    age: [*a, *b]\n"
	conf := writeAliasConfig(t, body)
	if _, err := RemoveAliasRecipient(conf, 0, "b"); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(conf)
	if string(after) != body {
		t.Fatalf("the config on disk changed:\n%s", after)
	}
}

// MARK: - AddNamedKey (SOPS-42)

const (
	namedKeyA = "age1ccsm6kw9f5vx4znq75wufan68wtt6uzhn3aka7zpnyr252e87aeqt2pg0m"
	namedKeyB = "age1fz69490r89f7gvuhcypsqn6v2yquxdw7pgryw0ujqrmx009qg4yspxs2de"
)

func TestAddNamedKeyDeclaresAnchorAndAliasesItIntoTheRule(t *testing.T) {
	conf := writeAliasConfig(t, "# header\nkeys:\n  - &a "+namedKeyA+"\ncreation_rules:\n  - path_regex: x$\n    age:\n      - *a\n")
	out, err := AddNamedKey(conf, "deploy", namedKeyB, 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"# header", "&deploy " + namedKeyB, "*a", "*deploy"} {
		if !strings.Contains(out, want) {
			t.Fatalf("missing %q in:\n%s", want, out)
		}
	}
	if err := os.WriteFile(conf, []byte(out), 0o600); err != nil {
		t.Fatal(err)
	}
	rules, err := InspectConfigRules(conf, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules.Keys) != 2 || rules.Keys[1].Name != "deploy" || rules.Keys[1].Recipient != namedKeyB {
		t.Fatalf("keys after: %+v", rules.Keys)
	}
	rec := rules.Rules[0].Recipients
	if len(rec) != 2 || rec[1].Name != "deploy" {
		t.Fatalf("rule recipients after: %+v", rec)
	}
}

func TestAddNamedKeyCreatesKeysListWhenAbsent(t *testing.T) {
	conf := writeAliasConfig(t, "creation_rules:\n  - path_regex: x$\n    age:\n      - "+namedKeyA+"\n")
	out, err := AddNamedKey(conf, "deploy", namedKeyB, 0)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Index(out, "keys:") > strings.Index(out, "creation_rules:") {
		t.Fatalf("keys: must precede creation_rules so anchors are defined first:\n%s", out)
	}
	if err := os.WriteFile(conf, []byte(out), 0o600); err != nil {
		t.Fatal(err)
	}
	rules, err := InspectConfigRules(conf, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(rules.Keys) != 1 || rules.Keys[0].Name != "deploy" {
		t.Fatalf("keys after: %+v", rules.Keys)
	}
	if len(rules.Rules[0].Recipients) != 2 {
		t.Fatalf("rule recipients after: %+v", rules.Rules[0].Recipients)
	}
}

func TestAddNamedKeyRefusesBadAnchorNamesAndTakenNames(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &a "+namedKeyA+"\ncreation_rules:\n  - path_regex: x$\n    age: [*a]\n")
	for _, bad := range []string{"", "two words", "x[y]", "a,b", "&x", "*x", "x#y", "tab\tx", "a.b", "ünïcode"} {
		if _, err := AddNamedKey(conf, bad, namedKeyB, 0); err == nil {
			t.Fatalf("anchor %q must be refused", bad)
		}
	}
	if _, err := AddNamedKey(conf, "a", namedKeyB, 0); err == nil || !strings.Contains(err.Error(), `"a"`) {
		t.Fatalf("a taken name must be refused naming it: %v", err)
	}
	if _, err := AddNamedKey(conf, "mac_studio-2", namedKeyB, 0); err != nil {
		t.Fatalf("ordinary punctuation must be allowed: %v", err)
	}
}

func TestAddNamedKeyRefusesInvalidPrivateAndDuplicateRecipients(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &a "+namedKeyA+"\ncreation_rules:\n  - path_regex: x$\n    age: [*a]\n")
	private := "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
	for _, bad := range []string{"", "not-a-key", private, "age1aaa"} {
		_, err := AddNamedKey(conf, "deploy", bad, 0)
		if err == nil {
			t.Fatalf("recipient %q must be refused", bad)
		}
		if bad != "" && strings.Contains(err.Error(), bad) {
			t.Fatalf("a refusal must not quote the value: %v", err)
		}
	}
	err := func() error { _, err := AddNamedKey(conf, "deploy", namedKeyA, 0); return err }()
	if err == nil || !strings.Contains(err.Error(), `"a"`) {
		t.Fatalf("a key keys: already declares must be refused naming the existing anchor: %v", err)
	}
	if strings.Contains(err.Error(), namedKeyA) {
		t.Fatalf("a refusal must not quote a key: %v", err)
	}
}

func TestAddNamedKeyDeclareOnlyWithRuleIndexMinusOne(t *testing.T) {
	conf := writeAliasConfig(t, "keys:\n  - &a "+namedKeyA+"\ncreation_rules:\n  - path_regex: x$\n    age: [*a]\n")
	out, err := AddNamedKey(conf, "deploy", namedKeyB, -1)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "&deploy") || strings.Contains(out, "*deploy") {
		t.Fatalf("declare-only must add the anchor and no alias:\n%s", out)
	}
}

func TestAddNamedKeyNeverWrites(t *testing.T) {
	body := "keys:\n  - &a " + namedKeyA + "\ncreation_rules:\n  - path_regex: x$\n    age: [*a]\n"
	conf := writeAliasConfig(t, body)
	if _, err := AddNamedKey(conf, "deploy", namedKeyB, 0); err != nil {
		t.Fatal(err)
	}
	after, _ := os.ReadFile(conf)
	if string(after) != body {
		t.Fatalf("the config on disk changed:\n%s", after)
	}
}
