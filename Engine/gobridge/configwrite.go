package gobridge

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strings"

	"go.yaml.in/yaml/v3"
)

// ConfigRecipientUpdate is the answer to one question: for the .sops.yaml
// creation rule that governs a given file, can this app rewrite its age
// recipient list, and if so what would the whole file then look like?
//
// It is a *proposal*, never an action. See UpdateConfigRecipients.
type ConfigRecipientUpdate struct {
	// Writable is true when the governing rule is a flat, age-only rule this
	// app fully understands, so Config can be written over the existing
	// .sops.yaml. False for every shape listed in UpdateConfigRecipients's
	// doc comment, and then Reason says which one was found.
	Writable bool `json:"writable"`
	// Reason is a complete sentence for a user: what shape was found and what
	// they can do instead. Empty exactly when Writable is true. It never
	// contains a private identity or any document content — only backend
	// names, YAML key names and fixed prose.
	Reason string `json:"reason"`
	// RuleIndex is the position of the governing rule in the config's
	// creation_rules list, or -1 when no rule governs the target file. It is
	// what makes MatchedFiles meaningful: "the same rule" is an index, not a
	// resemblance between two key lists.
	RuleIndex int `json:"ruleIndex"`
	// CurrentRecipients are the age public keys that rule resolves to *today*,
	// taken from sops's own config parser (LookupCreationRule), not from the
	// node tree this type edits. Empty (never nil) when no rule matched.
	CurrentRecipients []string `json:"currentRecipients"`
	// MatchedFiles are the candidate paths handed in that the same rule
	// governs, in the order they were given. Empty (never nil) when no rule
	// matched or no candidates were supplied.
	MatchedFiles []string `json:"matchedFiles"`
	// Changed is true when Config differs from what is on disk. False when the
	// rule already declares exactly the requested set — in which case Config
	// is the file's current text, so a caller that writes anyway writes the
	// same bytes — and false for an inspection.
	Changed bool `json:"changed"`
	// Config is the complete proposed .sops.yaml text. Empty when Writable is
	// false (a refusal must not hand back something a caller could write) and
	// empty for an inspection, which proposes nothing.
	Config string `json:"config"`
}

