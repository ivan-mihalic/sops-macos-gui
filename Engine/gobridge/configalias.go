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
	doc, err := loadConfigDocument(confPath)
	if err != nil {
		return "", err
	}
	target := anchoredKey(doc.document, anchor)
	if target == nil {
		return "", fmt.Errorf("no key named %q under keys: in %s", anchor, doc.name)
	}
	if err := appendAlias(doc, ruleIndex, anchor, target); err != nil {
		return "", err
	}
	return doc.emit()
}

// RemoveAliasRecipient returns what confPath would contain with the alias of
// the `keys:` anchor named `anchor` removed from creation rule `ruleIndex` —
// the inverse of AddAliasRecipient, under the same rules.
//
// Refused, with an error naming what was found:
//   - `anchor` is not declared under `keys:`,
//   - `ruleIndex` is outside the creation rule list,
//   - the rule uses `key_groups` holding more than one group,
//   - the rule does not alias that anchor. When it names the key the anchor
//     stands for *literally*, the refusal says so: editing a literal is a
//     different operation and is not done here,
//   - removing it would leave the rule's `age:` empty. A rule with no age
//     recipient is one nobody can decrypt files under; sops refuses to
//     encrypt with it, and this app does not write a config it knows to be
//     unusable.
//
// Never writes.
func RemoveAliasRecipient(confPath string, ruleIndex int, anchor string) (string, error) {
	doc, err := loadConfigDocument(confPath)
	if err != nil {
		return "", err
	}
	target := anchoredKey(doc.document, anchor)
	if target == nil {
		return "", fmt.Errorf("no key named %q under keys: in %s", anchor, doc.name)
	}
	holder, rule, err := ruleAgeHolder(doc, ruleIndex)
	if err != nil {
		return "", err
	}
	age := mappingValue(holder, "age")
	sequence, err := ageSequence(age)
	if err != nil {
		return "", fmt.Errorf("creation rule %d in %s: %w", ruleIndex, doc.name, err)
	}
	targetValue := ""
	if scalar := scalarOf(target); scalar != nil {
		targetValue = scalar.Value
	}
	kept := make([]*yaml.Node, 0, len(sequence.Content))
	removed := false
	literal := false
	for _, item := range sequence.Content {
		switch {
		case item.Kind == yaml.AliasNode && item.Value == anchor:
			removed = true
		case targetValue != "" && item.Kind == yaml.ScalarNode && item.Value == targetValue:
			literal = true
			kept = append(kept, item)
		default:
			kept = append(kept, item)
		}
	}
	if !removed {
		if literal {
			return "", fmt.Errorf(
				"creation rule %d in %s names the key %q stands for literally, so it is not removed here",
				ruleIndex, doc.name, anchor)
		}
		return "", fmt.Errorf("creation rule %d in %s does not name %q", ruleIndex, doc.name, anchor)
	}
	if len(kept) == 0 {
		return "", fmt.Errorf(
			"removing %q would leave creation rule %d in %s with no age recipient",
			anchor, ruleIndex, doc.name)
	}
	_ = rule
	sequence.Content = kept
	setMappingValue(holder, "age", sequence)
	return doc.emit()
}

// AddNamedKey returns what confPath would contain with a new `keys:` entry
// `- &name recipient` and, unless ruleIndex is -1, an alias of it appended to
// creation rule `ruleIndex` exactly as AddAliasRecipient would.
//
// Refused, with an error naming what was found:
//   - `name` is empty, carries whitespace, or a character YAML does not allow
//     in an anchor,
//   - `keys:` already declares an entry anchored `name`,
//   - `recipient` is not a native age public key — a private identity, a
//     plugin recipient and garbage are all refused, and the error never
//     quotes the value,
//   - `keys:` already declares that same public key under another name. The
//     error names that anchor, not the key.
//
// A config with no `keys:` gets one, placed before `creation_rules` so the
// anchors are defined before the aliases that use them. Never writes.
func AddNamedKey(confPath string, name string, recipient string, ruleIndex int) (string, error) {
	doc, err := loadConfigDocument(confPath)
	if err != nil {
		return "", err
	}
	if err := validateAnchorName(name); err != nil {
		return "", err
	}
	if anchoredKey(doc.document, name) != nil {
		return "", fmt.Errorf("keys: in %s already declares a key named %q", doc.name, name)
	}
	recipient = strings.TrimSpace(recipient)
	if _, err := validAgeRecipients([]string{recipient}); err != nil {
		return "", fmt.Errorf("the public key for %q is not usable: %w", name, err)
	}

	keys := mappingValue(doc.document, "keys")
	if keys == nil {
		keys = &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq"}
		insertMappingValueFirst(doc.document, "keys", keys)
	} else if keys.Kind != yaml.SequenceNode {
		return "", fmt.Errorf("keys: in %s is not a list", doc.name)
	}
	for _, entry := range keys.Content {
		if scalar := scalarOf(entry); scalar != nil && scalar.Value == recipient {
			label := entry.Anchor
			if label == "" {
				label = "an unnamed entry"
			} else {
				label = fmt.Sprintf("%q", label)
			}
			return "", fmt.Errorf("keys: in %s already declares that key as %s", doc.name, label)
		}
	}
	target := &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: recipient, Anchor: name}
	keys.Content = append(keys.Content, target)

	if ruleIndex != -1 {
		if err := appendAlias(doc, ruleIndex, name, target); err != nil {
			return "", err
		}
	}
	return doc.emit()
}

// configDocument is a parsed `.sops.yaml` plus what emit() needs to write it
// back the way it was found: the file's own line endings and indent.
type configDocument struct {
	name     string
	root     yaml.Node
	document *yaml.Node
	crlf     bool
}

