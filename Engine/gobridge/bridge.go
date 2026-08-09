// Package gobridge wraps upstream getsops/sops as an in-process library.
//
// M0 spike goal: prove that a Swift host can encrypt and decrypt SOPS files
// without shelling out, producing bytes the standard `sops` CLI accepts.
package gobridge

import (
	"context"
	"fmt"
	"reflect"
	"regexp"
	"runtime/debug"
	"strings"

	"github.com/getsops/sops/v3"
	"github.com/getsops/sops/v3/aes"
	sopsage "github.com/getsops/sops/v3/age"
	"github.com/getsops/sops/v3/cmd/sops/common"
	"github.com/getsops/sops/v3/cmd/sops/formats"
	"github.com/getsops/sops/v3/config"
	"github.com/getsops/sops/v3/keyservice"
	"github.com/getsops/sops/v3/version"
)

// Format identifies the on-disk file format of a SOPS document.
type Format string

const (
	FormatYAML Format = "yaml"
)

func (f Format) toSopsFormat() (formats.Format, error) {
	switch f {
	case FormatYAML:
		return formats.Yaml, nil
	default:
		return 0, fmt.Errorf("unsupported format %q", f)
	}
}

// ageKeyService is a keyservice.KeyServiceServer that decrypts age-wrapped data
// keys using identities handed to it explicitly, never from the environment or
// ~/.config/sops/age/keys.txt. The app must stay in control of key material.
type ageKeyService struct {
	identities sopsage.ParsedIdentities
}

func newAgeKeyService(privateKeys ...string) (*ageKeyService, error) {
	var ids sopsage.ParsedIdentities
	if err := ids.Import(privateKeys...); err != nil {
		return nil, fmt.Errorf("import age identity: %w", err)
	}
	return &ageKeyService{identities: ids}, nil
}

// agePrivateKeyPrefix is the Bech32 HRP of a native X25519 age secret key.
// Deliberately the only shape this bridge accepts as a decryption identity.
const agePrivateKeyPrefix = "AGE-SECRET-KEY-1"

// errNoAgeIdentity is what every caller-facing refusal in
// parseDecryptionIdentities is built from, so a caller can match on a stable
// phrase. It never carries any part of the supplied key.
const errNoAgeIdentity = "no age identity was supplied to decrypt with"

// parseDecryptionIdentities turns the caller's key argument into a non-empty
// set of native age identities, or fails.
//
// This exists because upstream sops treats "zero identities" as an invitation
// to go looking. age/keysource.go's MasterKey.Decrypt does:
//
//	if len(key.parsedIdentities) == 0 { ids, _, errs = key.loadIdentities() ... }
//
// and loadIdentities() reads SOPS_AGE_KEY, SOPS_AGE_KEY_FILE,
// $XDG_CONFIG_HOME/sops/age/keys.txt, the SSH key locations — and
// SOPS_AGE_KEY_CMD, which it *executes as a command line*. Meanwhile
// ParsedIdentities.Import("") returns nil identities and a nil error, so an
// empty, whitespace-only or comment-only key argument used to slide straight
// into that branch. Verified by running it: with SOPS_AGE_KEY_CMD set to
// "/usr/bin/touch marker", Decrypt(enc, FormatYAML, "") created the marker.
//
// ADR 0001 makes "identities are passed as function arguments only" binding
// for M1+, and CLAUDE.md says the app never mutates the system. Both are
// violated by a decrypt path that can be steered from the environment, so the
// guard is: parse the argument ourselves, require at least one identity, and
// accept only the AGE-SECRET-KEY-1 shape.
//
// Restricting to AGE-SECRET-KEY-1 is what closes the second execution vector.
// sops's own parseIdentity routes an AGE-PLUGIN-… string to plugin.NewIdentity,
// which execs an `age-plugin-*` binary found on PATH — the same "run whatever
// the environment points at" hazard, reached through the key argument instead
// of an environment variable. AGE-SECRET-KEY-PQ-1 (hybrid post-quantum) is
// refused too: this app only ever generates X25519 keys, so accepting a shape
// it cannot produce would widen the parser surface for nothing.
//
// No part of the supplied key appears in any error returned here. An error
// string is exactly the kind of text that reaches a log, a crash report or a
// screenshot.
func parseDecryptionIdentities(agePrivateKey string) (sopsage.ParsedIdentities, error) {
	var accepted []string
	for _, raw := range strings.Split(agePrivateKey, "\n") {
		line := strings.TrimSpace(raw)
		// Blank and #-comment lines are ordinary in an exported key file.
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if !strings.HasPrefix(line, agePrivateKeyPrefix) {
			return nil, fmt.Errorf("%s: this build accepts a native age secret key (%s…) only, and the value given is not one. Nothing was read from the environment", errNoAgeIdentity, agePrivateKeyPrefix)
		}
		accepted = append(accepted, line)
	}
	if len(accepted) == 0 {
		return nil, fmt.Errorf("%s: the key argument contained no key. This build never falls back to SOPS_AGE_KEY, SOPS_AGE_KEY_FILE, SOPS_AGE_KEY_CMD or ~/.config/sops/age/keys.txt", errNoAgeIdentity)
	}

	var ids sopsage.ParsedIdentities
	if err := ids.Import(accepted...); err != nil {
		// sops's parse error can quote the offending line, so it is
		// deliberately not wrapped into the message.
		return nil, fmt.Errorf("%s: the value given is not a usable age secret key", errNoAgeIdentity)
	}
	// Belt and braces: Import returning nil identities with a nil error is
	// precisely the upstream behaviour this guard exists to contain, so the
	// post-condition is asserted rather than assumed.
	if len(ids) == 0 {
		return nil, fmt.Errorf("%s: the key argument parsed to no identities", errNoAgeIdentity)
	}
	return ids, nil
}