// UpdateConfigRecipients computes what the .sops.yaml at confPath would look
// like if the creation rule governing targetFile declared exactly recipients
// as its age recipient list.
//
// # It never writes anything
//
// Not the config, not a staging file, not a temp file beside it — verified by
// TestUpdateConfigRecipients_NeverTouchesTheConfigOnDisk, which asserts the
// config's own directory gains no entries. Changing who can read a project's
// secrets is an explicit, separately confirmed user action, so the bridge is
// structurally incapable of performing it: it can only compute the text, and
// the Swift side writes it through AtomicFileWriter after the user says so.
//
// # Why this parses the config directly, and why that is not a second parser
//
// ADR 0002 bans hand-rolled YAML parsing on either side of this bridge, after
// three consecutive rounds of a hand-rolled Swift scanner each shipped a
// different silent-corruption bug. Nothing here scans lines, counts brackets
// or tracks indentation. The file is parsed twice, by the same real parser
// sops itself uses at this pinned version (go.yaml.in/yaml/v3 v3.0.4, see
// config/config.go's own import):
//
//   - into a yaml.Node tree, because a node tree is the only representation
//     that carries the user's comments, key order and quoting through a
//     re-encode. Unmarshalling into a struct and re-marshalling it would
//     silently delete every comment in the file and reorder every key.
//   - into the narrow writeConfigFile struct below, which mirrors nothing but
//     the fields of config.creationRule in getsops/sops v3.13.3 that decide
//     this question. That struct is what the rule *selection* runs over, so
//     selection sees exactly the values sops sees.
//
// And the result is then checked against sops's own answer:
// LookupCreationRule (config.LoadCreationRuleForFile end to end) must resolve
// the same age recipients and no non-age backends for the same file, or the
// write is refused. Two independent readings have to agree before anything is
// proposed.
//
// # Selecting the rule
//
// config.LoadCreationRuleForFile answers "which keys govern this file", not
// "which entry of the list said so", and configFile/creationRule are
// unexported, so the index has to be established here. It is established by
// running sops's own selection — parseCreationRuleForFile in
// getsops/sops v3.13.3 config/config.go, lines 570-600 — over the values sops
// itself decodes: strip the config's own directory from the target path as a
// literal prefix, then take the first rule with an empty path_regex or a
// path_regex that matches. That is a transcription of twelve lines of
// non-YAML logic (a TrimPrefix and a regexp), not a second parser, and three
// things stop a divergence in it from ever reaching the user's file:
//
//  1. the node list and the decoded list must have the same length;
//  2. the selected rule's path_regex must read the same in the node tree and
//     in the decoded struct;
//  3. the selected rule's age list must equal what sops resolved for the same
//     file, and sops must have resolved no non-age backend.
//
// # Shapes this refuses, all of them read-only rather than guessed at
//
// Only a flat, age-only creation rule is rewritten. Everything below comes
// back Writable = false with a Reason naming what was found:
//
//   - the rule uses key_groups (this app cannot know which group a recipient
//     belongs to);
//   - the rule sets shamir_threshold;
//   - the rule also uses pgp, kms, gcp_kms, hckms, azure_kv or hc_vault;
//   - the rule, or anything inside it, carries a YAML anchor or alias (its
//     key list may be shared with rules this call was not asked about);
//   - the document uses merge keys (<<) anywhere — yaml.v3 re-emits them as
//     `!!merge <<`, which is a change to a part of the file nobody asked to
//     change;
//   - the file holds more than one YAML document (sops reads only the first,
//     and a re-encode would delete the rest);
//   - the file mixes CRLF and LF line endings, so there is no answer to
//     "which one should the new lines use";
//   - creation_rules is missing, is not a sequence of mappings, or no rule
//     governs the target file. The shape check runs on the node tree *before*
//     the narrow struct decode, so a `creation_rules:` holding a mapping or a
//     list of scalars produces that sentence rather than a decode error naming
//     one of this package's own Go types;
//   - the two readings above disagree (see readingsDisagree — a net nothing
//     that can be written as a .sops.yaml reaches).
//
// # What a rewrite preserves, and what it cannot
//
// Preserved — and pinned by an exact, byte-for-byte expected document in
// TestUpdateConfigRecipients_RewriteIsByteForByteExceptTheAgeList, not by
// substring checks that a reordering or a re-indentation would slip through:
// every other creation rule and every other top-level key, verbatim; comments,
// including the trailing comment on a recipient that survives the change and
// the trailing comment of a scalar `age:` whose recipient survives into the new
// list; key order; quoting style; flow-vs-block style of the age list itself;
// the file's indentation width, inferred from the node tree's own column
// information; CRLF line endings.
//
// Not preserved, because a yaml.Node re-encode cannot — the node tree carries
// no blank-line information at all, in any position:
//
//   - blank lines between entries, including one immediately before a comment;
//   - the leading `---` document marker;
//   - the exact column a trailing comment was aligned to;
//   - a sequence written flush with its key (`creation_rules:` then `- …` at
//     column 1), which comes back indented because the encoder cannot emit the
//     flush form;
//   - the trailing comment of a recipient that is *removed* by the change,
//     which goes with the key it labelled — that one is the right answer
//     rather than a loss.
//
// These are visible, harmless formatting changes, and the caller is obliged to
// say so before the user commits: `.sops.yaml` is almost always in version
// control, and a surprise diff is exactly the "changed a part of it nobody
// asked to change" this file refuses a whole config over elsewhere (see
// reasonMergeKeys). The Swift confirmation dialog
// (`project-access.update-config-confirm.message`) states it. The alternative
// — splicing text by line number so the untouched lines are literally
// untouched — is the class of edit ADR 0002 exists to keep out of this
// codebase: computing a node's *end* means guessing where the next node's head
// comment begins.
//
// candidates, if given, are absolute paths to classify: MatchedFiles comes
// back holding the ones the same rule governs. They are only ever read as
// path strings; nothing is opened.
func UpdateConfigRecipients(
	confPath string, targetFile string, recipients []string, candidates []string,
) (*ConfigRecipientUpdate, error) {
	// An empty list is the *inspect* call: answer everything except the
	// proposed text. A panel has to be able to show what the config declares
	// and whether it could be rewritten before the user has staged anything —
	// and asking that question must not require inventing a recipient set to
	// ask it with. Nothing else about the call changes: every shape check
	// below still runs, so "this rule is read-only, here is why" is available
	// from the first read.
	inspectOnly := len(recipients) == 0

	// The same guards Task 1's rewrap applies, with the same fixed,
	// value-free error text: an invalid recipient is a caller mistake, not a
	// config shape, so it is an error rather than a refusal.
	var wanted []string
	if !inspectOnly {
		validated, err := validAgeRecipients(recipients)
		if err != nil {
			return nil, err
		}
		wanted = validated
	}

	raw, err := os.ReadFile(confPath)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", confPath, err)
	}

	crlf := bytes.Count(raw, []byte("\r\n"))
	bareLF := bytes.Count(raw, []byte("\n")) - crlf
	if crlf > 0 && bareLF > 0 {
		return refuse(reasonMixedLineEndings), nil
	}

	documents, err := countYAMLDocuments(raw)
	if err != nil {
		return nil, fmt.Errorf("could not read %s: %w", filepath.Base(confPath), err)
	}
	if documents > 1 {
		return refuse(reasonMultipleDocuments), nil
	}

	var root yaml.Node
	if err := yaml.Unmarshal(raw, &root); err != nil {
		return nil, fmt.Errorf("could not read %s: %w", filepath.Base(confPath), err)
	}

	// The node tree is checked for the *shape* of creation_rules before the
	// narrow struct decode below, and the order is the whole point. Decoding
	// first meant a `creation_rules:` holding a mapping, a scalar, or a list of
	// scalars never reached reasonCreationRulesNotAList at all: the decode
	// failed and the user was shown `cannot unmarshal !!map into
	// []gobridge.writeCreationRule` — this package's own Go type name — as a
	// hard read error, instead of the sentence that says what was found and
	// what to do about it.
	document := documentMapping(&root)
	if document == nil {
		// No mapping at the top: an empty file, a comment-only file, or a
		// document that is not a mapping at all. None of them declares a
		// creation rule, which is exactly what sops concludes too
		// (parseCreationRuleForFile: `if conf.CreationRules == nil { return
		// nil, nil }`).
		return refuse(reasonNoCreationRules), nil
	}
	rulesNode := mappingValue(document, "creation_rules")
	if rulesNode == nil || rulesNode.Tag == "!!null" {
		return refuse(reasonNoCreationRules), nil
	}
	if !isRuleList(rulesNode) {
		return refuse(reasonCreationRulesNotAList), nil
	}

	var decoded writeConfigFile
	if err := yaml.Unmarshal(raw, &decoded); err != nil {
		return nil, fmt.Errorf("could not read %s: %w", filepath.Base(confPath), err)
	}

	if len(decoded.CreationRules) == 0 {
		return refuse(reasonNoCreationRules), nil
	}

	absTarget, err := filepath.Abs(targetFile)
	if err != nil {
		return nil, fmt.Errorf("resolve target file path: %w", err)
	}
	configDir, err := filepath.Abs(filepath.Dir(confPath))
	if err != nil {
		return nil, fmt.Errorf("resolve config directory: %w", err)
	}

	index, err := matchingRuleIndex(decoded.CreationRules, configDir, absTarget)
	if err != nil {
		return nil, err
	}
	if index < 0 {
		return refuse(reasonNoMatchingRule), nil
	}

	// sops's own answer for this file, which is what CurrentRecipients
	// reports and what the node tree is checked against below.
	lookup, err := LookupCreationRule(confPath, absTarget)
	if err != nil {
		return nil, err
	}

	result := &ConfigRecipientUpdate{
		RuleIndex:         index,
		CurrentRecipients: lookup.AgeRecipients,
		MatchedFiles:      filesGovernedBy(index, decoded.CreationRules, configDir, candidates),
	}
	if result.CurrentRecipients == nil {
		result.CurrentRecipients = []string{}
	}

	if lookup.Matched && len(lookup.NonAgeBackends) > 0 {
		return result.refusing(reasonOtherBackends(lookup.NonAgeBackends)), nil
	}

	rule := decoded.CreationRules[index]
	if len(rule.KeyGroups) > 0 {
		return result.refusing(reasonKeyGroups), nil
	}
	if rule.ShamirThreshold != 0 {
		return result.refusing(reasonShamir), nil
	}

	// Before the node/struct cross-check, because a merged rule legitimately
	// reads differently in the two views — the decode resolves `<<` and the
	// node does not — and "this file uses merge keys" is the useful thing to
	// say about it, not "the two readings disagreed".
	if containsMergeKey(document) {
		return result.refusing(reasonMergeKeys), nil
	}

	if readingsDisagree(rulesNode, decoded.CreationRules, index, lookup) {
		return result.refusing(reasonRuleDisagreement), nil
	}
	// Safe to index: readingsDisagree has already established that the node
	// list and the decoded list are the same length and that `index` is inside
	// both of them.
	ruleNode := rulesNode.Content[index]
	if containsAnchorOrAlias(ruleNode) {
		return result.refusing(reasonAnchors), nil
	}
	// Also established by readingsDisagree, which refuses an age field neither
	// reading can make sense of.
	declared, _ := parseAgeField(rule.Age)

	result.Writable = true
	if inspectOnly {
		// Nothing was proposed, so there is nothing to hand back. Writable and
		// CurrentRecipients and MatchedFiles are the whole answer.
		return result, nil
	}
	if equalSets(declared, wanted) {
		// Nothing to write. Handing back the file's own text keeps the
		// contract simple for a caller that writes unconditionally: it writes
		// the same bytes.
		result.Config = string(raw)
		return result, nil
	}

	ageNode := mappingValue(ruleNode, "age")
	setMappingValue(ruleNode, "age", newAgeNode(ageNode, wanted))

	emitted, err := encodeConfig(&root, inferIndent(document))
	if err != nil {
		return nil, fmt.Errorf("could not write out %s: %w", filepath.Base(confPath), err)
	}
	if crlf > 0 {
		emitted = strings.ReplaceAll(emitted, "\n", "\r\n")
	}

	// Last line of defence: read the proposal back with the same decoder and
	// prove that exactly one thing about it differs from the original.
	if !onlyTheAgeListChanged(raw, emitted, decoded, index, wanted) {
		return result.refusing(reasonRewriteChangedSomethingElse), nil
	}

	result.Changed = true
	result.Config = emitted
	return result, nil
}

