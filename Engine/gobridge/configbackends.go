package gobridge

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// ConfigBackends is what key backends a whole .sops.yaml declares, anywhere in
// it — independent of which files currently exist. See InspectConfigBackends.
type ConfigBackends struct {
	// Backends are sops master-key type identifiers ("pgp", "kms", "gcp_kms",
	// "hckms", "azure_kv", "hc_vault") — the same vocabulary
	// CreationRuleLookup.NonAgeBackends speaks, so both paths can share one
	// label table on the Swift side. Age is deliberately absent: age is the
	// one backend this app reads in full, so its presence is not a caveat.
	// Sorted and deduplicated; empty (never nil, so it marshals as `[]` and
	// not `null`, which Swift's Decodable for [String] rejects) when the
	// config is age-only.
	Backends []string `json:"backends"`
}

// InspectConfigBackends reports which key backends the .sops.yaml at confPath
// declares anywhere across its creation rules — including a rule that has no
// matching encrypted file today.
//
// Why this exists alongside LookupCreationRule: sops's own config API resolves
// a rule *for one target file* (config.LoadCreationRuleForFile), and exposes no
// enumerate-every-rule call — configFile and creationRule are unexported. A
// rule declaring pgp/KMS/Vault with zero currently-matching files was therefore
// invisible to the per-file path, and ProjectHealthCheck's recipients finding
// folded that silence into a confident "every file's key list matches" — an OK
// about a configuration the app cannot evaluate at all. PROPOSAL.md §6 D
// forbids exactly that.
//
// Why this is not a second .sops.yaml parser, despite reading the file
// directly (ADR 0002 bans hand-rolled YAML parsing on either side of the
// bridge): the YAML is parsed by go.yaml.in/yaml/v3 — the same real parser
// sops's own config.load uses at this pinned version — into the structs below,
// which mirror nothing but the backend key names from
// config.creationRule/config.keyGroup in getsops/sops v3.13.3. No line
// scanning, no bracket counting, no indentation state machine: every shape
// that broke the deleted Swift scanner (flow lists on one line or several,
// block lists, comments, quoted path_regex, CRLF) is the YAML library's
// problem, not ours. What this deliberately does NOT do is interpret the key
// *values* — it never resolves a fingerprint, an ARN or a recipient, so
// nothing here can drift from sops's semantics for those; it only answers
// "which backends does this config name".
func InspectConfigBackends(confPath string) (*ConfigBackends, error) {
	raw, err := os.ReadFile(confPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", confPath, err)
	}

	var file backendConfigFile
	if err := yaml.Unmarshal(raw, &file); err != nil {
		return nil, fmt.Errorf("could not unmarshal config file: %w", err)
	}

	seen := map[string]bool{}
	for _, rule := range file.CreationRules {
		for _, id := range rule.backends() {
			seen[id] = true
		}
	}

	backends := make([]string, 0, len(seen))
	for id := range seen {
		backends = append(backends, id)
	}
	sort.Strings(backends)
	return &ConfigBackends{Backends: backends}, nil
}

// InspectConfigBackendsJSON is InspectConfigBackends for the C boundary, which
// can only carry strings: on success it returns the JSON encoding of a
// ConfigBackends. Errors are returned as-is for cshim to relay as the failure
// branch of its 0/1 result convention.
func InspectConfigBackendsJSON(confPath string) ([]byte, error) {
	backends, err := InspectConfigBackends(confPath)
	if err != nil {
		return nil, err
	}
	return json.Marshal(backends)
}

// backendConfigFile mirrors only what this question needs from
// config.configFile. destination_rules are not scanned: they configure
// `sops publish` targets, not which keys govern a file in the working tree,
// which is the only thing ProjectHealthCheck reports on.
type backendConfigFile struct {
	CreationRules []backendCreationRule `yaml:"creation_rules"`
}

