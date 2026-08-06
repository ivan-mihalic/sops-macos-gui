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

func (s *ageKeyService) Decrypt(ctx context.Context, req *keyservice.DecryptRequest) (*keyservice.DecryptResponse, error) {
	k, ok := req.Key.KeyType.(*keyservice.Key_AgeKey)
	if !ok {
		return nil, fmt.Errorf("unsupported key type %T: this build handles age keys only", req.Key.KeyType)
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
func Decrypt(encrypted []byte, format Format, agePrivateKey string) ([]byte, error) {
	sf, err := format.toSopsFormat()
	if err != nil {
		return nil, err
	}
	store := common.StoreForFormat(sf, config.NewStoresConfig())

	tree, err := store.LoadEncryptedFile(encrypted)
	if err != nil {
		return nil, fmt.Errorf("load encrypted file: %w", err)
	}

	ks, err := newAgeKeyService(agePrivateKey)
	if err != nil {
		return nil, err
	}

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

// SopsVersion reports the sops version compiled into this bridge, taken from
// the linked module rather than a hand-maintained constant.
func SopsVersion() string {
	return strings.TrimPrefix(version.Version, "v")
}

// AgeVersion reports the filippo.io/age version compiled into this bridge.
// age exposes no version constant, so it is read from the build info.
func AgeVersion() string {
	info, ok := debug.ReadBuildInfo()
	if !ok {
		return "0.0.0"
	}
	for _, dep := range info.Deps {
		if dep.Path == "filippo.io/age" {
			return strings.TrimPrefix(dep.Version, "v")
		}
	}
	return "0.0.0"
}
