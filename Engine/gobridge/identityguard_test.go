package gobridge

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The whole point of this file: ADR 0001 says "identities are passed as
// function arguments only". Upstream sops disagrees by default —
// age/keysource.go's MasterKey.Decrypt falls back to loadIdentities() (which
// reads SOPS_AGE_KEY, SOPS_AGE_KEY_FILE, SOPS_AGE_KEY_CMD, and
// $XDG_CONFIG_HOME/sops/age/keys.txt) whenever it was handed zero parsed
// identities. ParsedIdentities.Import("") returns nil identities *and a nil
// error*, so an empty key argument used to reach exactly that branch.
//
// Every test below sets one ambient discovery vector and calls Decrypt with a
// key argument that yields no identities. Each must fail. None of them may
// return plaintext, and none of them may cause anything to be executed.

// encryptedFixture returns a document encrypted to key, plus the key file
// contents an ambient-discovery vector would supply.
func encryptedFixture(t *testing.T) (encrypted []byte, key ageKeyPair) {
	t.Helper()
	key = newAgeKeyPair(t)
	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	return encrypted, key
}

// clearAmbientAgeEnv unsets every environment variable sops's age keysource
// consults, so a test that sets exactly one of them is measuring that one.
func clearAmbientAgeEnv(t *testing.T) {
	t.Helper()
	for _, name := range []string{
		"SOPS_AGE_KEY",
		"SOPS_AGE_KEY_FILE",
		"SOPS_AGE_KEY_CMD",
		"SOPS_AGE_SSH_PRIVATE_KEY_FILE",
		"SOPS_AGE_SSH_PRIVATE_KEY_CMD",
		"XDG_CONFIG_HOME",
	} {
		t.Setenv(name, "")
		if err := os.Unsetenv(name); err != nil {
			t.Fatalf("unset %s: %v", name, err)
		}
	}
}

// assertRefused fails the test if Decrypt succeeded, and also if it failed for
// the wrong reason (e.g. a malformed-document error rather than the guard).
func assertRefused(t *testing.T, plain []byte, err error) {
	t.Helper()
	if err == nil {
		t.Fatalf("Decrypt succeeded with no caller-supplied identity; it recovered %d bytes of plaintext from the environment", len(plain))
	}
	if plain != nil {
		t.Errorf("Decrypt returned %d bytes alongside an error; it must return nil plaintext", len(plain))
	}
	if !strings.Contains(err.Error(), "no age identity") {
		t.Errorf("Decrypt failed, but not with the identity guard's error: %v", err)
	}
}

func TestDecryptRefusesAmbientSopsAgeKeyEnv(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, key := encryptedFixture(t)
	t.Setenv("SOPS_AGE_KEY", key.Private)

	plain, err := Decrypt(encrypted, FormatYAML, "")
	assertRefused(t, plain, err)
}

func TestDecryptRefusesAmbientSopsAgeKeyFileEnv(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, key := encryptedFixture(t)
	keyFile := filepath.Join(t.TempDir(), "keys.txt")
	if err := os.WriteFile(keyFile, []byte(key.Private+"\n"), 0o600); err != nil {
		t.Fatalf("write key file: %v", err)
	}
	t.Setenv("SOPS_AGE_KEY_FILE", keyFile)

	plain, err := Decrypt(encrypted, FormatYAML, "")
	assertRefused(t, plain, err)
}

// The XDG path is the very file SecurityPostureCheck warns the user about:
// a plaintext age key sitting in ~/.config/sops/age/keys.txt. The app must
// never quietly use it.
func TestDecryptRefusesAmbientXDGConfigKeysFile(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, key := encryptedFixture(t)

	configHome := t.TempDir()
	ageDir := filepath.Join(configHome, "sops", "age")
	if err := os.MkdirAll(ageDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(ageDir, "keys.txt"), []byte(key.Private+"\n"), 0o600); err != nil {
		t.Fatalf("write keys.txt: %v", err)
	}
	t.Setenv("XDG_CONFIG_HOME", configHome)

	plain, err := Decrypt(encrypted, FormatYAML, "")
	assertRefused(t, plain, err)
}

// The worst vector: SOPS_AGE_KEY_CMD is a *command line* sops will execute.
// "The app never mutates the system" (CLAUDE.md) cannot survive the engine
// running a program named by an environment variable.
func TestDecryptNeverExecutesSopsAgeKeyCmd(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, _ := encryptedFixture(t)

	marker := filepath.Join(t.TempDir(), "marker")
	t.Setenv("SOPS_AGE_KEY_CMD", "/usr/bin/touch "+marker)

	plain, err := Decrypt(encrypted, FormatYAML, "")
	assertRefused(t, plain, err)

	if _, statErr := os.Stat(marker); statErr == nil {
		t.Fatalf("Decrypt executed the command in SOPS_AGE_KEY_CMD: %s was created", marker)
	}
}

// A key argument that is whitespace, or only comments, parses to zero
// identities just like "" does. Same guard, same refusal.
func TestDecryptRefusesKeyArgumentsThatYieldNoIdentity(t *testing.T) {
	cases := map[string]string{
		"empty":         "",
		"spaces":        "   ",
		"newlines":      "\n\n",
		"comment only":  "# this is a comment\n",
		"comments only": "# one\n#two\n\n",
	}
	for name, keyArg := range cases {
		t.Run(name, func(t *testing.T) {
			clearAmbientAgeEnv(t)
			encrypted, key := encryptedFixture(t)
			t.Setenv("SOPS_AGE_KEY", key.Private)

			plain, err := Decrypt(encrypted, FormatYAML, keyArg)
			assertRefused(t, plain, err)
		})
	}
}

