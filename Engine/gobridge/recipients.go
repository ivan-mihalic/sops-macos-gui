package gobridge

import (
	"encoding/json"
	"errors"
	"strings"

	"filippo.io/age"
	"github.com/getsops/sops/v3"
	sopsage "github.com/getsops/sops/v3/age"
	"github.com/getsops/sops/v3/cmd/sops/common"
	"github.com/getsops/sops/v3/config"
)

// These messages intentionally carry no supplied recipient, identity or
// document content. Every one can reach the UI, logs and crash reports.
var (
	errRecipientsEmpty    = errors.New("at least one recipient is required")
	errRecipientPrivate   = errors.New("a recipient is a private age identity, not a public age recipient")
	errRecipientPlugin    = errors.New("a recipient is an age plugin recipient; this app supports native age recipients only")
	errRecipientInvalid   = errors.New("a recipient is not a valid native age public key")
	errDocumentNotAgeOnly = errors.New("this file does not use a single native age recipient group")
)

// Recipients returns the native age public recipients embedded in encrypted's
// SOPS metadata. This does not decrypt the document and never consults config,
// environment variables, key files or plugins.
func Recipients(encrypted []byte) ([]string, error) {
	sf, err := FormatYAML.toSopsFormat()
	if err != nil {
		return nil, err
	}
	tree, err := loadEncryptedDocument(common.StoreForFormat(sf, config.NewStoresConfig()), encrypted)
	if err != nil {
		return nil, err
	}
	return recipientsFromMetadata(tree.Metadata)
}

// RecipientsJSON is the C-safe form of Recipients. JSON keeps a list's
// boundaries intact across the string-only bridge.
func RecipientsJSON(encrypted []byte) ([]byte, error) {
	recipients, err := Recipients(encrypted)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(recipients)
	if err != nil {
		return nil, errors.New("the recipients could not be encoded")
	}
	return payload, nil
}

// UpdateRecipients replaces the document's sole age key group and re-wraps
// its existing data key. It deliberately never derives recipients from a
// project config: changing access is explicit user intent.
func UpdateRecipients(encrypted []byte, recipients []string, agePrivateKey string) ([]byte, error) {
	masterKeys, err := nativeAgeMasterKeys(recipients)
	if err != nil {
		return nil, err
	}
	// Refuse unsupported metadata before handling an identity or decrypting any
	// document content. The re-wrap operation is only defined for one native age
	// key group.
	if _, err := Recipients(encrypted); err != nil {
		return nil, err
	}

	doc, err := loadAndDecrypt(encrypted, agePrivateKey)
	if err != nil {
		return nil, err
	}

	group := make(sops.KeyGroup, 0, len(masterKeys))
	for _, key := range masterKeys {
		group = append(group, key)
	}
	doc.tree.Metadata.KeyGroups = []sops.KeyGroup{group}
	// A sole group encrypts the full data key, so any former multi-group
	// threshold must not survive in the metadata.
	doc.tree.Metadata.ShamirThreshold = 0

	ks := &ageKeyService{}
	if errs := doc.tree.Metadata.UpdateMasterKeysWithKeyServices(doc.dataKey, ks.clients()); len(errs) > 0 {
		return nil, errors.New("the data key could not be re-wrapped for the requested recipients")
	}
	if err := common.EncryptTree(common.EncryptTreeOpts{
		DataKey: doc.dataKey,
		Tree:    doc.tree,
		Cipher:  doc.cipher,
	}); err != nil {
		return nil, errors.New("the document could not be re-encrypted")
	}
	out, err := doc.store.EmitEncryptedFile(*doc.tree)
	if err != nil {
		return nil, errors.New("the re-wrapped document could not be rendered")
	}
	return out, nil
}

// UpdateRecipientsJSON accepts the C bridge's JSON list without ever putting
// its contents in an error message.
func UpdateRecipientsJSON(encrypted, recipientsJSON []byte, agePrivateKey string) ([]byte, error) {
	var recipients []string
	if err := json.Unmarshal(recipientsJSON, &recipients); err != nil {
		return nil, errors.New("the recipient list is not valid JSON")
	}
	return UpdateRecipients(encrypted, recipients, agePrivateKey)
}

func recipientsFromMetadata(metadata sops.Metadata) ([]string, error) {
	if len(metadata.KeyGroups) != 1 || len(metadata.KeyGroups[0]) == 0 {
		return nil, errDocumentNotAgeOnly
	}
	recipients := make([]string, 0, len(metadata.KeyGroups[0]))
	for _, key := range metadata.KeyGroups[0] {
		if key.TypeToIdentifier() != sopsage.KeyTypeIdentifier {
			return nil, errDocumentNotAgeOnly
		}
		recipient := key.ToString()
		if _, err := age.ParseX25519Recipient(recipient); err != nil {
			return nil, errDocumentNotAgeOnly
		}
		recipients = append(recipients, recipient)
	}
	return recipients, nil
}

func nativeAgeMasterKeys(recipients []string) ([]*sopsage.MasterKey, error) {
	keys := make([]*sopsage.MasterKey, 0, len(recipients))
	for _, supplied := range recipients {
		recipient := strings.TrimSpace(supplied)
		if recipient == "" {
			return nil, errRecipientInvalid
		}
		if strings.HasPrefix(recipient, agePrivateKeyPrefix) {
			return nil, errRecipientPrivate
		}
		if strings.HasPrefix(recipient, "age1") && strings.Contains(recipient[len("age1"):], "1") {
			return nil, errRecipientPlugin
		}
		if _, err := age.ParseX25519Recipient(recipient); err != nil {
			return nil, errRecipientInvalid
		}
		keys = append(keys, &sopsage.MasterKey{Recipient: recipient})
	}
	if len(keys) == 0 {
		return nil, errRecipientsEmpty
	}
	return keys, nil
}
