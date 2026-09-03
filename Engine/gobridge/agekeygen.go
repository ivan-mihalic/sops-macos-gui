package gobridge

import (
	"encoding/json"
	"fmt"

	"filippo.io/age"
)

// GeneratedAgeKey is one freshly minted age identity: the private line the
// user must keep, and the public recipient they may share.
//
// Both fields are the exact strings `age-keygen` itself prints — the private
// one an `AGE-SECRET-KEY-1…` line, the public one an `age1…` line — so a file
// written from these is interchangeable with one age-keygen produced, and a
// key pasted into this app from elsewhere is the same shape as one it made.
type GeneratedAgeKey struct {
	PrivateKey string `json:"privateKey"`
	PublicKey  string `json:"publicKey"`
}

// GenerateAgeKey mints a new X25519 age identity and returns it as JSON.
//
// SOPS-44. This is the one place in the project that creates key material,
// and it is worth being exact about what that does and does not change:
//
//   - The key is generated in memory and handed back. Nothing is written to
//     disk, nothing is added to any config, and nothing is installed into the
//     user's key store — the app still never mutates the system (CLAUDE.md).
//     What the caller does with the private line is the user's decision,
//     taken on a screen that says so.
//   - Randomness is age's own (`age.GenerateX25519Identity`, which reads
//     crypto/rand). This package deliberately does not derive, stretch or
//     post-process it: a home-grown step here would be a second, unaudited
//     key derivation next to the one the whole format depends on.
//   - The private key is returned exactly once, to exactly one caller. It is
//     never logged, never put in an error message, and never retained — the
//     error paths below name the failure, never the value.
func GenerateAgeKey() ([]byte, error) {
	identity, err := age.GenerateX25519Identity()
	if err != nil {
		return nil, fmt.Errorf("a new age key could not be generated: %w", err)
	}
	return json.Marshal(GeneratedAgeKey{
		PrivateKey: identity.String(),
		PublicKey:  identity.Recipient().String(),
	})
}