// AGE-PLUGIN-… identities make sops exec an `age-plugin-*` binary found on
// PATH. That is the same "execute something from the environment" hazard as
// SOPS_AGE_KEY_CMD, reached through the key argument instead.
func TestDecryptRefusesPluginIdentity(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, _ := encryptedFixture(t)

	plain, err := Decrypt(encrypted, FormatYAML, "AGE-PLUGIN-YUBIKEY-1QQQQQQQQQQQQQ")
	if err == nil {
		t.Fatalf("Decrypt accepted an AGE-PLUGIN- identity and returned %d bytes", len(plain))
	}
	if plain != nil {
		t.Errorf("Decrypt returned %d bytes alongside an error", len(plain))
	}
	if !strings.Contains(err.Error(), "age identity") {
		t.Errorf("unexpected error shape: %v", err)
	}
}

// SSH private keys are another identity shape sops accepts. This app holds
// native age keys only; anything else is refused rather than silently routed
// through a different code path.
func TestDecryptRefusesNonAgeSecretKeyShapes(t *testing.T) {
	for name, keyArg := range map[string]string{
		"ssh private key": "-----BEGIN OPENSSH PRIVATE KEY-----\nnot-a-real-key\n-----END OPENSSH PRIVATE KEY-----",
		"public key":      "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsg5rzn",
		"random text":     "hunter2",
	} {
		t.Run(name, func(t *testing.T) {
			clearAmbientAgeEnv(t)
			encrypted, _ := encryptedFixture(t)

			plain, err := Decrypt(encrypted, FormatYAML, keyArg)
			if err == nil {
				t.Fatalf("Decrypt accepted %s and returned %d bytes", name, len(plain))
			}
			if plain != nil {
				t.Errorf("Decrypt returned %d bytes alongside an error", len(plain))
			}
		})
	}
}

// The error must name the problem without echoing any part of the key the
// caller supplied — an error string is exactly the kind of text that reaches
// a log or a crash report.
func TestDecryptIdentityErrorNeverEchoesTheKey(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, key := encryptedFixture(t)

	for _, keyArg := range []string{key.Private, "AGE-SECRET-KEY-1NOTAVALIDKEYATALL", "hunter2"} {
		// A syntactically valid key that cannot decrypt this file still must
		// not be echoed, so include the real one via a deliberately corrupted
		// variant as well.
		corrupted := strings.Replace(keyArg, "1", "0", 1)
		_, err := Decrypt(encrypted, FormatYAML, corrupted)
		if err == nil {
			continue
		}
		for _, secret := range []string{corrupted, keyArg} {
			if len(secret) > 8 && strings.Contains(err.Error(), secret) {
				t.Errorf("error echoes the supplied key material: %v", err)
			}
		}
	}
}

// The guard must not have broken the real path: a genuine identity still
// decrypts, and it does so with every ambient vector pointing somewhere else.
func TestDecryptStillWorksWithASuppliedIdentity(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, key := encryptedFixture(t)
	t.Setenv("SOPS_AGE_KEY", "AGE-SECRET-KEY-1GARBAGE")
	t.Setenv("SOPS_AGE_KEY_CMD", "/usr/bin/false")

	plain, err := Decrypt(encrypted, FormatYAML, key.Private)
	if err != nil {
		t.Fatalf("Decrypt with a real identity: %v", err)
	}
	if !strings.Contains(string(plain), "hunter2") {
		t.Errorf("decrypted output does not look like the fixture: %q", plain)
	}
}

// Surrounding whitespace and trailing comment lines are ordinary in a key
// file; they must not defeat a key that is genuinely present.
func TestDecryptAcceptsAKeyWithWhitespaceAndComments(t *testing.T) {
	clearAmbientAgeEnv(t)
	encrypted, key := encryptedFixture(t)

	keyArg := "# exported " + "from the app\n  " + key.Private + "  \n\n"
	plain, err := Decrypt(encrypted, FormatYAML, keyArg)
	if err != nil {
		t.Fatalf("Decrypt with a padded identity: %v", err)
	}
	if !strings.Contains(string(plain), "hunter2") {
		t.Errorf("decrypted output does not look like the fixture: %q", plain)
	}
}

// Encrypt legitimately builds a key service with zero identities — it only
// ever wraps, never unwraps. The guard belongs in Decrypt, not in
// newAgeKeyService, and this test pins that distinction.
func TestEncryptStillNeedsNoIdentity(t *testing.T) {
	clearAmbientAgeEnv(t)
	key := newAgeKeyPair(t)

	encrypted, err := Encrypt([]byte(plainYAML), FormatYAML, EncryptOpts{
		AgeRecipients: []string{key.Public},
	})
	if err != nil {
		t.Fatalf("Encrypt: %v", err)
	}
	if !strings.Contains(string(encrypted), "ENC[") {
		t.Errorf("Encrypt produced something that is not an encrypted document")
	}
}