// UpdateConfigRecipientsJSON is UpdateConfigRecipients for the C boundary,
// which can only carry strings: recipients and candidates arrive as JSON
// string arrays, and on success the result is the JSON encoding of a
// ConfigRecipientUpdate. Errors are returned as-is for cshim to relay as the
// failure branch of its 0/1 result convention.
func UpdateConfigRecipientsJSON(
	confPath string, targetFile string, recipientsJSON []byte, candidatesJSON []byte,
) ([]byte, error) {
	var recipients []string
	if err := json.Unmarshal(recipientsJSON, &recipients); err != nil {
		return nil, errors.New("the recipient list is not valid JSON")
	}
	var candidates []string
	if len(bytes.TrimSpace(candidatesJSON)) > 0 {
		if err := json.Unmarshal(candidatesJSON, &candidates); err != nil {
			return nil, errors.New("the candidate file list is not valid JSON")
		}
	}
	update, err := UpdateConfigRecipients(confPath, targetFile, recipients, candidates)
	if err != nil {
		return nil, err
	}
	return json.Marshal(update)
}

// MARK: - Refusal reasons
//
// Every one of these is a whole sentence a user reads in a dialog, naming the
// shape that was found and what they can do about it. None of them can carry
// a key, an identity or any document content: they are constants, or are
// built from a fixed table of backend names.

