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

// TestResultRecoveryCatchesMutations is the fixture set `inspectResultRecovery`
// did not have.
//
// It had none: all twelve cases above target `inspectGuardWiring`, and the four
// mutations behind the `result` rules were run by hand once and thrown away —
// exactly what this file's own header says not to do. A review then found a
// shape the hand-run mutations had missed, and it was the worst of them: a
// `recover()` inside a nested goroutine, which returns nil, lets the panic
// terminate the host, and reported `ok`.
func TestResultRecoveryCatchesMutations(t *testing.T) {
	mutations := []struct {
		name     string
		source   string
		expected string
	}{
		{
			// What defeated the substring check: a comment is body text.
			name: "the recover is gone and only a comment names it",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	// TODO: restore the recover() here before shipping.
	return statusOK
}`,
			expected: "not the required shape",
		},
		{
			name: "no defer at all, recover called inline",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	if recover() != nil {
		status = statusFailure
	}
	return statusOK
}`,
			expected: "not the required shape",
		},
		{
			// Swallows the panic and falls off the end, returning a zero
			// status: success, for a call that panicked.
			name: "a bare recover that swallows and does nothing",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		recover()
	}()
	return statusOK
}`,
			expected: "not the required shape",
		},
		{
			// The one the hand-run mutations missed. recover() returns nil
			// anywhere but directly inside the deferred function, so this is
			// worse than having no recover: the panic escapes, and the test
			// used to say ok.
			name: "recover moved into a goroutine, where it returns nil",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		go func() {
			if r := recover(); r != nil {
				status = statusFailure
			}
		}()
	}()
	return statusOK
}`,
			expected: "not the required shape",
		},
		{
			// Notices the panic and returns success anyway.
			name: "the recovered value is bound and then discarded",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		r := recover()
		_ = r
	}()
	return statusOK
}`,
			expected: "not the required shape",
		},
		{
			name: "the recover branch is empty",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
		}
	}()
	return statusOK
}`,
			expected: "not the required shape",
		},
		{
			// `:=` shadows rather than sets. Looks right, does nothing.
			name: "the closure declares a new status instead of setting the result",
			source: `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
			status := statusFailure
			_ = status
		}
	}()
	return statusOK
}`,
			expected: "not the required shape",
		},
	}

	for _, mutation := range mutations {
		t.Run(mutation.name, func(t *testing.T) {
			complaints, err := inspectResultRecovery(resultFixture(mutation.source))
			if err != nil {
				t.Fatalf("parse fixture: %v", err)
			}
			if len(complaints) == 0 {
				t.Fatalf("mutation went unnoticed; expected a complaint about %q", mutation.expected)
			}
			for _, complaint := range complaints {
				if strings.Contains(complaint, mutation.expected) {
					return
				}
			}
			t.Fatalf("complaints %q mention nothing about %q", complaints, mutation.expected)
		})
	}
}

// TestResultRecoveryAcceptsTheRealShape guards the other direction: the rules
// must not reject the source actually shipping, or the fixtures above would be
// satisfied by a check that complains about everything.
func TestResultRecoveryAcceptsTheRealShape(t *testing.T) {
	source := `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
			if out != nil {
				*out = nil
			}
			status = statusFailure
		}
	}()
	return statusOK
}`
	complaints, err := inspectResultRecovery(resultFixture(source))
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(complaints) != 0 {
		t.Fatalf("the shipped shape was rejected: %q", complaints)
	}
}

// resultFixture wraps a `result` definition in the minimum that parses.
func resultFixture(body string) string {
	return "package main\n\nimport \"C\"\n\nconst (\n\tstatusOK      C.int = 0\n\tstatusFailure C.int = 1\n)\n\n" + body + "\n"
}

// TestResultRecoveryRejectsASelfAssignment is its own function rather than
// another row in the table above because it is the mutation that got through
// the rules those rows were written for.
//
// `status = status` satisfies every earlier rule — deferred closure, recover
// feeding a condition, no nested literal, an assignment to a named result —
// and swallows the panic, returning `statusOK`. `go vet` is silent and all 158
// Go tests passed. The rule now asks whether the assignment moves anything.
func TestResultRecoveryRejectsASelfAssignment(t *testing.T) {
	source := `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
			status = status
		}
	}()
	return statusOK
}`
	complaints, err := inspectResultRecovery(resultFixture(source))
	if err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	if len(complaints) == 0 {
		t.Fatal("a self-assignment was accepted: the panic is swallowed and reported as success")
	}
}

