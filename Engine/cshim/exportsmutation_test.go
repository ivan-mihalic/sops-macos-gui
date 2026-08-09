package main

// The mutations `exports_test.go`'s guard-wiring check has to catch, kept as
// permanent cases rather than as something a reviewer once tried by hand and
// wrote down in a report.
//
// This exists because of how the previous check failed. It was
// `strings.Contains(body, "gobridge.Guard(")`, it was the sole evidence for
// PROPOSAL §9's "all nine cgo entry points recover", and it passed with the
// guard deleted — a comment reading `// TODO: wrap in gobridge.Guard( ... )`
// satisfied it. Nothing in the repository would have told anyone that. A
// checker is only as good as the mutations it is shown to reject, so the
// mutations live here, next to it, and run on every `go test ./cshim/`.
//
// Each fixture is a whole parseable file rather than a fragment, because
// go/parser is what the checker uses and a fragment would be testing something
// else. They are deliberately *not* copies of main.go: a fixture that drifted
// into agreement with main.go would stop testing the rule and start testing
// the file.

import (
	"strings"
	"testing"
)

// fixture wraps one entry-point body in the minimum file go/parser accepts.
// The imports are never resolved — this is syntax analysis, so the names only
// have to parse.
func fixture(entryPoint string) string {
	return `package main

/*
#include <stdlib.h>
*/
import "C"

import "github.com/ivan-mihalic/sops-macos-gui/engine/gobridge"

` + entryPoint + `
`
}

// The shape every entry point is supposed to have. If this one ever fails, the
// rule has become stricter than the code it governs and the mutations below
// prove nothing.
const wellFormedEntryPoint = `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte(C.GoString(in)), C.GoString(in))
	})
	return result(out, payload, err)
}`

const wellFormedVoidEntryPoint = `// sops_thing_void does a thing with nothing to report.
//
//export sops_thing_void
func sops_thing_void(p *C.char) {
	_ = gobridge.GuardVoid(gobridge.OpReleasing, func() {
		if p == nil {
			return
		}
		C.free(unsafe.Pointer(p))
	})
}`

func TestGuardWiringAcceptsTheRequiredShape(t *testing.T) {
	for _, source := range []string{wellFormedEntryPoint, wellFormedVoidEntryPoint} {
		exports, complaints, err := inspectGuardWiring(fixture(source))
		if err != nil {
			t.Fatalf("parse fixture: %v", err)
		}
		if len(exports) != 1 {
			t.Fatalf("expected 1 //export in the fixture, found %v", exports)
		}
		if len(complaints) != 0 {
			t.Errorf("the required shape was rejected: %v", complaints)
		}
	}
}

// TestGuardWiringCatchesMutations is the whole point of the rewrite: every one
// of these is a real way an entry point can stop being guarded, and the two
// marked "passed the old substring check" are the two that were verified to
// slip through it.
func TestGuardWiringCatchesMutations(t *testing.T) {
	mutations := []struct {
		name     string
		source   string
		expected string
	}{
		{
			// Passed the old substring check. Verified against the real
			// main.go before this rewrite: `go test ./cshim/` reported ok.
			name: "guard deleted, a comment naming it left behind",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	// TODO: wrap in gobridge.Guard( ... ) one day
	payload, err := gobridge.Do([]byte(C.GoString(in)))
	return result(out, payload, err)
}`,
			expected: "runs no gobridge.Guard/GuardVoid at all",
		},
		{
			// Passed the old substring check too: the guard is right there in
			// the body, it just no longer covers the conversion.
			name: "work hoisted above an otherwise intact guard",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	plain := C.GoString(in)
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte(plain))
	})
	return result(out, payload, err)
}`,
			expected: "calls C.GoString(…) outside any guard",
		},
		{
			// The sibling of "work hoisted above an otherwise intact guard",
			// and it survived that rule for a while: moved a few characters
			// to the right, into the guard's own argument list, the same
			// conversion was invisible. Go evaluates an argument list before
			// entering the function, so this runs exactly as unguarded as the
			// hoisted version — the rule had been keying on lexical position
			// rather than on when the code runs.
			name: "work smuggled into the guard's argument list",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpFor(C.GoString(in)), func() ([]byte, error) {
		return gobridge.Do(nil)
	})
	return result(out, payload, err)
}`,
			expected: "calls C.GoString(…) outside any guard",
		},
		{
			// Passes every other rule: the guard is present, unconditional,
			// nothing runs outside it, and `result` is handed the very
			// identifiers the guard bound. One assignment in between empties
			// the answer, so a recovered panic returns status 0 with no
			// payload — a blank document the user can then save over the real
			// file.
			name: "the guard's error is thrown away after it was bound",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do(nil)
	})
	err = nil
	return result(out, payload, err)
}`,
			expected: "reassigns err after the guard bound it",
		},
		{
			name: "work left dangling after the guard",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do(nil)
	})
	payload = append(payload, C.GoString(in)...)
	return result(out, payload, err)
}`,
			expected: "outside any guard",
		},
		{
			name: "guard runs but its error is discarded",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	_, _ = gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte(C.GoString(in)))
	})
	return result(out, nil, nil)
}`,
			expected: "passes something other than the guard's own payload to result",
		},
		{
			name: "guard runs but the status is fabricated",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	_, _ = gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte(C.GoString(in)))
	})
	return statusOK
}`,
			expected: "does not end in `return result(out, …)`",
		},
		{
			name: "an early return before the guard",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	if in == nil {
		return statusFailure
	}
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte(C.GoString(in)))
	})
	return result(out, payload, err)
}`,
			expected: "return statements outside its guard, expected exactly 1",
		},
		{
			name: "the guard is conditional, so some paths run unguarded",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	var payload []byte
	var err error
	if in != nil {
		payload, err = gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
			return gobridge.Do(nil)
		})
	}
	return result(out, payload, err)
}`,
			expected: "not as a statement of its own body",
		},
		{
			name: "a pointer is dereferenced outside the guard",
			source: `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	first := *in
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte{byte(first)})
	})
	return result(out, payload, err)
}`,
			expected: "dereferences a pointer outside any guard",
		},
		{
			name: "a tenth entry point added with no guard at all",
			source: wellFormedEntryPoint + `

