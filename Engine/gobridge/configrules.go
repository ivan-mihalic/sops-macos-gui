package gobridge

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// Read-only, whole-config view of .sops.yaml for the Access page: named keys
// (YAML anchors under `keys:`), every creation rule with its age recipients
// resolved through aliases to (name, key) pairs, and which rule governs each
// candidate file. Parsing is yaml.v3's Node API — the same parser sops's own
// config loader uses (ADR 0002). Anchors are read from Node.Anchor and
// Node.Alias; nothing here scans text. Nothing here writes.

// NamedKey is one entry under a config's top-level `keys:` list — an age
// recipient that may carry a YAML anchor giving it a human name.
type NamedKey struct {
	Name      string `json:"name"`      // YAML anchor, "" when the entry has none
	Recipient string `json:"recipient"` // age1…
}

// RuleRecipient is one age recipient a creation rule resolves to, with the
// name of the anchor it was aliased from (if any).
type RuleRecipient struct {
	Name      string `json:"name"` // alias target's anchor, or "" for an inline literal
	Recipient string `json:"recipient"`
}

// ConfigRule is one creation_rules entry, fully resolved for display.
type ConfigRule struct {
	Index          int             `json:"index"`
	PathRegex      string          `json:"pathRegex"`
	Recipients     []RuleRecipient `json:"recipients"`
	UsesKeyGroups  bool            `json:"usesKeyGroups"`
	UsesAnchors    bool            `json:"usesAnchors"`
	NonAgeBackends []string        `json:"nonAgeBackends"`
	Comment        string          `json:"comment"` // HeadComment of the rule node, "#" stripped, may be ""
}

// ConfigRules is the whole-config answer InspectConfigRules produces.
type ConfigRules struct {
	Keys  []NamedKey   `json:"keys"`
	Rules []ConfigRule `json:"rules"`
	// GovernedBy maps a candidate path (as passed in) to the index of the
	// rule that governs it; a candidate with no matching rule is absent, not
	// mapped to -1.
	GovernedBy map[string]int `json:"governedBy"`
}

var backendKeys = []string{"pgp", "kms", "gcp_kms", "hc_vault", "azure_kv", "hckms"}