func (s *ageKeyService) Decrypt(ctx context.Context, req *keyservice.DecryptRequest) (*keyservice.DecryptResponse, error) {
	k, ok := req.Key.KeyType.(*keyservice.Key_AgeKey)
	if !ok {
		return nil, fmt.Errorf("unsupported key type %T: this build handles age keys only", req.Key.KeyType)
	}
	// Second line of defence behind parseDecryptionIdentities. A MasterKey
	// handed zero identities does not fail — sops's MasterKey.Decrypt reads
	// the environment instead (see parseDecryptionIdentities for the detail).
	// The encryption path legitimately builds this service with no identities
	// at all, so refusing here keeps that construction from ever being able to
	// unwrap anything.
	if len(s.identities) == 0 {
		return nil, fmt.Errorf("%s: this key service holds no identities", errNoAgeIdentity)
	}
	mk := sopsage.MasterKey{Recipient: k.AgeKey.Recipient}
	mk.EncryptedKey = string(req.Ciphertext)
	s.identities.ApplyToMasterKey(&mk)
	plaintext, err := mk.Decrypt()
	if err != nil {
		return nil, err
	}
	return &keyservice.DecryptResponse{Plaintext: plaintext}, nil
}

func (s *ageKeyService) Encrypt(ctx context.Context, req *keyservice.EncryptRequest) (*keyservice.EncryptResponse, error) {
	k, ok := req.Key.KeyType.(*keyservice.Key_AgeKey)
	if !ok {
		return nil, fmt.Errorf("unsupported key type %T: this build handles age keys only", req.Key.KeyType)
	}
	mk := sopsage.MasterKey{Recipient: k.AgeKey.Recipient}
	if err := mk.Encrypt(req.Plaintext); err != nil {
		return nil, err
	}
	return &keyservice.EncryptResponse{Ciphertext: []byte(mk.EncryptedKey)}, nil
}

func (s *ageKeyService) clients() []keyservice.KeyServiceClient {
	return []keyservice.KeyServiceClient{keyservice.NewCustomLocalClient(s)}
}

// SplitRecipients parses a comma-separated recipient list, dropping blanks.
// The C boundary can only carry one string, so this is how Swift passes a list.
func SplitRecipients(csv string) []string {
	var out []string
	for _, part := range strings.Split(csv, ",") {
		if part = strings.TrimSpace(part); part != "" {
			out = append(out, part)
		}
	}
	return out
}

// EncryptOpts mirrors the subset of `.sops.yaml` creation rules the spike covers.
type EncryptOpts struct {
	// AgeRecipients are Bech32-encoded age public keys (age1...) that will each
	// be able to decrypt the resulting file.
	AgeRecipients []string
	// EncryptedRegex, when non-empty, restricts encryption to matching keys.
	EncryptedRegex string
}