// TestResultRecoveryRejectsEverySwallowShape is the table the previous two
// attempts at this rule needed.
//
// Rule 5 was first "assigns to a named result", then "assigns something other
// than itself". A review walked through seven shapes that satisfied the second
// and still reported a panicking call as a success. Enumerating wrong answers
// was the mistake; the rule now names the one right answer, and these are the
// regression cases for it.
func TestResultRecoveryRejectsEverySwallowShape(t *testing.T) {
	swallows := []struct{ name, branch string }{
		{"assigns the success constant", "status = statusOK"},
		{"assigns itself", "status = status"},
		{"adds zero", "status += 0"},
		{"assigns itself in parentheses", "status = (status)"},
		{"adds zero the long way", "status = status + 0"},
		{"assigns a zero conversion", "status = C.int(0)"},
		{"ors zero", "status |= 0"},
		{"multiplies by one", "status *= 1"},
		{"assigns a zero-valued local", "var z C.int\n\t\t\tstatus = z"},
	}

	for _, swallow := range swallows {
		t.Run(swallow.name, func(t *testing.T) {
			source := `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
			` + swallow.branch + `
		}
	}()
	return statusOK
}`
			complaints, err := inspectResultRecovery(resultFixture(source))
			if err != nil {
				t.Fatalf("parse fixture: %v", err)
			}
			if len(complaints) == 0 {
				t.Fatalf("accepted %q: a recovered panic is reported as success", swallow.branch)
			}
		})
	}
}

// TestResultRecoveryAcceptsTheOnlyRightAnswer is the other half: the rule must
// not have become "complain about everything", which would satisfy the table
// above for no reason at all.
func TestResultRecoveryAcceptsTheOnlyRightAnswer(t *testing.T) {
	for _, branch := range []string{
		"status = statusFailure",
		"status = (statusFailure)",
	} {
		source := `func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
			` + branch + `
		}
	}()
	return statusOK
}`
		complaints, err := inspectResultRecovery(resultFixture(source))
		if err != nil {
			t.Fatalf("parse fixture: %v", err)
		}
		if len(complaints) != 0 {
			t.Fatalf("rejected the correct shape %q: %v", branch, complaints)
		}
	}
}

// TestResultRecoveryRejectsWrittenButUnreachedFailures covers the round of
// attacks that the value check could not see.
//
// Rule 5 asked whether `status = statusFailure` was *written*. A review pointed
// out that says nothing about whether it *runs*, and produced six shapes that
// wrote it and still returned success. The rule now requires the one canonical
// shape instead of describing wrong ones; these are its regression cases.
func TestResultRecoveryRejectsWrittenButUnreachedFailures(t *testing.T) {
	bodies := []struct{ name, body string }{
		{
			name: "a later assignment overwrites the failure",
			body: `	defer func() {
		if recover() != nil {
			status = statusFailure
			status = statusOK
		}
	}()`,
		},
		{
			// The nastiest of the set: reads as tidying up, and makes
			// `statusFailure` mean success inside this closure only.
			name: "statusFailure is shadowed by a local constant",
			body: `	defer func() {
		const statusFailure C.int = 0
		if recover() != nil {
			status = statusFailure
		}
	}()`,
		},
		{
			name: "a second defer undoes the first by LIFO",
			body: `	defer func() {
		if recover() != nil {
			status = statusFailure
		}
	}()
	defer func() {
		status = statusOK
	}()`,
		},
		{
			name: "the condition is inverted",
			body: `	defer func() {
		if recover() == nil {
			status = statusFailure
		}
	}()`,
		},
		{
			name: "the assignment sits in an unreachable branch",
			body: `	defer func() {
		if recover() != nil {
			if false {
				status = statusFailure
			}
		}
	}()`,
		},
		{
			name: "the assignment sits in a loop that never runs",
			body: `	defer func() {
		if recover() != nil {
			for i := 0; i < 0; i++ {
				status = statusFailure
			}
		}
	}()`,
		},
	}

	for _, shape := range bodies {
		t.Run(shape.name, func(t *testing.T) {
			source := "func result(out **C.char, payload []byte, err error) (status C.int) {\n" +
				shape.body + "\n\treturn statusOK\n}"
			complaints, err := inspectResultRecovery(resultFixture(source))
			if err != nil {
				t.Fatalf("parse fixture: %v", err)
			}
			if len(complaints) == 0 {
				t.Fatalf("accepted a shape that writes statusFailure but never reaches it:\n%s",
					shape.body)
			}
		})
	}
}