// sops_new_thing was added six months later by someone who never read this.
//
//export sops_new_thing
func sops_new_thing(in *C.char, out **C.char) C.int {
	payload, err := gobridge.Do([]byte(C.GoString(in)))
	return result(out, payload, err)
}`,
			expected: "sops_new_thing runs no gobridge.Guard/GuardVoid at all",
		},
		{
			name: "the void entry point loses its guard",
			source: `// sops_thing_void does a thing with nothing to report.
//
//export sops_thing_void
func sops_thing_void(p *C.char) {
	if p == nil {
		return
	}
	C.free(unsafe.Pointer(p))
}`,
			expected: "runs no gobridge.Guard/GuardVoid at all",
		},
	}

	for _, mutation := range mutations {
		t.Run(mutation.name, func(t *testing.T) {
			_, complaints, err := inspectGuardWiring(fixture(mutation.source))
			if err != nil {
				t.Fatalf("parse fixture: %v", err)
			}
			if len(complaints) == 0 {
				t.Fatalf("the mutation was accepted; this is exactly what the old "+
					"substring check did. Expected a complaint containing %q",
					mutation.expected)
			}
			for _, complaint := range complaints {
				if strings.Contains(complaint, mutation.expected) {
					return
				}
			}
			t.Errorf("complained, but not about the right thing.\nwanted a complaint containing: %q\ngot: %v",
				mutation.expected, complaints)
		})
	}
}

// TestGuardWiringWouldHaveFailedTheOldSubstringCheck pins the specific reason
// the previous check was worthless, so that nobody reintroduces it as a
// "simpler" version of the same idea. Both of these bodies contain the literal
// text `gobridge.Guard(` and neither is guarded.
func TestGuardWiringWouldHaveFailedTheOldSubstringCheck(t *testing.T) {
	deleted := `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	// TODO: wrap in gobridge.Guard( ... ) one day
	payload, err := gobridge.Do([]byte(C.GoString(in)))
	return result(out, payload, err)
}`
	hoisted := `// sops_thing does a thing.
//
//export sops_thing
func sops_thing(in *C.char, out **C.char) C.int {
	plain := C.GoString(in)
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Do([]byte(plain))
	})
	return result(out, payload, err)
}`

	for _, source := range []string{deleted, hoisted} {
		if !strings.Contains(source, "gobridge.Guard(") {
			t.Fatal("the fixture no longer demonstrates the old check's blind spot")
		}
		_, complaints, err := inspectGuardWiring(fixture(source))
		if err != nil {
			t.Fatalf("parse fixture: %v", err)
		}
		if len(complaints) == 0 {
			t.Error("a body containing the literal text `gobridge.Guard(` was accepted " +
				"even though nothing in it is guarded")
		}
	}
}
