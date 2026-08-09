package gobridge

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/getsops/sops/v3"
)

// exposureLedger answers one question at save time: **would writing this file
// put in plain text something the file on disk was keeping encrypted?**
//
// # Why this is not the obvious check
//
// The obvious check is "for each path, was it encrypted before and is it
// encrypted now". Paths do not survive a change set: removing a list element
// renumbers every later sibling, so half the tree can legitimately change path
// in one save. The first version of this guard compared *values* to avoid
// modelling that — and then built the set of protected values **after** the
// change set had been applied, while keying it off `encryptedPaths`, which
// describes the file as it was read. Every renumbered secret was looked up
// under a path that no longer meant what it used to, found nothing, and the
// guard was left with an empty set and returned success. A user removing one
// item from a list wrote the next one to disk in the clear.
//
// So: built **before** anything mutates the tree, and matched by content.
//
// # Why counting, not membership
//
// A set of protected values refuses too much. A file can legitimately hold the
// same text in one encrypted row and one plaintext row — it arrived that way,
// nothing is being newly exposed, and a membership test refuses every save of
// that file forever, so the user cannot edit an unrelated key ever again.
// Measured, not supposed; it is why this counts occurrences. A value is newly
// exposed only when the output has *more* cleartext copies of it than the input
// did, and only when the input had it encrypted somewhere.
//
// # Why comments are in here
//
// sops encrypts comments — `Tree.walkBranch` runs the comment through the
// cipher — and leaves them out of the MAC entirely (`Tree.Encrypt`: "Only add
// to MAC if not a comment"). So a comment losing its protection is invisible
// both to this app's own leaf walk, which skips comments because the editor has
// no row for them, and to sops's integrity check. A comment is a common place
// for a recovery phrase. A comment written back in the clear is exactly as bad
// as a value.
type exposureLedger struct {
	// How many cleartext copies of each canonical item the input already had.
	publicCounts map[string]int
	// Canonical items the input kept encrypted, mapped to a name for the
	// message. Never holds a value — only where one was.
	secretNames map[string]string
}

// newExposureLedger records the input's state. `wasEncrypted` is keyed by the
// positional keys `collectNodeEncryption` produced *before* decryption; `tree`
// is the same tree after decryption and before any change is applied.
func newExposureLedger(tree *sops.Tree, wasEncrypted map[string]bool) *exposureLedger {
	ledger := &exposureLedger{
		publicCounts: map[string]int{},
		secretNames:  map[string]string{},
	}
	walkAllNodes(tree.Branches, func(positionKey string, name []string, node interface{}) {
		canonical, ok := canonicalNode(node)
		if !ok {
			return
		}
		if wasEncrypted[positionKey] {
			if _, seen := ledger.secretNames[canonical]; !seen {
				ledger.secretNames[canonical] = describePath(name)
			}
			return
		}
		ledger.publicCounts[canonical]++
	})
	return ledger
}

// snapshotBeforeEncrypting records the tree as the change set left it, still in
// plain text. Taken between the last mutation and `EncryptTree`.
//
// This exists so `refuseNewExposure` can tell "still protected" from "written
// in the clear" **exactly**, by asking whether encryption changed the node,
// rather than by asking whether the output looks like ciphertext. Looking is
// not good enough: a secret whose plaintext is itself a well-formed
// `ENC[AES256_GCM,…]` string reads as protected in the output while sitting
// there in the clear. Contrived, and exactly the shape somebody would choose.
func snapshotBeforeEncrypting(tree *sops.Tree) map[string]string {
	snapshot := map[string]string{}
	walkAllNodes(tree.Branches, func(positionKey string, _ []string, node interface{}) {
		if canonical, ok := canonicalNode(node); ok {
			snapshot[positionKey] = canonical
		}
	})
	return snapshot
}

// refuseNewExposure inspects the encrypted output. Anything left in the clear
// there that the input kept encrypted, in more copies than the input already
// had in the clear, is a secret this save would publish.
func (l *exposureLedger) refuseNewExposure(tree *sops.Tree, beforeEncrypting map[string]string) error {
	if len(l.secretNames) == 0 {
		return nil
	}

	cleartextNow := map[string]int{}
	walkAllNodes(tree.Branches, func(positionKey string, _ []string, node interface{}) {
		canonical, ok := canonicalNode(node)
		if !ok {
			return
		}
		// Encryption changed it, so it is ciphertext now. `EncryptTree` never
		// restructures the tree, so the positional key still addresses the same
		// node it did a moment ago.
		if before, known := beforeEncrypting[positionKey]; known && before != canonical {
			return
		}
		cleartextNow[canonical]++
	})

	var exposed []string
	for canonical, count := range cleartextNow {
		name, wasSecret := l.secretNames[canonical]
		if wasSecret && count > l.publicCounts[canonical] {
			exposed = append(exposed, name)
		}
	}
	if len(exposed) == 0 {
		return nil
	}
	sort.Strings(exposed)

	return fmt.Errorf(
		"saving this file would write %s in plain text, because this file's own "+
			"encryption rules no longer cover %s. The file on disk has not been changed",
		strings.Join(exposed, ", "),
		map[bool]string{true: "them", false: "it"}[len(exposed) > 1])
}

