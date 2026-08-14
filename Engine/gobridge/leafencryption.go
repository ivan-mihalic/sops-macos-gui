package gobridge

import (
	"encoding/json"
	"errors"
	"regexp"

	"github.com/getsops/sops/v3"
	"github.com/getsops/sops/v3/cmd/sops/common"
	"github.com/getsops/sops/v3/config"
)

// LeafEncryptionSummary reports how many of a SOPS document's leaves are
// genuinely ciphertext on disk, how many the document actually has, and
// whether its own metadata explains a gap between the two.
//
// # Why this exists
//
// `refuseUnusableEncryptionRule` (documentchanges.go) refuses to save a
// document whose `encrypted_regex` cannot compile — but only on this app's
// own save path. The real sops CLI has no equivalent guard: verified
// directly against sops 3.13.3, `sops --encrypt --age <key>
// --encrypted-regex '(unclosed' file.yaml` exits 0 and writes a file with a
// complete, valid `sops:` metadata block — recipients, a valid MAC, the
// broken pattern recorded verbatim as `encrypted_regex: (unclosed` — and
// every value in the document left in cleartext. A health check that only
// compares recipient sets (this app's existing check) sees a perfectly
// healthy file: the metadata says exactly what it should. This is the only
// place that looks at whether the *values* are actually protected.
//
// # Why this needs no decryption, and no key
//
// A value being ciphertext is a fact about its *shape* on disk —
// `ENC[AES256_GCM,data:...]`, recognised by the same pattern
// (`encValueRe`) sops's own recogniser uses — not a fact that requires
// unwrapping it. This loads the tree exactly as `Recipients` does
// (`loadEncryptedDocument`, no cipher operation, no identity) and walks it
// with the same `nodeIsCiphertext`/`walkAllNodes` helpers
// `collectNodeEncryption` already uses for the exposure-ledger guard —
// this is a read of the same fact that code already computes at save time,
// asked from a place that has no document to save and no key to save it
// with.
//
// # Three shapes, not one certain/uncertain split
//
// An empty `LeafCount>0, EncryptedLeafCount<LeafCount` gap is not on its own
// enough to call a file broken: `encrypted_regex` and its siblings exist
// precisely so some values can legitimately stay in cleartext
// (TestEncryptAcceptsARuleThatMatchesSomeKeys). So this reports, alongside
// the counts, two facts read from the file's own already-parsed
// `sops.Metadata` — no second parse of the raw text is needed, because
// unlike `UnencryptedSuffix` (see below), sops never fills these fields
// with a default:
//
//   - NarrowingDeclared: whether the file's metadata names any rule that
//     could legitimately leave some values in cleartext — an
//     `encrypted_regex`, `unencrypted_regex`, `encrypted_suffix`, either
//     `_comment_regex` sibling, or a non-default `unencrypted_suffix`.
//     `UnencryptedSuffix` is compared against sops's own compiled-in
//     default (`sops.DefaultUnencryptedSuffix`) rather than merely
//     checked for non-emptiness: `stores.metadata.ToInternal` fills that
//     one field with the default the moment a file declares *no* rule at
//     all, so its mere presence is not evidence of a choice — measured
//     directly against both this app's own `Encrypt` and the real CLI,
//     every default-mode file carries `unencrypted_suffix: _unencrypted`
//     whether anyone asked for it or not.
//   - UncompilableRuleDeclared: whether any declared regex-shaped rule
//     (`encrypted_regex`, `unencrypted_regex`, or either `_comment_regex`)
//     fails `regexp.Compile` — the exact engine sops itself compiles
//     these with. An uncompilable pattern can never match anything, so
//     sops's documented fallback (reproduced above) is certain, not a
//     guess: this is the one shape a caller may treat as a definite
//     finding even though NarrowingDeclared is also true for it.
//
// A caller combines these three ways:
//
//  1. UncompilableRuleDeclared: certain — report the gap as the ticket #5
//     bug regardless of what NarrowingDeclared says (a broken rule always
//     counts as declared).
//  2. !NarrowingDeclared, gap>0: certain — sops's documented behaviour with
//     no rule at all is "encrypt every leaf", so any gap is unexplained.
//  3. NarrowingDeclared (and compiles), gap>0: unverifiable — a rule that
//     compiles and simply matches none of this document's keys is a
//     legitimate configuration (TestEncryptRefusesARuleThatEncryptsNothingInThisDocument
//     shows this app's own save path already refuses to *create* that
//     shape, which is exactly why it is not this function's place to
//     assume the same about a file it did not create).
type LeafEncryptionSummary struct {
	// LeafCount is how many non-comment scalar leaves the document has,
	// across every document in a multi-document file. Zero for a document
	// with nothing to encrypt (`{}`, or one whose only values are null —
	// sops never encrypts those either), which must never be read as the
	// same shape as "every leaf is unencrypted".
	LeafCount int `json:"leafCount"`
	// EncryptedLeafCount is how many of those leaves are ciphertext on disk
	// right now, recognised the same way sops recognises its own output.
	EncryptedLeafCount int `json:"encryptedLeafCount"`
	// NarrowingDeclared is whether this file's own metadata names a rule
	// that could legitimately leave some values unencrypted. See the type
	// doc comment for exactly what counts and why `unencrypted_suffix`
	// needs special handling that the other five fields do not.
	NarrowingDeclared bool `json:"narrowingDeclared"`
	// UncompilableRuleDeclared is whether a declared regex-shaped rule
	// fails to compile under the same engine sops uses. See the type doc
	// comment for why this, alone, is certain enough to report as a
	// finding even though NarrowingDeclared is also true for it.
	UncompilableRuleDeclared bool `json:"uncompilableRuleDeclared"`
}

