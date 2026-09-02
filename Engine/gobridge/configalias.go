package gobridge

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"go.yaml.in/yaml/v3"
)

// The one write an anchored `.sops.yaml` supports: appending an alias of a
// key already declared under `keys:` to a creation rule's age list.
//
// `UpdateConfigRecipients` refuses a rule built from anchors or key groups on
// purpose — it rewrites the *whole* recipient list, and doing that to an
// anchored rule means deciding which group each key belongs in and whether an
// alias may be replaced by the literal behind it. Neither is knowable from the
// file. Appending one alias to the end of the rule's first `age:` sequence is
// a different question with one answer: nothing is removed, nothing is
// resolved, and the anchor the user picked is the one that lands in the file.
//
// Like every other config call here, this **never writes**: it returns the
// text the file would hold and the Swift side writes it, atomically and only
// after the user has confirmed.

// AddAliasRecipient returns what confPath would contain with an alias of the
// `keys:` anchor named `anchor` appended to creation rule `ruleIndex`.
//
// Refused, with an error naming what was found:
//   - `anchor` is not declared under the config's top-level `keys:`,
//   - `ruleIndex` is outside the config's creation rule list,
//   - the rule already aliases that anchor,
//   - the rule uses `key_groups` holding **more than one group** — several
//     possible destinations, and picking one is a guess about who may read
//     what, so this refuses instead of guessing.
//
// A rule whose `age:` is a scalar ("a,b") becomes a sequence of those same
// scalars plus the alias; a rule with no `age:` at all gets one. Comments,
// the file's own indent width and its line endings survive, because the
// document is round-tripped through the same node encoder
// `UpdateConfigRecipients` uses.
func AddAliasRecipient(confPath string, ruleIndex int, anchor string) (string, error) {
	name := filepath.Base(confPath)
	raw, err := os.ReadFile(confPath)
	if err != nil {
		return "", fmt.Errorf("read %s: %w", confPath, err)
	}
	crlf := bytes.Count(raw, []byte("\r\n"))
	bareLF := bytes.Count(raw, []byte("\n")) - crlf
	if crlf > 0 && bareLF > 0 {
		return "", fmt.Errorf("%s mixes line endings, so it is not rewritten here", name)
	}

	var root yaml.Node
	if err := yaml.Unmarshal(raw, &root); err != nil {
		return "", fmt.Errorf("could not read %s: %w", name, err)
	}
	document := documentMapping(&root)
	if document == nil {
		return "", fmt.Errorf("%s declares no creation rules", name)
	}

	target := anchoredKey(document, anchor)
	if target == nil {
		return "", fmt.Errorf("no key named %q under keys: in %s", anchor, name)
	}

	rulesNode := mappingValue(document, "creation_rules")
	if rulesNode == nil || rulesNode.Kind != yaml.SequenceNode {
		return "", fmt.Errorf("%s declares no creation rules", name)
	}
	if ruleIndex < 0 || ruleIndex >= len(rulesNode.Content) {
		return "", fmt.Errorf("%s has no creation rule %d", name, ruleIndex)
	}
	rule := rulesNode.Content[ruleIndex]
	if rule.Kind != yaml.MappingNode {
		return "", fmt.Errorf("creation rule %d in %s is not a rule", ruleIndex, name)
	}

	// Where the alias goes: the rule's own `age:` when it has one, otherwise
	// the single key group's. Two groups is the refusal above.
	holder := rule
	if groups := mappingValue(rule, "key_groups"); groups != nil {
		if groups.Kind != yaml.SequenceNode || len(groups.Content) == 0 {
			return "", fmt.Errorf("creation rule %d in %s declares no usable key group", ruleIndex, name)
		}
		// Refused whether or not the rule also carries a top-level `age:`:
		// with several groups there is no single answer to "who gains
		// access", and a rule spelling both forms is one this app does not
		// claim to understand well enough to add to.
		if len(groups.Content) > 1 {
			return "", fmt.Errorf(
				"creation rule %d in %s has more than one key group, so there is no single place to add a key",
				ruleIndex, name)
		}
		if mappingValue(rule, "age") == nil {
			if groups.Content[0].Kind != yaml.MappingNode {
				return "", fmt.Errorf("creation rule %d in %s declares no usable key group", ruleIndex, name)
			}
			holder = groups.Content[0]
		}
	}

	age := mappingValue(holder, "age")
	sequence, err := ageSequence(age)
	if err != nil {
		return "", fmt.Errorf("creation rule %d in %s: %w", ruleIndex, name, err)
	}
	for _, item := range sequence.Content {
		if item.Kind == yaml.AliasNode && item.Value == anchor {
			return "", fmt.Errorf("creation rule %d in %s already names %q", ruleIndex, name, anchor)
		}
	}
	sequence.Content = append(sequence.Content,
		&yaml.Node{Kind: yaml.AliasNode, Value: anchor, Alias: target})
	setMappingValue(holder, "age", sequence)

	emitted, err := encodeConfig(&root, inferIndent(document))
	if err != nil {
		return "", fmt.Errorf("could not write out %s: %w", name, err)
	}
	if crlf > 0 {
		emitted = strings.ReplaceAll(emitted, "\n", "\r\n")
	}
	return emitted, nil
}

// anchoredKey finds the `keys:` entry carrying `anchor`. Deliberately scoped
// to that list rather than to the whole document: an anchor defined somewhere
// else is not a key this config offers, and aliasing it into a rule would put
// a value of unknown shape where a recipient belongs.
func anchoredKey(document *yaml.Node, anchor string) *yaml.Node {
	if anchor == "" {
		return nil
	}
	keys := mappingValue(document, "keys")
	if keys == nil || keys.Kind != yaml.SequenceNode {
		return nil
	}
	for _, entry := range keys.Content {
		if entry.Kind == yaml.ScalarNode && entry.Anchor == anchor {
			return entry
		}
	}
	return nil
}

// ageSequence returns `age`'s value as a sequence node that can be appended
// to: the node itself when it already is one, a fresh sequence holding the
// same scalars when the value is written as `age: a,b`, and an empty one when
// the rule has no `age:` at all.
func ageSequence(age *yaml.Node) (*yaml.Node, error) {
	if age == nil || age.Tag == "!!null" {
		return &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}, nil
	}
	if age.Kind == yaml.SequenceNode {
		return age, nil
	}
	if age.Kind != yaml.ScalarNode {
		return nil, fmt.Errorf("its age: is neither a key nor a list of them")
	}
	sequence := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
	for _, piece := range strings.Split(age.Value, ",") {
		if p := strings.TrimSpace(piece); p != "" {
			sequence.Content = append(sequence.Content,
				&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: p})
		}
	}
	return sequence, nil
}