// backendCreationRule mirrors the backend-bearing fields of
// config.creationRule in getsops/sops v3.13.3, under the exact YAML keys sops
// itself declares — `azure_keyvault` and `hc_vault_transit_uri` at rule level,
// which sops spells differently inside a key group (see backendKeyGroup).
// Every field is `any` for the same reason sops declares most of them
// `interface{}`: a value may be a scalar, a comma-joined string, or a list.
// This type reads presence only, never meaning.
//
// `age` is intentionally absent: age is the one backend this app can read, so
// an age key is never a caveat. Non-key fields (path_regex, shamir_threshold,
// the suffix/regex settings) are absent because nothing here needs them.
type backendCreationRule struct {
	KMS           any               `yaml:"kms"`
	PGP           any               `yaml:"pgp"`
	GCPKMS        any               `yaml:"gcp_kms"`
	HCKMS         any               `yaml:"hckms"`
	AzureKeyVault any               `yaml:"azure_keyvault"`
	VaultURI      any               `yaml:"hc_vault_transit_uri"`
	KeyGroups     []backendKeyGroup `yaml:"key_groups"`
}

func (r backendCreationRule) backends() []string {
	found := declaredBackends(map[string]any{
		"kms":      r.KMS,
		"pgp":      r.PGP,
		"gcp_kms":  r.GCPKMS,
		"hckms":    r.HCKMS,
		"azure_kv": r.AzureKeyVault,
		"hc_vault": r.VaultURI,
	})
	for _, group := range r.KeyGroups {
		found = append(found, group.backends()...)
	}
	return found
}

// backendKeyGroup mirrors the backend-bearing fields of config.keyGroup in
// getsops/sops v3.13.3. Note the two keys sops spells differently here than at
// rule level: `hc_vault` (not `hc_vault_transit_uri`) and `azure_keyvault`
// carrying mappings rather than URLs. Both spellings are honoured exactly
// where sops honours them, so this never raises a caveat about a key sops
// itself would ignore.
//
// `age` is absent for the same reason as in backendCreationRule, and that is
// the deliberate answer to "should an age-only key group count as
// unevaluable": it should not. sops normalizes key_groups into the same
// []sops.KeyGroup a flat rule produces (getKeyGroupsFromCreationRule), so
// LookupCreationRule already resolves an age-only group's recipients and the
// per-file comparison against them is a real comparison. Flagging it would
// withhold a verdict the app is fully able to reach.
type backendKeyGroup struct {
	Merge         []backendKeyGroup `yaml:"merge"`
	KMS           any               `yaml:"kms"`
	PGP           any               `yaml:"pgp"`
	GCPKMS        any               `yaml:"gcp_kms"`
	HCKMS         any               `yaml:"hckms"`
	AzureKeyVault any               `yaml:"azure_keyvault"`
	Vault         any               `yaml:"hc_vault"`
}

func (g backendKeyGroup) backends() []string {
	found := declaredBackends(map[string]any{
		"kms":      g.KMS,
		"pgp":      g.PGP,
		"gcp_kms":  g.GCPKMS,
		"hckms":    g.HCKMS,
		"azure_kv": g.AzureKeyVault,
		"hc_vault": g.Vault,
	})
	for _, merged := range g.Merge {
		found = append(found, merged.backends()...)
	}
	return found
}

func declaredBackends(fields map[string]any) []string {
	found := []string{}
	for id, value := range fields {
		if declared(value) {
			found = append(found, id)
		}
	}
	return found
}

// declared reports whether a backend field names anything at all. An absent
// key, an empty string, an empty list and an empty mapping all mean "this rule
// explicitly uses none of this backend" — the app can still say everything it
// checked, so they must not raise a caveat.
func declared(value any) bool {
	switch v := value.(type) {
	case nil:
		return false
	case string:
		return strings.TrimSpace(v) != ""
	case []any:
		for _, item := range v {
			if declared(item) {
				return true
			}
		}
		return false
	case map[string]any:
		return len(v) > 0
	default:
		// A number, a bool, anything else a user might have typed: it is
		// present, and this app cannot read it. Erring toward "declared" here
		// costs a caveat; erring the other way costs a false OK.
		return true
	}
}
