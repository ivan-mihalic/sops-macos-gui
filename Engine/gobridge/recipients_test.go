package gobridge

import (
	"reflect"
	"strings"
	"testing"

	"github.com/getsops/sops/v3"
	sopsage "github.com/getsops/sops/v3/age"
	"github.com/getsops/sops/v3/cmd/sops/common"
	"github.com/getsops/sops/v3/config"
	"github.com/getsops/sops/v3/pgp"
)

// The C shim can only pass a single string across the boundary, so recipients
// arrive comma-separated. strings.Split("", ",") yields [""], which would turn
// "no recipients" into "one empty recipient" — hence this helper.
func TestSplitRecipients(t *testing.T) {
	cases := map[string]struct {
		in   string
		want []string
	}{
		"empty":           {"", nil},
		"only separators": {" , , ", nil},
		"single":          {"age1abc", []string{"age1abc"}},
		"multiple":        {"age1abc,age1def", []string{"age1abc", "age1def"}},
		"surrounding ws":  {" age1abc , age1def ", []string{"age1abc", "age1def"}},
		"trailing comma":  {"age1abc,", []string{"age1abc"}},
	}

	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			got := SplitRecipients(tc.in)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("SplitRecipients(%q) = %#v, want %#v", tc.in, got, tc.want)
			}
		})
	}
}

func TestUpdateRecipientsRewrapsForExactlyTheRequestedPeople(t *testing.T) {
	owner := newAgeKeyPair(t)
	kept := newAgeKeyPair(t)
	added := newAgeKeyPair(t)
	removed := newAgeKeyPair(t)

	encrypted := runSopsCLI(t, owner, nil,
		"--encrypt", "--age", owner.Public+","+removed.Public,
		writeTemp(t, "secrets.yaml", []byte(plainYAML)))

	rewrapped, err := UpdateRecipients(encrypted, []string{kept.Public, added.Public}, owner.Private)
	if err != nil {
		t.Fatalf("UpdateRecipients: %v", err)
	}

	for _, key := range []ageKeyPair{kept, added} {
		if got, err := Decrypt(rewrapped, FormatYAML, key.Private); err != nil || string(got) != plainYAML {
			t.Fatalf("new recipient cannot decrypt: output %q, error %v", got, err)
		}
	}
	if _, err := Decrypt(rewrapped, FormatYAML, removed.Private); err == nil {
		t.Fatal("removed recipient can still decrypt")
	}
}

func TestRecipientsReadsTheDocumentMetadata(t *testing.T) {
	first := newAgeKeyPair(t)
	second := newAgeKeyPair(t)
	encrypted := runSopsCLI(t, first, nil,
		"--encrypt", "--age", first.Public+","+second.Public,
		writeTemp(t, "secrets.yaml", []byte(plainYAML)))

	got, err := Recipients(encrypted)
	if err != nil {
		t.Fatalf("Recipients: %v", err)
	}
	if !reflect.DeepEqual(got, []string{first.Public, second.Public}) {
		t.Fatalf("Recipients = %q, want %q", got, []string{first.Public, second.Public})
	}
}

func TestUpdateRecipientsRefusesUnsafeRecipientArguments(t *testing.T) {
	owner := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, owner, plainYAML)

	for name, tc := range map[string]struct {
		recipients []string
		want       error
	}{
		"empty":           {nil, errRecipientsEmpty},
		"private":         {[]string{owner.Private}, errRecipientPrivate},
		"plugin":          {[]string{"age1yubikey1qwbmkfqzrqzc4dm5dqrgcnpq6r0dsmrpqzr"}, errRecipientPlugin},
		"invalid":         {[]string{"not-an-age-recipient"}, errRecipientInvalid},
		"empty item":      {[]string{owner.Public, ""}, errRecipientInvalid},
		"whitespace item": {[]string{owner.Public, " \t\n "}, errRecipientInvalid},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := UpdateRecipients(encrypted, tc.recipients, owner.Private)
			if err == nil {
				t.Fatal("unsafe recipients were accepted")
			}
			if err.Error() != tc.want.Error() {
				t.Fatalf("UpdateRecipients did not return the expected fixed error text")
			}
			if strings.Contains(err.Error(), owner.Private) {
				t.Fatal("error leaked private identity")
			}
		})
	}
}

const recipientMetadataCanary = "METADATA-MUST-NOT-LEAK-9AE2"

func TestRecipientAPIsRefuseNonNativeAgeOnlyMetadata(t *testing.T) {
	owner := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, owner, plainYAML)

	for name, mutate := range map[string]func(*sops.Tree){
		"multiple groups": func(tree *sops.Tree) {
			tree.Metadata.KeyGroups = append(tree.Metadata.KeyGroups, tree.Metadata.KeyGroups[0])
		},
		"mixed backend": func(tree *sops.Tree) {
			tree.Metadata.KeyGroups[0] = append(tree.Metadata.KeyGroups[0], &pgp.MasterKey{
				Fingerprint: recipientMetadataCanary,
			})
		},
		"plugin hybrid": func(tree *sops.Tree) {
			tree.Metadata.KeyGroups[0] = append(tree.Metadata.KeyGroups[0], &sopsage.MasterKey{
				Recipient: "age1plugin1" + recipientMetadataCanary,
			})
		},
	} {
		t.Run(name, func(t *testing.T) {
			malformed := mutateRecipientMetadata(t, encrypted, mutate)

			_, err := Recipients(malformed)
			assertRecipientMetadataRefusal(t, "Recipients", err, owner)

			_, err = UpdateRecipients(malformed, []string{owner.Public}, owner.Private)
			assertRecipientMetadataRefusal(t, "UpdateRecipients", err, owner)
		})
	}
}

func mutateRecipientMetadata(t *testing.T, encrypted []byte, mutate func(*sops.Tree)) []byte {
	t.Helper()
	sf, err := FormatYAML.toSopsFormat()
	if err != nil {
		t.Fatalf("YAML format: %v", err)
	}
	store := common.StoreForFormat(sf, config.NewStoresConfig())
	tree, err := store.LoadEncryptedFile(encrypted)
	if err != nil {
		t.Fatalf("load encrypted fixture: %v", err)
	}
	mutate(&tree)
	out, err := store.EmitEncryptedFile(tree)
	if err != nil {
		t.Fatalf("emit metadata fixture: %v", err)
	}
	return out
}

func assertRecipientMetadataRefusal(t *testing.T, api string, err error, owner ageKeyPair) {
	t.Helper()
	if err == nil {
		t.Fatalf("%s accepted non-native-age metadata", api)
	}
	if err.Error() != errDocumentNotAgeOnly.Error() {
		t.Fatalf("%s did not return the expected fixed error text", api)
	}
	for _, secret := range []string{owner.Private, recipientMetadataCanary} {
		if strings.Contains(err.Error(), secret) {
			t.Fatalf("%s error leaked protected input", api)
		}
	}
}
