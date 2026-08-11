package gobridge

import (
	"reflect"
	"strings"
	"testing"
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
		"empty":   {nil, errRecipientsEmpty},
		"private": {[]string{owner.Private}, errRecipientPrivate},
		"plugin":  {[]string{"age1yubikey1qwbmkfqzrqzc4dm5dqrgcnpq6r0dsmrpqzr"}, errRecipientPlugin},
		"invalid": {[]string{"not-an-age-recipient"}, errRecipientInvalid},
	} {
		t.Run(name, func(t *testing.T) {
			_, err := UpdateRecipients(encrypted, tc.recipients, owner.Private)
			if err == nil {
				t.Fatal("unsafe recipients were accepted")
			}
			if err.Error() != tc.want.Error() {
				t.Fatalf("UpdateRecipients error = %q, want fixed text %q", err, tc.want)
			}
			if strings.Contains(err.Error(), owner.Private) {
				t.Fatalf("error leaked private identity: %v", err)
			}
		})
	}
}
