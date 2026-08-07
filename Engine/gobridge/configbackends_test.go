package gobridge

import (
	"encoding/json"
	"strings"
	"testing"
)

// backendsOf runs InspectConfigBackends against a .sops.yaml written into a
// fresh temp dir and fails the test if it errors.
func backendsOf(t *testing.T, contents string) []string {
	t.Helper()
	confPath := writeConfig(t, t.TempDir(), contents)
	got, err := InspectConfigBackends(confPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	return got.Backends
}

func TestInspectConfigBackends_AgeOnlyConfigDeclaresNoUnreadableBackend(t *testing.T) {
	k := newAgeKeyPair(t)
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k.Public+`
`)
	if len(got) != 0 {
		t.Errorf("Backends = %v, want none — an age-only config is fully readable by this app", got)
	}
}

// The finding this whole entry point exists for: a pgp rule with zero
// matching files is invisible to LookupCreationRule (which resolves rules per
// target file), so the recipients check folded it into a blanket .ok.
func TestInspectConfigBackends_PGPOnlyConfigWithNoFilesIsStillVisible(t *testing.T) {
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    pgp: 0000000000000000000000000000000000AAAA
`)
	if !equalStrings(got, []string{"pgp"}) {
		t.Errorf("Backends = %v, want [pgp]", got)
	}
}

func TestInspectConfigBackends_MixedAgeRuleAndPGPRule(t *testing.T) {
	k := newAgeKeyPair(t)
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k.Public+`
  - path_regex: legacy/.*\.yaml$
    pgp: 0000000000000000000000000000000000AAAA
`)
	if !equalStrings(got, []string{"pgp"}) {
		t.Errorf("Backends = %v, want [pgp] — the healthy age rule must not hide the pgp one", got)
	}
}

// Every backend name a creation rule can carry, under the exact YAML keys
// getsops/sops v3.13.3's config.creationRule declares, mapped to the same
// master-key type identifiers LookupCreationRule reports
// (keys.MasterKey.TypeToIdentifier()) so both paths speak one vocabulary.
func TestInspectConfigBackends_EveryCreationRuleBackendKey(t *testing.T) {
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    kms: arn:aws:kms:us-east-1:000000000000:key/test
    gcp_kms: projects/test/locations/global/keyRings/test/cryptoKeys/test
    azure_keyvault: https://test.vault.azure.net/keys/test/0000
    hc_vault_transit_uri: https://vault.example.invalid:8200/v1/transit/keys/test
    hckms:
      - key_id: test-key-id
    pgp: 0000000000000000000000000000000000AAAA
`)
	want := []string{"azure_kv", "gcp_kms", "hc_vault", "hckms", "kms", "pgp"}
	if !equalStrings(got, want) {
		t.Errorf("Backends = %v, want %v", got, want)
	}
}

func TestInspectConfigBackends_KeyGroupsCarryingPGPAreReported(t *testing.T) {
	k := newAgeKeyPair(t)
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - `+k.Public+`
        pgp:
          - 0000000000000000000000000000000000AAAA
`)
	if !equalStrings(got, []string{"pgp"}) {
		t.Errorf("Backends = %v, want [pgp]", got)
	}
}

// Decision, deliberately encoded as a test: a key group holding only age
// recipients is NOT unevaluable. sops normalizes key_groups into the same
// []sops.KeyGroup a flat rule produces, so LookupCreationRule already reads
// those recipients and the per-file comparison is a real comparison. Flagging
// it here would raise a caveat about something the app demonstrably can read.
func TestInspectConfigBackends_AgeOnlyKeyGroupIsNotUnevaluable(t *testing.T) {
	k1, k2 := newAgeKeyPair(t), newAgeKeyPair(t)
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - `+k1.Public+`
      - age:
          - `+k2.Public+`
`)
	if len(got) != 0 {
		t.Errorf("Backends = %v, want none — age-only key groups are readable", got)
	}
}

func TestInspectConfigBackends_MergedKeyGroupsAreScannedToo(t *testing.T) {
	k := newAgeKeyPair(t)
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    key_groups:
      - age:
          - `+k.Public+`
        merge:
          - hc_vault:
              - https://vault.example.invalid:8200/v1/transit/keys/test
`)
	if !equalStrings(got, []string{"hc_vault"}) {
		t.Errorf("Backends = %v, want [hc_vault]", got)
	}
}

func TestInspectConfigBackends_ExplicitlyEmptyBackendIsNotDeclared(t *testing.T) {
	k := newAgeKeyPair(t)
	got := backendsOf(t, `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k.Public+`
    pgp: []
    kms: ""
`)
	if len(got) != 0 {
		t.Errorf("Backends = %v, want none — pgp: [] and kms: \"\" declare nothing", got)
	}
}