const (
	reasonNoCreationRules = "This project's .sops.yaml declares no creation_rules, so there is no rule to " +
		"update. Add a creation rule whose path_regex matches these files, then try again."
	reasonNoMatchingRule = "No creation rule in this project's .sops.yaml governs these files, so there is " +
		"nothing to update. Add a creation rule whose path_regex matches them, then try again."
	reasonCreationRulesNotAList = "The creation_rules entry in this project's .sops.yaml is not a list of " +
		"rules, so this app cannot tell which rule governs these files. Edit .sops.yaml by hand."
	reasonKeyGroups = "The matching creation rule uses key_groups, which splits its keys into separate " +
		"groups. This app only rewrites a rule with a single flat list of age recipients, because it " +
		"cannot know which group a recipient belongs in. Edit .sops.yaml by hand to change this rule."
	reasonShamir = "The matching creation rule sets shamir_threshold, which needs several key groups to " +
		"reconstruct the data key. This app only rewrites a rule with a single flat list of age " +
		"recipients. Edit .sops.yaml by hand to change this rule."
	reasonAnchors = "The matching creation rule uses a YAML anchor or alias, so its key list may be shared " +
		"with other rules in the same file. This app will not rewrite it, because it cannot tell what " +
		"else would change. Edit .sops.yaml by hand to change this rule."
	reasonMergeKeys = "This project's .sops.yaml uses YAML merge keys (<<). Rewriting the file would " +
		"re-spell them, changing a part of it nobody asked to change, so this app leaves it alone. " +
		"Write the merged values into the rule itself, or edit .sops.yaml by hand."
	reasonMultipleDocuments = "This project's .sops.yaml holds more than one YAML document. sops reads only " +
		"the first, and rewriting the file here would delete the rest, so this app leaves it alone. Move " +
		"the extra documents into their own file, or edit .sops.yaml by hand."
	reasonMixedLineEndings = "This project's .sops.yaml mixes CRLF and LF line endings, so this app cannot " +
		"tell which one new lines should use. Give the file one kind of line ending, then try again."
	reasonRuleDisagreement = "This app read this project's .sops.yaml two ways and they did not agree about " +
		"which creation rule governs these files, so it will not rewrite any of it. Edit .sops.yaml by hand."
	reasonRewriteChangedSomethingElse = "Rewriting the matching creation rule would have changed something " +
		"else in this project's .sops.yaml as well, so nothing was written. Edit .sops.yaml by hand."
)

