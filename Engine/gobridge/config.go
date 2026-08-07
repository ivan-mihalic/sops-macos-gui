package gobridge

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"sort"

	"github.com/getsops/sops/v3/config"
)

// CreationRuleLookup is the result of resolving which .sops.yaml creation
// rule governs a specific target file, via sops's own config parser end to
// end — never a hand-rolled one. See LookupCreationRule.
type CreationRuleLookup struct {
	// Matched is false when the config loaded successfully but no creation
	// rule governs TargetFile — including a .sops.yaml with no
	// creation_rules key at all, which sops's own config.LoadCreationRuleForFile
	// treats identically to "no rule matches" rather than as an error (see
	// parseCreationRuleForFile in config/config.go: `if conf.CreationRules
	// == nil { return nil, nil }`).
	Matched bool `json:"matched"`
	// AgeRecipients are the Bech32 age public keys (age1...) the matched
	// rule resolves to, read from sops's own parsed sops.KeyGroups — via
	// each key's real Go type, not re-parsed from YAML text. Empty (never
	// nil, so it marshals as `[]` not `null`) when Matched is false or the
	// rule uses no age keys.
	AgeRecipients []string `json:"ageRecipients"`
	// NonAgeBackends are the sops master-key type identifiers
	// (keys.MasterKey.TypeToIdentifier(): "pgp", "kms", "gcp_kms",
	// "hckms", "azure_kv", "hc_vault") present anywhere in the matched
	// rule's key groups — including inside a key_groups: block, which sops
	// normalizes into the same []sops.KeyGroup representation as a flat
	// rule, so no separate "key_groups" case is needed here. Empty (never
	// nil) when Matched is false or the rule is age-only.
	NonAgeBackends []string `json:"nonAgeBackends"`
}

// LookupCreationRule resolves which creation rule in the .sops.yaml at
// confPath governs targetFile, using github.com/getsops/sops/v3/config —
// the exact code sops itself uses to answer this question for every
// command. This app's understanding of a .sops.yaml can therefore never
// drift from what sops actually does with it: this replaces three
// consecutive rounds of a hand-rolled Swift YAML scanner, each of which
// shipped a different silent-corruption bug (a nested block list misread as
// a new rule, a flow list read as one recipient with a stray bracket, two
// unrelated rules glued together by a whole-document bracket-balance
// check that quoted-value brackets in different rules could cancel out
// against).
//
// targetFile must be an absolute path. config.LoadCreationRuleForFile
// matches each rule's path_regex against targetFile *relative to confPath's
// directory* (it strips that directory as a literal prefix internally) — a
// relative or differently-rooted targetFile would silently fail to strip,
// and every path_regex would then be matched against the wrong string.
//
// Three outcomes, matching what config.LoadCreationRuleForFile itself
// distinguishes:
//   - a rule matched: (non-nil, nil) with Matched = true.
//   - no rule matched (including no creation_rules key at all): (non-nil,
//     nil) with Matched = false. Not an error, because sops itself does not
//     treat "no rule for this file" as an error, so this app must not act
//     more insistent than sops does.
//   - the config could not be loaded (missing file, malformed YAML,
//     unresolvable key material, an unparseable path_regex reached during
//     matching): (nil, err), with sops's own error text — a real YAML
//     validator's error, not a heuristic's.
func LookupCreationRule(confPath string, targetFile string) (*CreationRuleLookup, error) {
	absTarget, err := filepath.Abs(targetFile)
	if err != nil {
		return nil, fmt.Errorf("resolve target file path: %w", err)
	}

	cfg, err := config.LoadCreationRuleForFile(confPath, absTarget, nil)
	if err != nil {
		if isNoMatchingRuleError(err) {
			return &CreationRuleLookup{AgeRecipients: []string{}, NonAgeBackends: []string{}}, nil
		}
		return nil, err
	}
	if cfg == nil {
		// No creation_rules key in the config at all.
		return &CreationRuleLookup{AgeRecipients: []string{}, NonAgeBackends: []string{}}, nil
	}

	age := []string{}
	backendSet := map[string]bool{}
	for _, group := range cfg.KeyGroups {
		for _, masterKey := range group {
			if id := masterKey.TypeToIdentifier(); id == "age" {
				age = append(age, masterKey.ToString())
			} else {
				backendSet[id] = true
			}
		}
	}
	backends := make([]string, 0, len(backendSet))
	for id := range backendSet {
		backends = append(backends, id)
	}
	sort.Strings(age)
	sort.Strings(backends)

	return &CreationRuleLookup{
		Matched:        true,
		AgeRecipients:  age,
		NonAgeBackends: backends,
	}, nil
}

// LookupCreationRuleJSON is LookupCreationRule for the C boundary, which can
// only carry strings: on success it returns the JSON encoding of a
// CreationRuleLookup. Errors are returned as-is for the caller (cshim) to
// relay as the failure branch of its 0/1 result convention — see
// cshim/main.go's `result` helper and its doc comment.
func LookupCreationRuleJSON(confPath string, targetFile string) ([]byte, error) {
	lookup, err := LookupCreationRule(confPath, targetFile)
	if err != nil {
		return nil, err
	}
	return json.Marshal(lookup)
}

// isNoMatchingRuleError recognizes config/config.go's parseCreationRuleForFile
// literal error text for "a creation_rules list exists but none of its
// entries match this file" — the one LoadCreationRuleForFile error that
// means "no rule governs this file" rather than "the config is broken".
func isNoMatchingRuleError(err error) bool {
	return err != nil && err.Error() == "error loading config: no matching creation rules found"
}
