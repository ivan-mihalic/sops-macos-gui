// Package gobridge wraps upstream getsops/sops as an in-process library.
//
// M0 spike goal: prove that a Swift host can encrypt and decrypt SOPS files
// without shelling out, producing bytes the standard `sops` CLI accepts.
package gobridge

import (
	"context"
	"fmt"
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
		return nil, fmt.Errorf("load plain file: %w", err)
	}
	if len(branches) < 1 {
		return nil, fmt.Errorf("file must contain at least one document")
	}
	if store.HasSopsTopLevelKey(branches[0]) {
		return nil, fmt.Errorf("file already encrypted: it has a top-level %q entry", "sops")
	}

	masterKeys, err := sopsage.MasterKeysFromRecipients(strings.Join(opts.AgeRecipients, ","))
	if err != nil {
		return nil, fmt.Errorf("parse age recipients: %w", err)
	}
	if len(masterKeys) == 0 {
		return nil, fmt.Errorf("no age recipients given")
	}
	group := make(sops.KeyGroup, 0, len(masterKeys))
	for _, mk := range masterKeys {
		group = append(group, mk)
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

	if err := common.EncryptTree(common.EncryptTreeOpts{
		DataKey: dataKey,
		Tree:    &tree,
		Cipher:  aes.NewCipher(),
	}); err != nil {
		return nil, fmt.Errorf("encrypt tree: %w", err)
	}

	encrypted, err := store.EmitEncryptedFile(tree)
	if err != nil {
		return nil, fmt.Errorf("emit encrypted file: %w", err)
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

	tree, err := store.LoadEncryptedFile(encrypted)
	if err != nil {
		return nil, fmt.Errorf("load encrypted file: %w", err)
	}

	ks := &ageKeyService{identities: identities}

	if _, err := common.DecryptTree(common.DecryptTreeOpts{
		Tree:        &tree,
		Cipher:      aes.NewCipher(),
		KeyServices: ks.clients(),
	}); err != nil {
		return nil, fmt.Errorf("decrypt tree: %w", err)
	}

	plain, err := store.EmitPlainFile(tree.Branches)
	if err != nil {
		return nil, fmt.Errorf("emit plain file: %w", err)
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