// backendNames turns the sops master-key type identifiers LookupCreationRule
// speaks into the names a user would recognize from their own config file.
var backendNames = map[string]string{
	"pgp":      "pgp",
	"kms":      "kms (AWS KMS)",
	"gcp_kms":  "gcp_kms",
	"hckms":    "hckms",
	"azure_kv": "azure_keyvault",
	"hc_vault": "hc_vault",
}

func reasonOtherBackends(identifiers []string) string {
	named := make([]string, 0, len(identifiers))
	for _, id := range identifiers {
		if name, ok := backendNames[id]; ok {
			named = append(named, name)
		} else {
			named = append(named, id)
		}
	}
	sort.Strings(named)
	return "The matching creation rule also uses " + joinWithAnd(named) + ". This app manages native age " +
		"recipients only, and rewriting just the age half of a mixed rule would change who can read " +
		"these files in a way it cannot describe. Edit .sops.yaml by hand to change this rule."
}

func joinWithAnd(names []string) string {
	switch len(names) {
	case 0:
		return "another key backend"
	case 1:
		return names[0]
	default:
		return strings.Join(names[:len(names)-1], ", ") + " and " + names[len(names)-1]
	}
}

func refuse(reason string) *ConfigRecipientUpdate {
	return &ConfigRecipientUpdate{
		RuleIndex:         -1,
		Reason:            reason,
		CurrentRecipients: []string{},
		MatchedFiles:      []string{},
	}
}

// refusing turns a partially populated result — one that already knows which
// rule governs the file and which files that rule covers — into a refusal.
// The context is kept deliberately: a user reading "this rule also uses pgp"
// is better served by still seeing which files it governs.
func (u *ConfigRecipientUpdate) refusing(reason string) *ConfigRecipientUpdate {
	u.Writable = false
	u.Changed = false
	u.Config = ""
	u.Reason = reason
	return u
}

// MARK: - The narrow decode
//
// These types mirror only the fields of config.configFile / config.creationRule
// in getsops/sops v3.13.3 that this question needs, under the exact YAML keys
// sops itself declares. They read presence and value, never meaning: no key is
// resolved into a master key here — LookupCreationRule does that, with sops's
// own code, and this is checked against it.

type writeConfigFile struct {
	CreationRules []writeCreationRule `yaml:"creation_rules"`
}

type writeCreationRule struct {
	PathRegex string `yaml:"path_regex"`
	// `any` for the same reason sops declares it `interface{} // string or
	// []string`: a value may be a scalar, a comma-joined string, or a list.
	Age             any   `yaml:"age"`
	KeyGroups       []any `yaml:"key_groups"`
	ShamirThreshold int   `yaml:"shamir_threshold"`
	// Everything else in the rule, kept so that the verification step below
	// can prove a rewrite changed nothing but `age`. Order and names follow
	// config.creationRule.
	KMS                     any    `yaml:"kms"`
	AwsProfile              string `yaml:"aws_profile"`
	PGP                     any    `yaml:"pgp"`
	GCPKMS                  any    `yaml:"gcp_kms"`
	HCKms                   any    `yaml:"hckms"`
	AzureKeyVault           any    `yaml:"azure_keyvault"`
	VaultURI                any    `yaml:"hc_vault_transit_uri"`
	UnencryptedSuffix       string `yaml:"unencrypted_suffix"`
	EncryptedSuffix         string `yaml:"encrypted_suffix"`
	UnencryptedRegex        string `yaml:"unencrypted_regex"`
	EncryptedRegex          string `yaml:"encrypted_regex"`
	UnencryptedCommentRegex string `yaml:"unencrypted_comment_regex"`
	EncryptedCommentRegex   string `yaml:"encrypted_comment_regex"`
	MACOnlyEncrypted        bool   `yaml:"mac_only_encrypted"`
}

// parseAgeField reads an `age:` value the way sops's own parseKeyField does —
// a scalar is comma-separated, a list is a list — and reports false for a
// shape sops itself would reject.
func parseAgeField(field any) ([]string, bool) {
	switch v := field.(type) {
	case nil:
		return []string{}, true
	case string:
		out := []string{}
		for _, part := range strings.Split(v, ",") {
			if trimmed := strings.TrimSpace(part); trimmed != "" {
				out = append(out, trimmed)
			}
		}
		return out, true
	case []any:
		out := make([]string, 0, len(v))
		for _, item := range v {
			s, ok := item.(string)
			if !ok {
				return nil, false
			}
			out = append(out, s)
		}
		return out, true
	default:
		return nil, false
	}
}

