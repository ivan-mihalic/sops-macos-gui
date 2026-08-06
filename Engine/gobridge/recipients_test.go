package gobridge

import (
	"reflect"
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