// Encrypt turns a plaintext document into a SOPS-encrypted one.
//
// This mirrors cmd/sops/encrypt.go step for step; the point of the spike is
// that the output is indistinguishable from what the CLI would have written.
func Encrypt(plain []byte, format Format, opts EncryptOpts) ([]byte, error) {
	sf, err := format.toSopsFormat()
	if err != nil {
		return nil, err
	}
	store := common.StoreForFormat(sf, config.NewStoresConfig())

	branches, err := store.LoadPlainFile(plain)
	if err != nil {
		// Never `%w`. go-yaml quotes the document back at you for a duplicate
		// key, an unresolved alias, or a scalar where a mapping was expected —
		// and this input is the user's plaintext. The line number survives;
		// nothing else does. See describeYAMLFailure in document.go.
		return nil, describeYAMLFailure("the document is not valid YAML", err)
	}
	if len(branches) < 1 {
		return nil, fmt.Errorf("file must contain at least one document")
	}
	if store.HasSopsTopLevelKey(branches[0]) {
		return nil, fmt.Errorf("file already encrypted: it has a top-level %q entry", "sops")
	}

	// Refuse anything that is not a native `age1…` recipient, **before**
	// handing the string to upstream. Two reasons, both measured:
	//
	//  1. Upstream's parse error is `unknown recipient type: %q` with the whole
	//     input. Paste an `AGE-SECRET-KEY-1…` into the recipients field — an
	//     easy mistake, they sit side by side in the UI — and the private key
	//     comes back inside `SopsBridgeError.description`, which reaches the
	//     UI, the log and any crash report. The decrypt path already guards
	//     exactly this (`parseDecryptionIdentities`); the encrypt path did not.
	//
	//  2. A recipient shaped like `age1name1…` makes upstream exec
	//     `age-plugin-<name>` **from $PATH**, with no absolute path and no
	//     timeout. Recipients come from a project's `.sops.yaml`, so a cloned
	//     repository could name the plugin. That is the same vector
	//     `parseDecryptionIdentities` closes on the identity side.
	for index, recipient := range opts.AgeRecipients {
		if !strings.HasPrefix(recipient, "age1") {
			return nil, fmt.Errorf(
				"recipient %d is not a native age recipient: it must begin with %q",
				// Index, never the value: the value may be a private key.
				index+1, "age1")
		}
		// `age1<name>1<data>` is the plugin form. A native X25519 recipient is
		// bech32 over `age1` with no further separator.
		if rest := recipient[len("age1"):]; strings.Contains(rest, "1") {
			return nil, fmt.Errorf(
				"recipient %d looks like an age plugin recipient; this app supports "+
					"native age recipients only, and never runs a plugin binary",
				index+1)
		}
	}

	masterKeys, err := sopsage.MasterKeysFromRecipients(strings.Join(opts.AgeRecipients, ","))
	if err != nil {
		// Never `%w`: see above. The recipients string may contain a private
		// key the user pasted into the wrong field.
		return nil, fmt.Errorf("the age recipients could not be parsed")
	}
	if len(masterKeys) == 0 {
		return nil, fmt.Errorf("no age recipients given")
	}
	group := make(sops.KeyGroup, 0, len(masterKeys))
	for _, mk := range masterKeys {
		group = append(group, mk)
	}

	// `sops.Tree.shouldBeEncrypted` does `matched, _ := regexp.Match(...)` and
	// drops the error, so an `encrypted_regex` that does not compile makes
	// every value "not matched" — and the file is written with complete sops
	// metadata, a valid MAC, and every secret in cleartext. `sops --decrypt`
	// reads it back without complaint. Verified.
	//
	// Compiling it here turns that into a refusal. The regex text is the
	// user's own rule from `.sops.yaml`, not document content, so quoting it
	// is safe and is the only way the message is actionable.
	if opts.EncryptedRegex != "" {
		if _, err := regexp.Compile(opts.EncryptedRegex); err != nil {
			return nil, fmt.Errorf(
				"encrypted_regex %q is not a valid regular expression, so nothing would "+
					"have been encrypted", opts.EncryptedRegex)
		}
	}

	// The CLI only falls back to the default unencrypted suffix when no other
	// encryption rule is in play (main.go: cryptRuleCount == 0).
	unencryptedSuffix := ""
	if opts.EncryptedRegex == "" {
		unencryptedSuffix = sops.DefaultUnencryptedSuffix
	}

	tree := sops.Tree{
		Branches: branches,
		Metadata: sops.Metadata{
			KeyGroups:         []sops.KeyGroup{group},
			UnencryptedSuffix: unencryptedSuffix,
			EncryptedRegex:    opts.EncryptedRegex,
			Version:           version.Version,
		},
	}

	ks, err := newAgeKeyService()
	if err != nil {
		return nil, err
	}
	dataKey, errs := tree.GenerateDataKeyWithKeyServices(ks.clients())
	if len(errs) > 0 {
		return nil, fmt.Errorf("generate data key: %v", errs)
	}

	// Snapshotted before the encrypt so the check below is a *post-condition*
	// on what actually happened, not a prediction of what sops's matching
	// rules will do. Predicting them means reimplementing
	// `sops.Tree.shouldBeEncrypted` here and keeping the copy in step forever;
	// comparing before with after cannot drift.
	valuesBeforeEncrypting := leafValues(tree.Branches)

	if err := common.EncryptTree(common.EncryptTreeOpts{
		DataKey: dataKey,
		Tree:    &tree,
		Cipher:  aes.NewCipher(),
	}); err != nil {
		// Same rule as the decrypt path, for the same reason: sops's
		// tree-encryption errors interpolate the value that failed
		// ("Could not convert %s to bytes", and a timestamp that would not
		// marshal), and everything in this tree is plaintext.
		return nil, fmt.Errorf("the document could not be encrypted")
	}

	// A rule that compiles and matches nothing produces a file with complete
	// sops metadata, a valid MAC, and every value in cleartext. `sops
	// --decrypt` reads it back without complaint, so nothing downstream ever
	// notices, and from the user's side it is indistinguishable from a
	// successful encryption. The compile guard above cannot see this:
	// `^nothing_here$` is a perfectly valid regular expression.
	//
	// Only when the document has values at all — an empty file has nothing to
	// encrypt, and that is not a broken rule.
	//
	// Note this deliberately differs from the save path
	// (`refuseUnusableEncryptionRule`), which refuses only the compile
	// failure. There, the document arrived already encrypted under its own
	// rule, so "matches nothing" describes a file that was already like that
	// before this app touched it. Here the app is *creating* the file, and a
	// file it creates must not claim a protection it did not apply.
	if len(valuesBeforeEncrypting) > 0 &&
		!anyValueChanged(valuesBeforeEncrypting, leafValues(tree.Branches)) {
		if opts.EncryptedRegex != "" {
			return nil, fmt.Errorf(
				"encrypted_regex %q matches none of this document's keys, so every value "+
					"would have been written in plain text", opts.EncryptedRegex)
		}
		return nil, fmt.Errorf(
			"every key in this document ends in %q, which sops treats as \"do not encrypt\", "+
				"so every value would have been written in plain text",
			sops.DefaultUnencryptedSuffix)
	}

	encrypted, err := store.EmitEncryptedFile(tree)
	if err != nil {
		return nil, fmt.Errorf("the encrypted document could not be rendered")
	}
	return encrypted, nil
}