// InspectConfigRules reads confPath and reports its named keys, every
// creation rule (with recipients resolved through anchors/aliases), and which
// rule governs each of candidates. A candidate that matches no rule is simply
// absent from GovernedBy — that is not a failure of this call.
func InspectConfigRules(confPath string, candidates []string) (*ConfigRules, error) {
	raw, err := os.ReadFile(confPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", confPath, err)
	}
	var doc yaml.Node
	if err := yaml.Unmarshal(raw, &doc); err != nil {
		return nil, fmt.Errorf("parse %s: %w", confPath, err)
	}
	out := &ConfigRules{Keys: []NamedKey{}, Rules: []ConfigRule{}, GovernedBy: map[string]int{}}
	root := &doc
	if root.Kind == yaml.DocumentNode && len(root.Content) == 1 {
		root = root.Content[0]
	}
	if root.Kind != yaml.MappingNode {
		return out, nil
	}

	if keysNode := mappingValue(root, "keys"); keysNode != nil && keysNode.Kind == yaml.SequenceNode {
		for _, n := range keysNode.Content {
			if s := scalarOf(n); s != nil {
				out.Keys = append(out.Keys, NamedKey{Name: n.Anchor, Recipient: strings.TrimSpace(s.Value)})
			}
		}
	}
	rulesNode := mappingValue(root, "creation_rules")
	if rulesNode == nil || rulesNode.Kind != yaml.SequenceNode {
		return out, nil
	}

	// Reuse the write-side decode for matching so both answers agree on
	// which rule governs which file.
	var typed writeConfigFile
	if err := yaml.Unmarshal(raw, &typed); err != nil {
		return nil, fmt.Errorf("parse %s: %w", confPath, err)
	}
	configDir := filepath.Dir(confPath)

	for i, rn := range rulesNode.Content {
		rule := ConfigRule{Index: i, Recipients: []RuleRecipient{}, NonAgeBackends: []string{},
			Comment: stripComment(rn.HeadComment)}
		if rn.Kind != yaml.MappingNode {
			out.Rules = append(out.Rules, rule)
			continue
		}
		if pr := mappingValue(rn, "path_regex"); pr != nil {
			rule.PathRegex = pr.Value
		}
		rule.UsesAnchors = containsAnchorOrAlias(rn)
		if age := mappingValue(rn, "age"); age != nil {
			rule.Recipients = append(rule.Recipients, ageRecipients(age)...)
		}
		if kg := mappingValue(rn, "key_groups"); kg != nil && kg.Kind == yaml.SequenceNode {
			rule.UsesKeyGroups = true
			for _, g := range kg.Content {
				if age := mappingValue(g, "age"); age != nil {
					rule.Recipients = append(rule.Recipients, ageRecipients(age)...)
				}
				for _, backend := range backendKeys {
					if mappingValue(g, backend) != nil {
						rule.NonAgeBackends = appendUnique(rule.NonAgeBackends, backend)
					}
				}
			}
		}
		for _, backend := range backendKeys {
			if mappingValue(rn, backend) != nil {
				rule.NonAgeBackends = appendUnique(rule.NonAgeBackends, backend)
			}
		}
		sort.Strings(rule.NonAgeBackends)
		out.Rules = append(out.Rules, rule)
	}
	for _, c := range candidates {
		abs, err := filepath.Abs(c)
		if err != nil {
			continue
		}
		idx, err := matchingRuleIndex(typed.CreationRules, configDir, abs)
		if err != nil || idx < 0 {
			continue
		}
		out.GovernedBy[c] = idx
	}
	return out, nil
}

// ageRecipients flattens an `age:` value — a scalar "a,b", a flow/block
// sequence of scalars, aliases, or a mix — into (name, key) pairs.
func ageRecipients(n *yaml.Node) []RuleRecipient {
	var outRecipients []RuleRecipient
	add := func(node *yaml.Node) {
		name := ""
		if node.Kind == yaml.AliasNode {
			name = node.Alias.Anchor
			node = node.Alias
		} else if node.Anchor != "" {
			name = node.Anchor
		}
		if node.Kind != yaml.ScalarNode {
			return
		}
		for _, piece := range strings.Split(node.Value, ",") {
			if p := strings.TrimSpace(piece); p != "" {
				outRecipients = append(outRecipients, RuleRecipient{Name: name, Recipient: p})
			}
		}
	}
	if n.Kind == yaml.SequenceNode {
		for _, item := range n.Content {
			add(item)
		}
	} else {
		add(n)
	}
	return outRecipients
}

func scalarOf(n *yaml.Node) *yaml.Node {
	if n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	if n.Kind == yaml.ScalarNode {
		return n
	}
	return nil
}

func stripComment(c string) string {
	lines := strings.Split(strings.TrimSpace(c), "\n")
	for i, l := range lines {
		lines[i] = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(l), "#"))
	}
	return strings.TrimSpace(strings.Join(lines, " "))
}

func appendUnique(xs []string, x string) []string {
	for _, y := range xs {
		if y == x {
			return xs
		}
	}
	return append(xs, x)
}

// InspectConfigRulesJSON is InspectConfigRules's cshim-facing wrapper.
// candidatesJSON is a JSON array of paths, or "" for none.
func InspectConfigRulesJSON(confPath string, candidatesJSON string) ([]byte, error) {
	var candidates []string
	if candidatesJSON != "" {
		if err := json.Unmarshal([]byte(candidatesJSON), &candidates); err != nil {
			return nil, fmt.Errorf("decode candidate paths: %w", err)
		}
	}
	r, err := InspectConfigRules(confPath, candidates)
	if err != nil {
		return nil, err
	}
	return json.Marshal(r)
}