// matchingRuleIndex is parseCreationRuleForFile's own selection, run over the
// values sops decodes: getsops/sops v3.13.3 config/config.go lines 570-600.
// See UpdateConfigRecipients's doc comment for why the index has to be
// established here at all and what stops a divergence from reaching a file.
func matchingRuleIndex(rules []writeCreationRule, configDir string, absTarget string) (int, error) {
	relative := strings.TrimPrefix(absTarget, configDir+string(filepath.Separator))
	for i, rule := range rules {
		if rule.PathRegex == "" {
			return i, nil
		}
		expression, err := regexp.Compile(rule.PathRegex)
		if err != nil {
			return -1, fmt.Errorf("can not compile regexp: %w", err)
		}
		if expression.MatchString(relative) {
			return i, nil
		}
	}
	return -1, nil
}

func filesGovernedBy(index int, rules []writeCreationRule, configDir string, candidates []string) []string {
	matched := []string{}
	for _, candidate := range candidates {
		absolute, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		found, err := matchingRuleIndex(rules, configDir, absolute)
		if err != nil {
			continue
		}
		if found == index {
			matched = append(matched, candidate)
		}
	}
	return matched
}

// readingsDisagree reports whether the two readings of this config — the node
// tree this type edits, and the narrow struct decode the rule selection ran
// over — fail to agree about the rule at `index`, or fail to agree with what
// sops's own loader resolved for the same file.
//
// It is the guard that makes editing the *wrong* rule impossible rather than
// merely unlikely: see UpdateConfigRecipients's doc comment for why the rule
// index has to be established here at all. Every caller of it treats `true` as
// a refusal, never as something to work around.
//
// Its own function, and not inlined, because nothing that can be built as a
// `.sops.yaml` reaches it: every shape that could make the two readings differ
// is caught by an earlier check, or by sops's own loader, first. That is what a
// defensive net is for, and it is also why this is tested directly rather than
// through a fixture that cannot exist — see
// TestReadingsDisagree_DetectsEachWayTheTwoReadingsCanDiffer.
func readingsDisagree(
	rulesNode *yaml.Node, rules []writeCreationRule, index int, lookup *CreationRuleLookup,
) bool {
	if lookup == nil || !lookup.Matched {
		return true
	}
	if rulesNode == nil || index < 0 || index >= len(rules) {
		return true
	}
	// The node list and the decoded list must be the same list.
	if len(rulesNode.Content) != len(rules) || index >= len(rulesNode.Content) {
		return true
	}
	ruleNode := rulesNode.Content[index]
	if ruleNode.Kind != yaml.MappingNode {
		return true
	}
	rule := rules[index]
	// The rule about to be edited must be the one sops selected.
	if nodeScalar(mappingValue(ruleNode, "path_regex")) != rule.PathRegex {
		return true
	}
	declared, ok := parseAgeField(rule.Age)
	if !ok {
		return true
	}
	return !equalSets(declared, lookup.AgeRecipients)
}

// onlyTheAgeListChanged re-reads the proposed text and proves that the only
// difference from the original is the selected rule's age list, now holding
// exactly `wanted`.
//
// Two comparisons, because one is not enough. Every *creation rule* is checked
// field by field against the narrow struct decode; and every *other top-level
// key* — `stores:`, `destination_rules:`, and anything this app has never heard
// of — is checked through a generic `map[string]any` decode, so the guard's
// coverage is the whole document rather than only the part this type models.
func onlyTheAgeListChanged(
	raw []byte, emitted string, before writeConfigFile, index int, wanted []string,
) bool {
	var after writeConfigFile
	if err := yaml.Unmarshal([]byte(emitted), &after); err != nil {
		return false
	}
	if len(after.CreationRules) != len(before.CreationRules) {
		return false
	}
	for i := range before.CreationRules {
		was, now := before.CreationRules[i], after.CreationRules[i]
		if i == index {
			declared, ok := parseAgeField(now.Age)
			if !ok || !equalSets(declared, wanted) {
				return false
			}
			was.Age, now.Age = nil, nil
		}
		if !reflect.DeepEqual(was, now) {
			return false
		}
	}
	return everythingButCreationRulesIsIdentical(raw, []byte(emitted))
}