// Decrypt returns the plaintext of a SOPS-encrypted document, using the given
// age private key (AGE-SECRET-KEY-1...) as the decryption identity.
//
// The identity is validated up front — see parseDecryptionIdentities. A key
// argument that yields no identity is an error, never a signal to look at the
// environment.
func Decrypt(encrypted []byte, format Format, agePrivateKey string) ([]byte, error) {
	// Validated before anything else is done, so the refusal cannot depend on
	// the document's contents or on how far parsing got.
	identities, err := parseDecryptionIdentities(agePrivateKey)
	if err != nil {
		return nil, err
	}

	sf, err := format.toSopsFormat()
	if err != nil {
		return nil, err
	}
	store := common.StoreForFormat(sf, config.NewStoresConfig())

	// Shared with the document API so that both read paths refuse the same
	// files, sanitise the same way, and cannot drift apart.
	tree, err := loadEncryptedDocument(store, encrypted)
	if err != nil {
		return nil, err
	}

	ks := &ageKeyService{identities: identities}

	if _, err := common.DecryptTree(common.DecryptTreeOpts{
		Tree:        tree,
		Cipher:      aes.NewCipher(),
		KeyServices: ks.clients(),
	}); err != nil {
		// Never `%w`. sops's decrypt errors can carry the decrypted value:
		// aes.Cipher.Decrypt converts the plaintext after unwrapping it and
		// passes strconv's error, which quotes its input, back up. See
		// describeDecryptFailure in document.go for the full account.
		return nil, describeDecryptFailure(tree, err)
	}

	plain, err := store.EmitPlainFile(tree.Branches)
	if err != nil {
		// The YAML encoder's error can quote the value it choked on, and every
		// value in this tree is now plaintext.
		return nil, fmt.Errorf("the decrypted document could not be rendered")
	}
	return plain, nil
}