// loadConfigDocument reads and parses confPath, refusing a file that mixes
// line endings (there is no single right answer for what to emit) and one
// with no top-level mapping.
func loadConfigDocument(confPath string) (*configDocument, error) {
	name := filepath.Base(confPath)
	raw, err := os.ReadFile(confPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", confPath, err)
	}
	crlf := bytes.Count(raw, []byte("\r\n"))
	bareLF := bytes.Count(raw, []byte("\n")) - crlf
	if crlf > 0 && bareLF > 0 {
		return nil, fmt.Errorf("%s mixes line endings, so it is not rewritten here", name)
	}
	doc := &configDocument{name: name, crlf: crlf > 0}
	if err := yaml.Unmarshal(raw, &doc.root); err != nil {
		return nil, fmt.Errorf("could not read %s: %w", name, err)
	}
	doc.document = documentMapping(&doc.root)
	if doc.document == nil {
		return nil, fmt.Errorf("%s declares no creation rules", name)
	}
	return doc, nil
}

func (d *configDocument) emit() (string, error) {
	emitted, err := encodeConfig(&d.root, inferIndent(d.document))
	if err != nil {
		return "", fmt.Errorf("could not write out %s: %w", d.name, err)
	}
	if d.crlf {
		emitted = strings.ReplaceAll(emitted, "\n", "\r\n")
	}
	return emitted, nil
}

// ruleAgeHolder finds creation rule ruleIndex and the mapping whose `age:`
// the rule's recipients live in: the rule itself when it has an `age:`,
// otherwise its single key group. Two groups is a refusal — with several
// there is no single answer to "who gains access", and a rule spelling both
// forms is one this app does not claim to understand well enough to edit.
func ruleAgeHolder(doc *configDocument, ruleIndex int) (holder, rule *yaml.Node, err error) {
	rulesNode := mappingValue(doc.document, "creation_rules")
	if rulesNode == nil || rulesNode.Kind != yaml.SequenceNode {
		return nil, nil, fmt.Errorf("%s declares no creation rules", doc.name)
	}
	if ruleIndex < 0 || ruleIndex >= len(rulesNode.Content) {
		return nil, nil, fmt.Errorf("%s has no creation rule %d", doc.name, ruleIndex)
	}
	rule = rulesNode.Content[ruleIndex]
	if rule.Kind != yaml.MappingNode {
		return nil, nil, fmt.Errorf("creation rule %d in %s is not a rule", ruleIndex, doc.name)
	}
	holder = rule
	if groups := mappingValue(rule, "key_groups"); groups != nil {
		if groups.Kind != yaml.SequenceNode || len(groups.Content) == 0 {
			return nil, nil, fmt.Errorf("creation rule %d in %s declares no usable key group", ruleIndex, doc.name)
		}
		if len(groups.Content) > 1 {
			return nil, nil, fmt.Errorf(
				"creation rule %d in %s has more than one key group, so there is no single place to add a key",
				ruleIndex, doc.name)
		}
		if mappingValue(rule, "age") == nil {
			if groups.Content[0].Kind != yaml.MappingNode {
				return nil, nil, fmt.Errorf("creation rule %d in %s declares no usable key group", ruleIndex, doc.name)
			}
			holder = groups.Content[0]
		}
	}
	return holder, rule, nil
}

// appendAlias is the in-memory core AddAliasRecipient and AddNamedKey share:
// an alias of target (anchored `anchor`) goes to the end of rule ruleIndex's
// age list, unless the rule already names that key in either spelling.
//
// Two spellings of "already there": `*studio` (an alias to the anchor) and
// the literal public key that anchor stands for, written out in the rule —
// what a config looks like when someone pasted the key into the rule by hand
// and declared it under `keys:` afterwards. The rule already grants that
// recipient access, so appending an alias adds an entry that grants nothing
// and leaves the rule reading as if two people can decrypt. Compared through
// scalarOf, which resolves an alias to the scalar behind it.
func appendAlias(doc *configDocument, ruleIndex int, anchor string, target *yaml.Node) error {
	holder, _, err := ruleAgeHolder(doc, ruleIndex)
	if err != nil {
		return err
	}
	age := mappingValue(holder, "age")
	sequence, err := ageSequence(age)
	if err != nil {
		return fmt.Errorf("creation rule %d in %s: %w", ruleIndex, doc.name, err)
	}
	targetValue := ""
	if scalar := scalarOf(target); scalar != nil {
		targetValue = scalar.Value
	}
	for _, item := range sequence.Content {
		if item.Kind == yaml.AliasNode && item.Value == anchor {
			return fmt.Errorf("creation rule %d in %s already names %q", ruleIndex, doc.name, anchor)
		}
		// The value is never quoted into the message: it is the recipient's
		// public key, and a refusal names the anchor instead.
		if targetValue != "" && item.Kind == yaml.ScalarNode && item.Value == targetValue {
			return fmt.Errorf(
				"creation rule %d in %s already names the key %q stands for",
				ruleIndex, doc.name, anchor)
		}
	}
	sequence.Content = append(sequence.Content,
		&yaml.Node{Kind: yaml.AliasNode, Value: anchor, Alias: target})
	setMappingValue(holder, "age", sequence)
	return nil
}

// validateAnchorName applies the rule yaml.v3's *emitter* enforces — ASCII
// letters, digits, `_` and `-` only — rather than the parser's looser one,
// since an anchor the encoder refuses is a config that cannot be written.
func validateAnchorName(name string) error {
	if name == "" {
		return fmt.Errorf("a named key needs a name")
	}
	for _, r := range name {
		ok := (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' || r == '-'
		if !ok {
			return fmt.Errorf("%q is not usable as a YAML anchor name: letters, digits, _ and - only", name)
		}
	}
	return nil
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