// canonicalNode reduces a leaf to a string that distinguishes it from every
// other leaf that is not the same secret.
//
// Type-tagged, because `%v` alone collapses the integer `1` and the string
// `"1"` — and a document full of `true`/`0`/`1` would then have every boolean
// colliding with every other one. Comments live in their own namespace so a
// comment's text cannot be matched against a value's.
//
// Containers are not leaves and return false: an empty map is not a secret.
func canonicalNode(node interface{}) (string, bool) {
	switch typed := node.(type) {
	case sops.Comment:
		return "comment\x00" + typed.Value, true
	case sops.TreeBranch, []interface{}, nil:
		return "", false
	default:
		return fmt.Sprintf("value\x00%T\x00%v", typed, typed), true
	}
}

// nodeIsCiphertext reports whether a node in a tree that has not been decrypted
// yet is ciphertext. `encValueRe` is sops's own recogniser, so a plaintext value
// that merely starts with "ENC[" cannot pass for ciphertext — but a value whose
// plaintext is a *complete* well-formed ENC form can, which is why this is used
// only to classify the input and never to decide whether the output is safe.
// That question is answered against `snapshotBeforeEncrypting`.
func nodeIsCiphertext(node interface{}) bool {
	switch typed := node.(type) {
	case sops.Comment:
		return encValueRe.MatchString(typed.Value)
	case string:
		return encValueRe.MatchString(typed)
	default:
		return false
	}
}

// collectNodeEncryption records, for a tree that has **not** been decrypted
// yet, which nodes are ciphertext — keyed positionally.
//
// Positional, not by key name, because it has to survive being read back after
// decryption, and decryption never restructures the tree. Key names would work
// too; indices are simply the cheaper thing that cannot be confused by a
// duplicate name in a multi-document file.
func collectNodeEncryption(branches sops.TreeBranches) map[string]bool {
	encrypted := map[string]bool{}
	walkAllNodes(branches, func(positionKey string, _ []string, node interface{}) {
		if nodeIsCiphertext(node) {
			encrypted[positionKey] = true
		}
	})
	return encrypted
}

// walkAllNodes visits every leaf **and every comment** in the tree, handing the
// visitor a stable positional key and a human-readable name path.
//
// Separate from `walkLeaves` on purpose. That walk is the editor's: it skips
// comments because a comment is not a row, and it refuses non-string keys
// because a row needs a label. This one is the guard's, it must see everything
// sops can encrypt, and it must never fail — a walk that gives up halfway
// through would hand the guard a partial ledger and call it clean.
func walkAllNodes(branches sops.TreeBranches, visit func(positionKey string, name []string, node interface{})) {
	for document, branch := range branches {
		walkBranchNodes(strconv.Itoa(document), nil, branch, visit)
	}
}

func walkBranchNodes(positionKey string, name []string, branch sops.TreeBranch,
	visit func(string, []string, interface{})) {
	for index, item := range branch {
		itemKey := positionKey + ":" + strconv.Itoa(index)
		if comment, isComment := item.Key.(sops.Comment); isComment {
			visit(itemKey+":k", name, comment)
			continue
		}
		childName := name
		if text, ok := item.Key.(string); ok {
			childName = append(append([]string{}, name...), text)
		}
		walkValueNodes(itemKey, childName, item.Value, visit)
	}
}

func walkValueNodes(positionKey string, name []string, value interface{},
	visit func(string, []string, interface{})) {
	switch typed := value.(type) {
	case sops.TreeBranch:
		walkBranchNodes(positionKey, name, typed, visit)
	case []interface{}:
		for index, element := range typed {
			walkValueNodes(positionKey+"."+strconv.Itoa(index),
				append(append([]string{}, name...), strconv.Itoa(index)), element, visit)
		}
	default:
		visit(positionKey, name, typed)
	}
}

// describePath names a key in a refusal message, safely.
//
// The document is attacker-controlled under this project's threat model, and a
// YAML key can be arbitrarily long and can contain newlines (an explicit `? |-`
// key) or terminal control characters. Unsanitised, a key name can make the
// refusal render as its own paragraph — a hostile file was made to produce a
// refusal reading "Saved. Your changes are on disk." Control characters are
// escaped and the whole thing is bounded.
func describePath(name []string) string {
	if len(name) == 0 {
		return "a value in this file"
	}
	var builder strings.Builder
	for index, component := range strings.Join(name, ".") {
		if index >= 120 {
			builder.WriteString("…")
			break
		}
		if component < 0x20 || component == 0x7f {
			builder.WriteString(strconv.QuoteRune(component))
			continue
		}
		builder.WriteRune(component)
	}
	return builder.String()
}