func TestInspectConfigBackends_NoCreationRulesKeyAtAllIsNotAnError(t *testing.T) {
	got := backendsOf(t, "stores:\n  yaml:\n    indent: 2\n")
	if len(got) != 0 {
		t.Errorf("Backends = %v, want none", got)
	}
}

func TestInspectConfigBackends_MalformedYAMLIsAnError(t *testing.T) {
	confPath := writeConfig(t, t.TempDir(), "creation_rules:\n  - this: [is: not: valid\n")
	if _, err := InspectConfigBackends(confPath); err == nil {
		t.Fatalf("expected an error for malformed YAML, got none")
	}
}

func TestInspectConfigBackends_MissingConfigFileIsAnError(t *testing.T) {
	if _, err := InspectConfigBackends(t.TempDir() + "/.sops.yaml"); err == nil {
		t.Fatalf("expected an error for a missing config file, got none")
	}
}

// The shapes that broke the deleted hand-rolled Swift parser, asserted here
// too: this entry point must never grow its own YAML scanning either.
func TestInspectConfigBackends_AwkwardButValidYAMLShapes(t *testing.T) {
	k := newAgeKeyPair(t)
	cases := map[string]string{
		"single-line flow list": `creation_rules:
  # a comment, and a trailing one below
  - path_regex: 'secrets/[a-z]+\.yaml$' # governs the app's own secrets
    age: [` + k.Public + `]
    pgp: [0000000000000000000000000000000000AAAA, 0000000000000000000000000000000000BBBB]
`,
		"multi-line flow list": `creation_rules:
  - path_regex: secrets/.*\.yaml$
    pgp: [0000000000000000000000000000000000AAAA,
          0000000000000000000000000000000000BBBB]
`,
		"block list": `creation_rules:
  - path_regex: secrets/.*\.yaml$
    pgp:
      - 0000000000000000000000000000000000AAAA
      - 0000000000000000000000000000000000BBBB
`,
		"CRLF line endings": "creation_rules:\r\n  - path_regex: secrets/.*\\.yaml$\r\n    pgp: 0000000000000000000000000000000000AAAA\r\n",
		"later rule matches": `creation_rules:
  - path_regex: unrelated/.*\.yaml$
    age: ` + k.Public + `
  - path_regex: secrets/.*\.yaml$
    pgp: 0000000000000000000000000000000000AAAA
`,
	}
	for name, contents := range cases {
		t.Run(name, func(t *testing.T) {
			if got := backendsOf(t, contents); !equalStrings(got, []string{"pgp"}) {
				t.Errorf("Backends = %v, want [pgp]", got)
			}
		})
	}
}

func TestInspectConfigBackendsJSON_ShapeIsStableForSwiftDecoding(t *testing.T) {
	confPath := writeConfig(t, t.TempDir(), `creation_rules:
  - path_regex: secrets/.*\.yaml$
    pgp: 0000000000000000000000000000000000AAAA
`)
	payload, err := InspectConfigBackendsJSON(confPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	var decoded struct {
		Backends []string `json:"backends"`
	}
	if err := json.Unmarshal(payload, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !equalStrings(decoded.Backends, []string{"pgp"}) {
		t.Errorf("backends = %v, want [pgp]", decoded.Backends)
	}
}

// Swift's Decodable for [String] rejects JSON null, so an age-only config
// must marshal `"backends": []`, never `"backends": null`.
func TestInspectConfigBackendsJSON_AgeOnlyConfigStillProducesANonNullArray(t *testing.T) {
	k := newAgeKeyPair(t)
	confPath := writeConfig(t, t.TempDir(), `creation_rules:
  - path_regex: secrets/.*\.yaml$
    age: `+k.Public+`
`)
	payload, err := InspectConfigBackendsJSON(confPath)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !strings.Contains(string(payload), `"backends":[]`) {
		t.Errorf("payload = %s, want an empty JSON array for backends", payload)
	}
}