// InspectLeafEncryption loads (never decrypts) encrypted's tree, counts how
// many of its leaves are actually ciphertext, and reports what the file's
// own metadata says about whether that is expected. See LeafEncryptionSummary
// for what each field does and does not establish.
//
// Errors exactly as `Recipients` does: the document has no sops metadata at
// all, or could not be parsed as YAML. Never requires an age identity.
func InspectLeafEncryption(encrypted []byte) (LeafEncryptionSummary, error) {
	sf, err := FormatYAML.toSopsFormat()
	if err != nil {
		return LeafEncryptionSummary{}, err
	}
	tree, err := loadEncryptedDocument(common.StoreForFormat(sf, config.NewStoresConfig()), encrypted)
	if err != nil {
		return LeafEncryptionSummary{}, err
	}

	var leaves, encryptedLeaves int
	walkAllNodes(tree.Branches, func(_ string, _ []string, node interface{}) {
		if _, isComment := node.(sops.Comment); isComment {
			// Comments are walked by `walkAllNodes` (the exposure-ledger
			// guard needs to see them), but they are not document leaves —
			// counting them here would answer a different question than
			// the one this type's doc comment states. Ticket #5, claim 3
			// is the comment-specific gap; it is deliberately not this
			// function's job.
			return
		}
		leaves++
		if nodeIsCiphertext(node) {
			encryptedLeaves++
		}
	})

	narrowing, uncompilable := narrowingRuleState(tree.Metadata)

	return LeafEncryptionSummary{
		LeafCount: leaves, EncryptedLeafCount: encryptedLeaves,
		NarrowingDeclared: narrowing, UncompilableRuleDeclared: uncompilable,
	}, nil
}

// narrowingRuleState reads whether m declares a rule that could legitimately
// narrow encryption, and whether any regex-shaped rule it declares actually
// compiles. See LeafEncryptionSummary's doc comment for the reasoning.
func narrowingRuleState(m sops.Metadata) (narrowing bool, uncompilable bool) {
	regexRules := []string{m.EncryptedRegex, m.UnencryptedRegex, m.EncryptedCommentRegex, m.UnencryptedCommentRegex}
	for _, rule := range regexRules {
		if rule == "" {
			continue
		}
		narrowing = true
		if _, err := regexp.Compile(rule); err != nil {
			uncompilable = true
		}
	}
	if m.EncryptedSuffix != "" {
		narrowing = true
	}
	if m.UnencryptedSuffix != "" && m.UnencryptedSuffix != sops.DefaultUnencryptedSuffix {
		narrowing = true
	}
	return narrowing, uncompilable
}

// InspectLeafEncryptionJSON is the C-safe form of InspectLeafEncryption.
func InspectLeafEncryptionJSON(encrypted []byte) ([]byte, error) {
	summary, err := InspectLeafEncryption(encrypted)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(summary)
	if err != nil {
		return nil, errors.New("the leaf encryption summary could not be encoded")
	}
	return payload, nil
}
