package gobridge

import (
	"errors"

	"filippo.io/age"
)

// AgePublicKey derives the native age public key (a Bech32 "age1…"
// recipient) that corresponds to privateKey.
//
// SOPS-38 phase F3: detecting a read-only ciphertext file — one whose
// recipients do not include the session's own key — must never decrypt
// anything. Comparing public keys against a file's own `sops.age[].recipient`
// metadata (`EncryptedFileMetadata`, Swift side) needs the session's public
// key, and `SessionKeyStore` holds only the private identity a user pasted
// in. This is the one call that turns that private identity into the public
// key it corresponds to — read-only, and itself no more sensitive than
// `age-keygen`'s own "# public key: …" line, which is exactly what this
// reproduces.
//
// privateKey must be a native AGE-SECRET-KEY-1… identity, the same shape
// every other private-key-taking function in this package requires. An
// invalid or malformed identity is an ordinary error, never a panic — the
// same age.ParseX25519Identity call SessionKeyStore's own shape check exists
// to catch most of before this is ever reached, but this function does not
// assume that check ran.
func AgePublicKey(privateKey string) (string, error) {
	identity, err := age.ParseX25519Identity(privateKey)
	if err != nil {
		return "", errors.New("not a valid age private key")
	}
	return identity.Recipient().String(), nil
}