// everythingButCreationRulesIsIdentical decodes both documents generically —
// no narrow struct, so no top-level key can fall outside the comparison the way
// it did when this guard modelled `creation_rules` alone — and compares
// everything except `creation_rules`, which its caller checks rule by rule.
func everythingButCreationRulesIsIdentical(before []byte, after []byte) bool {
	strip := func(raw []byte) (map[string]any, bool) {
		var document map[string]any
		if err := yaml.Unmarshal(raw, &document); err != nil {
			return nil, false
		}
		delete(document, "creation_rules")
		return document, true
	}
	was, ok := strip(before)
	if !ok {
		return false
	}
	now, ok := strip(after)
	if !ok {
		return false
	}
	return reflect.DeepEqual(was, now)
}

// isRuleList reports whether a `creation_rules:` node is what sops needs it to
// be — a sequence whose every entry is a mapping. Anything else is a config
// shape this app refuses rather than one it fails to decode; see the call site.
func isRuleList(node *yaml.Node) bool {
	if node.Kind != yaml.SequenceNode {
		return false
	}
	for _, item := range node.Content {
		if item.Kind != yaml.MappingNode {
			return false
		}
	}
	return true
}

// MARK: - Node tree helpers
//
// Positions, styles and comments come from the parser. Nothing below reads the
// file as text.

func documentMapping(root *yaml.Node) *yaml.Node {
	if root == nil || root.Kind != yaml.DocumentNode || len(root.Content) == 0 {
		return nil
	}
	if root.Content[0].Kind != yaml.MappingNode {
		return nil
	}
	return root.Content[0]
}

func mappingValue(mapping *yaml.Node, key string) *yaml.Node {
	if mapping == nil || mapping.Kind != yaml.MappingNode {
		return nil
	}
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return mapping.Content[i+1]
		}
	}
	return nil
}

// setMappingValue replaces `key`'s value in place, or appends the pair at the
// end of the mapping when the key is not there yet.
func setMappingValue(mapping *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			mapping.Content[i+1] = value
			return
		}
	}
	mapping.Content = append(
		mapping.Content,
		&yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key},
		value)
}

func nodeScalar(node *yaml.Node) string {
	if node == nil || node.Kind != yaml.ScalarNode {
		return ""
	}
	return node.Value
}

func containsAnchorOrAlias(node *yaml.Node) bool {
	if node == nil {
		return false
	}
	if node.Kind == yaml.AliasNode || node.Anchor != "" {
		return true
	}
	for _, child := range node.Content {
		if containsAnchorOrAlias(child) {
			return true
		}
	}
	return false
}

func containsMergeKey(node *yaml.Node) bool {
	if node == nil {
		return false
	}
	if node.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(node.Content); i += 2 {
			if node.Content[i].Value == "<<" || node.Content[i].Tag == "!!merge" {
				return true
			}
		}
	}
	for _, child := range node.Content {
		if containsMergeKey(child) {
			return true
		}
	}
	return false
}

// newAgeNode builds the replacement value for a rule's `age:` key, keeping as
// much of how the user wrote it as the new list allows.
//
//   - an existing block or flow list stays that style, and an entry that
//     survives the change keeps its own node — so `- age1… # alice` keeps its
//     comment;
//   - a scalar stays a scalar when one recipient is left, and becomes a block
//     list when there is more than one, rather than a comma-joined line no
//     one can read (sops accepts both — config.parseKeyField splits a scalar
//     on commas). A scalar's *trailing* comment labels the recipient written
//     on that line, so when that recipient survives into the new list the
//     comment travels onto its entry; when it does not, the comment goes with
//     the key it labelled, which is the right answer rather than a loss. (An
//     earlier version copied `LineComment` only from an existing *sequence*,
//     so `age: age1… # alice` growing to two recipients dropped `# alice`
//     silently.)
//   - a rule that had no `age:` at all gets a block list.
func newAgeNode(existing *yaml.Node, recipients []string) *yaml.Node {
	if existing != nil && existing.Kind == yaml.ScalarNode && len(recipients) == 1 {
		replacement := *existing
		// A trailing comment labels the recipient that *was* on this line. If
		// the line is now a different recipient, the comment does not belong
		// to it: keeping it would leave "# alice" pointing at bob's key, which
		// is worse than losing it. Caught by
		// TestUpdateConfigRecipients_ACommentGoesWithTheRecipientItLabels.
		if replacement.Value != recipients[0] {
			replacement.LineComment = ""
		}
		replacement.Value = recipients[0]
		replacement.Tag = "!!str"
		return &replacement
	}

	style := yaml.Style(0)
	reusable := map[string]*yaml.Node{}
	// The trailing comment of a scalar `age:` and the recipients that scalar
	// named, so the comment can be re-attached below to whichever of them
	// survives. Empty unless `existing` is a scalar.
	scalarComment := ""
	var scalarValues []string
	if existing != nil {
		switch existing.Kind {
		case yaml.SequenceNode:
			style = existing.Style
			for _, item := range existing.Content {
				if item.Kind == yaml.ScalarNode {
					reusable[item.Value] = item
				}
			}
		case yaml.ScalarNode:
			scalarComment = existing.LineComment
			scalarValues, _ = parseAgeField(existing.Value)
		}
	}

	sequence := &yaml.Node{Kind: yaml.SequenceNode, Tag: "!!seq", Style: style}
	if existing != nil {
		sequence.HeadComment = existing.HeadComment
		sequence.FootComment = existing.FootComment
		if existing.Kind == yaml.SequenceNode {
			sequence.LineComment = existing.LineComment
		}
	}
	for _, recipient := range recipients {
		if kept, ok := reusable[recipient]; ok {
			sequence.Content = append(sequence.Content, kept)
			continue
		}
		item := &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: recipient}
		// A comma-joined scalar can name several recipients under one comment;
		// the comment follows the first of them that survives, and is used at
		// most once.
		if scalarComment != "" && len(scalarValues) > 0 && scalarValues[0] == recipient {
			item.LineComment = scalarComment
			scalarComment = ""
		}
		sequence.Content = append(sequence.Content, item)
	}
	return sequence
}