// UnknownVersion is what SopsVersion and AgeVersion report when the linked
// module version cannot be determined at all.
//
// Deliberately not a version number. Every consumer of these strings performs
// a *comparison* — ExternalToolCheck warns when the installed sops CLI is
// older than the embedded engine, EngineFreshnessCheck warns when the embedded
// engine is older than the latest upstream release. The previous sentinel,
// "0.0.0", is the single worst value for that: it parses cleanly as semver and
// then loses every comparison, so an engine whose version was never actually
// read turned "warn if the CLI is behind" into a permanent OK (an installed
// sops 3.0.0 reported [OK] against an embedded 0.0.0), and turned the
// freshness check into a confident warning about a version nobody established.
//
// A value that cannot parse as semver forces the Swift side to handle the
// unknown case explicitly instead of silently comparing against a fiction.
const UnknownVersion = "unknown"

// moduleVersion reports the version of the named module linked into this
// binary, or UnknownVersion.
//
// Build info rather than a package constant: sops's own version.Version is a
// hand-maintained literal in upstream sops, not derived from the module
// system, so reading it would let this drift silently from what was actually
// linked.
func moduleVersion(modulePath string) string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return UnknownVersion
	}
	for _, dep := range info.Deps {
		if dep.Path == modulePath {
			if v := strings.TrimPrefix(dep.Version, "v"); v != "" {
				return v
			}
			return UnknownVersion
		}
	}
	return UnknownVersion
}

// SopsVersion reports the sops version compiled into this bridge, taken from
// the linked module (github.com/getsops/sops/v3), or UnknownVersion.
func SopsVersion() string { return moduleVersion("github.com/getsops/sops/v3") }

// AgeVersion reports the filippo.io/age version compiled into this bridge, or
// UnknownVersion. age exposes no version constant, so it is read from the
// build info.
func AgeVersion() string { return moduleVersion("filippo.io/age") }

// leafValues returns every scalar value in a tree, in walk order.
//
// Comments are excluded. **Not** because sops leaves them alone — it does not,
// it encrypts them (`Tree.walkBranch` runs the comment through the cipher) and
// then leaves them out of the MAC. An earlier version of this comment claimed
// the opposite, and that belief is why the save-path guard went a round without
// looking at comments at all. Here the exclusion only makes this post-condition
// more conservative: it asks "did encrypting do anything to the values", and a
// document of nothing but comments would otherwise answer yes for a reason that
// has nothing to do with the rule under test.
func leafValues(branches sops.TreeBranches) []interface{} {
	var values []interface{}
	var walk func(interface{})
	walk = func(node interface{}) {
		switch typed := node.(type) {
		case sops.TreeBranch:
			for _, item := range typed {
				if _, isComment := item.Key.(sops.Comment); isComment {
					continue
				}
				walk(item.Value)
			}
		case []interface{}:
			for _, element := range typed {
				walk(element)
			}
		case sops.Comment:
			// Not a value.
		case nil:
			// sops's own `walkValue` returns early on nil, so a null is never
			// encrypted and can never change. Counting it made a document whose
			// only leaf is `password:` (a null) look like one where encryption
			// silently did nothing, and the refusal then told the user their
			// rule matched no keys — about a rule matching the only key there
			// is. Measured before this line existed.
		default:
			values = append(values, node)
		}
	}
	for _, branch := range branches {
		walk(branch)
	}
	return values
}

// anyValueChanged reports whether encryption touched anything at all. A length
// change counts: it means the shape moved, which encryption alone would not do
// but which is certainly not "nothing happened".
func anyValueChanged(before, after []interface{}) bool {
	if len(before) != len(after) {
		return true
	}
	for i := range before {
		if !reflect.DeepEqual(before[i], after[i]) {
			return true
		}
	}
	return false
}