// inferIndent reads the file's indentation width off the parser's own column
// information, so a two-space config does not come back four-space. Falls back
// to two — the width sops's own documentation uses — when the document offers
// no block collection to measure, or measures zero (a sequence written flush
// with its key, which the encoder cannot reproduce anyway).
func inferIndent(document *yaml.Node) int {
	if width := indentUnder(document, "creation_rules"); width > 0 {
		return width
	}
	var found int
	var walk func(*yaml.Node)
	walk = func(node *yaml.Node) {
		if node == nil || found > 0 {
			return
		}
		if node.Kind == yaml.MappingNode {
			for i := 0; i+1 < len(node.Content); i += 2 {
				if width := blockIndent(node.Content[i], node.Content[i+1]); width > 0 {
					found = width
					return
				}
			}
		}
		for _, child := range node.Content {
			walk(child)
		}
	}
	walk(document)
	if found >= 1 && found <= 9 {
		return found
	}
	return 2
}

func indentUnder(mapping *yaml.Node, key string) int {
	if mapping == nil || mapping.Kind != yaml.MappingNode {
		return 0
	}
	for i := 0; i+1 < len(mapping.Content); i += 2 {
		if mapping.Content[i].Value == key {
			return blockIndent(mapping.Content[i], mapping.Content[i+1])
		}
	}
	return 0
}

func blockIndent(key *yaml.Node, value *yaml.Node) int {
	if value == nil || len(value.Content) == 0 {
		return 0
	}
	if value.Kind != yaml.MappingNode && value.Kind != yaml.SequenceNode {
		return 0
	}
	if value.Style&yaml.FlowStyle != 0 {
		return 0
	}
	if value.Line == key.Line {
		return 0
	}
	width := value.Column - key.Column
	if width < 1 || width > 9 {
		return 0
	}
	return width
}

func encodeConfig(root *yaml.Node, indent int) (string, error) {
	var buffer bytes.Buffer
	encoder := yaml.NewEncoder(&buffer)
	encoder.SetIndent(indent)
	if err := encoder.Encode(root); err != nil {
		return "", err
	}
	if err := encoder.Close(); err != nil {
		return "", err
	}
	return buffer.String(), nil
}

// countYAMLDocuments reports how many YAML documents the file holds, using the
// same decoder rather than looking for `---` in the text.
func countYAMLDocuments(raw []byte) (int, error) {
	decoder := yaml.NewDecoder(bytes.NewReader(raw))
	count := 0
	for {
		var document yaml.Node
		err := decoder.Decode(&document)
		if errors.Is(err, io.EOF) {
			return count, nil
		}
		if err != nil {
			return 0, err
		}
		count++
	}
}

// MARK: - Small shared helpers

// validAgeRecipients runs the supplied list through the same guards Task 1's
// rewrap uses — native age public keys only, no private identity, no plugin
// recipient — and returns it deduplicated with the caller's order intact.
func validAgeRecipients(recipients []string) ([]string, error) {
	keys, err := nativeAgeMasterKeys(recipients)
	if err != nil {
		return nil, err
	}
	seen := map[string]bool{}
	out := make([]string, 0, len(keys))
	for _, key := range keys {
		if seen[key.Recipient] {
			continue
		}
		seen[key.Recipient] = true
		out = append(out, key.Recipient)
	}
	return out, nil
}

func equalSets(a []string, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	left, right := append([]string(nil), a...), append([]string(nil), b...)
	sort.Strings(left)
	sort.Strings(right)
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}
