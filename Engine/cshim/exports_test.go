package main

// The exported entry points cannot be called the normal way from a Go test:
// `go test` refuses cgo in _test.go files ("use of cgo in test not
// supported"), so this file cannot itself `import "C"` to build a *C.char.
// Their behaviour used to be proved from both sides instead —
// gobridge/enginefault_test.go exercises the guard itself against the real
// hostile document, and Tests/SopsEngineTests/HostileDocumentTests.swift
// drives the actual C symbols through the built xcframework — with nothing
// in between calling the //export functions from Go.
//
// What is left for the *rest* of this file (the guard-wiring checks below)
// is the thing neither of those can see: whether every //export is *wired* to
// the guard. That is the failure mode with a future — a thirteenth entry
// point added without one, six months from now, by someone who never read
// this. So it is checked structurally, against the source, rather than
// trusted to review.
//
// # Why this is an AST check and not a strings.Contains
//
// It used to be `strings.Contains(body, "gobridge.Guard(")`, and that check was
// vacuous. Verified, not suspected: delete the guard from sops_decrypt_yaml
// (this package's entry point of that name, before SOPS-38 generalized it to
// sops_decrypt), leave the comment `// TODO: wrap in gobridge.Guard( ... ) one
// day` behind, and `go test ./cshim/` reported ok. Hoisting the real work
// above an otherwise-intact guard passed too. Since this test is the sole
// evidence for PROPOSAL §9's claim that all twelve entry points recover, a
// check that a comment can satisfy is worse than no check — it is a claim
// nobody will re-examine.
//
// So the shape is asserted instead, in `complaintsAbout` below, and the
// mutations that used to slip through are in `TestGuardWiringCatchesMutations`
// as permanent cases rather than as something a reviewer once tried by hand.
//
// # SOPS-38: calling the real //export functions turned out to be possible
//
// The claim above — "the exported entry points cannot be called from a Go
// test" — is true of the direct route (`import "C"` in this file) and stays
// true. But cgo preprocessing main.go's own `import "C"` generates ordinary
// Go type declarations for every C type it uses, under names of its own
// (`_Ctype_char` for `C.char`), and those land in a normal generated .go file
// that becomes part of this package exactly like any other. A _test.go file
// may refer to a package-level type without itself producing any cgo
// directive — the restriction is on `import "C"` appearing in the test file,
// not on using types cgo already put in the package elsewhere. Verified
// directly on this toolchain (go1.26.5, darwin/arm64) with a two-file scratch
// package before relying on it here: a `//export`ed cgo function plus a
// same-package _test.go referencing `_Ctype_char` (no cgo import of its own)
// builds and runs `go test` cleanly; adding `import "C"` to that same test
// file reproduces the documented failure verbatim.
//
// `cToGoString`/`goToCString` below reimplement C.GoString/C.CString's memory
// shape (a NUL-terminated byte run) using unsafe.Add/unsafe.Slice rather than
// the uintptr-arithmetic pattern `go vet`'s unsafeptr check exists to flag.
// goToCString hands back ordinary Go-heap memory the garbage collector already
// owns — nothing here calls C.malloc, so there is nothing to free on the
// input side. The one pointer this file must release is whatever an export
// writes into *out, and that goes through the real sops_free — a genuine cgo
// function defined in main.go — so freeing still exercises production code,
// not a test-only stand-in for it.
//
// This does not replace the AST checks: they are the only thing that can
// assert every entry point is wired the same way, cheaply, without a fixture
// per function. What the two behavioural tests below exist for is the one
// thing an AST walk cannot see — whether the `format` string an export
// receives actually reaches the gobridge call that switches on it, as opposed
// to a stray unconverted use or a leftover hardcoded gobridge.FormatYAML the
// AST check has no opinion about either way.

import (
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
	"testing"
	"unsafe"

	"filippo.io/age"

	"github.com/ivan-mihalic/sops-macos-gui/engine/gobridge"
)

// exportedEntryPointCount is asserted rather than derived so that adding an
// entry point is a deliberate act that updates this number, and cannot happen
// by accident.
const exportedEntryPointCount = 13

// TestEveryExportedEntryPointRecoversFromPanics checks the real main.go.
func TestEveryExportedEntryPointRecoversFromPanics(t *testing.T) {
	// A nil src makes go/parser read the named file from the package
	// directory, which is the point: this asserts against the shipped source,
	// not against a copy of it.
	exports, complaints, err := inspectGuardWiring(nil)
	if err != nil {
		t.Fatalf("parse main.go: %v", err)
	}

	if len(exports) != exportedEntryPointCount {
		t.Fatalf("found %d //export'ed entry points, expected %d: %v",
			len(exports), exportedEntryPointCount, exports)
	}

	for _, complaint := range complaints {
		t.Errorf("%s", complaint)
	}
}

// goToCString copies s into a NUL-terminated byte run and returns it typed as
// cgo's own *C.char, spelled under the name cgo generated for it in this
// package (see this file's header comment for why that is safe here and
// nowhere near safe as a general trick). The backing array is ordinary
// Go-heap memory: nothing frees it explicitly, and nothing needs to.
func goToCString(s string) *_Ctype_char {
	b := make([]byte, len(s)+1) // trailing NUL; correct even for s == ""
	copy(b, s)
	return (*_Ctype_char)(unsafe.Pointer(&b[0]))
}

// cToGoString reads a NUL-terminated *C.char back into a Go string. It never
// frees p — see sops_free for the one call in this file that does.
func cToGoString(p *_Ctype_char) string {
	if p == nil {
		return ""
	}
	n := 0
	for *(*byte)(unsafe.Add(unsafe.Pointer(p), n)) != 0 {
		n++
	}
	return string(unsafe.Slice((*byte)(unsafe.Pointer(p)), n))
}

// newTestAgeKey generates a throwaway X25519 identity, exactly the shape
// parseDecryptionIdentities requires (AGE-SECRET-KEY-1…). Nothing here is
// ever written to disk.
func newTestAgeKey(t *testing.T) (public, private string) {
	t.Helper()
	id, err := age.GenerateX25519Identity()
	if err != nil {
		t.Fatalf("generate age identity: %v", err)
	}
	return id.Recipient().String(), id.String()
}

func mustJSONString(t *testing.T, v any) string {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatalf("marshal %#v: %v", v, err)
	}
	return string(b)
}

// TestBogusFormatFailsCleanlyAcrossEveryFormatTakingExport calls every
// //export that takes a format string with format="bogus" and checks the one
// thing PROPOSAL and this task's brief both require: statusFailure, a message
// (never a crash), and no echo of the document content or key material this
// test seeds each call with as a canary.
//
// Every one of these gobridge functions validates format via
// Format.toSopsFormat() before parsing any document content (bridge.go,
// document.go's loadAndDecrypt, recipients.go, leafencryption.go all do this
// as one of their first steps — see gobridge for the exact call sites) and
// returns an ordinary error, so nothing here needs a second, cshim-side
// validation layer: the existing gobridge.Guard/result plumbing already turns
// that error into statusFailure. This test is what proves that, rather than
// assuming it from reading the source.
func TestBogusFormatFailsCleanlyAcrossEveryFormatTakingExport(t *testing.T) {
	public, private := newTestAgeKey(t)
	const canary = "canary-document-content-should-never-appear-in-an-error-3f81c2"

	format := goToCString("bogus")
	recipientsJSON := goToCString(mustJSONString(t, []string{public}))
	key := goToCString(private)
	encrypted := goToCString(canary)
	plain := goToCString(canary)

	cases := []struct {
		name string
		call func() (status _Ctype_int, out *_Ctype_char)
	}{
		{"sops_encrypt", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_encrypt(plain, format, goToCString(public), goToCString(""), &out)
			return status, out
		}},
		{"sops_decrypt", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_decrypt(encrypted, format, key, &out)
			return status, out
		}},
		{"sops_decrypt_to_rows", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_decrypt_to_rows(encrypted, format, key, &out)
			return status, out
		}},
		{"sops_apply_edits", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_apply_edits(encrypted, format, goToCString("[]"), key, &out)
			return status, out
		}},
		{"sops_apply_changes", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_apply_changes(encrypted, format, goToCString("{}"), key, &out)
			return status, out
		}},
		{"sops_recipients", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_recipients(encrypted, format, &out)
			return status, out
		}},
		{"sops_update_recipients", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_update_recipients(encrypted, format, recipientsJSON, key, &out)
			return status, out
		}},
		{"sops_leaf_encryption_summary", func() (_Ctype_int, *_Ctype_char) {
			var out *_Ctype_char
			status := sops_leaf_encryption_summary(encrypted, format, &out)
			return status, out
		}},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			status, out := c.call()
			if status != statusFailure {
				t.Fatalf("format=%q: expected statusFailure, got status %v", "bogus", status)
			}
			if out == nil {
				t.Fatal("statusFailure but *out was left nil: Swift sees \"bridge returned no result\" instead of a message")
			}
			envelopeJSON := cToGoString(out)
			sops_free(out)

			// *out on failure is a JSON errorEnvelope, not err.Error() raw
			// (see result() in main.go) — decode it the way the Swift side
			// does rather than substring-matching the JSON-escaped text.
			var envelope errorEnvelope
			if err := json.Unmarshal([]byte(envelopeJSON), &envelope); err != nil {
				t.Fatalf("*out on failure did not decode as an error envelope: %v\nraw: %s", err, envelopeJSON)
			}
			if !strings.Contains(envelope.Message, "unsupported format") || !strings.Contains(envelope.Message, "bogus") {
				t.Errorf("expected the error envelope to name the unsupported format, got: %q", envelope.Message)
			}
			if strings.Contains(envelope.Message, canary) {
				t.Errorf("error envelope echoed the document/key canary value: %q", envelope.Message)
			}
			if strings.Contains(envelope.Message, private) {
				t.Errorf("error envelope echoed the private key")
			}
		})
	}
}

// TestDotenvFormatReachesGobridgeThroughDecryptToRowsAndUpdateRecipients is
// the positive half: format="dotenv" must actually select the dotenv store,
// not merely fail to crash. It proves this two ways at once — a call that
// should succeed does, with dotenv-shaped output, and the *same* encrypted
// document handed to the *same* export with format="yaml" fails. If the
// format parameter were ignored (e.g. a leftover hardcoded gobridge.FormatYAML
// after the SOPS-38 rewrite), both calls would behave identically; they do
// not, so the string genuinely reaches gobridge.
func TestDotenvFormatReachesGobridgeThroughDecryptToRowsAndUpdateRecipients(t *testing.T) {
	owner, ownerPrivate := newTestAgeKey(t)
	const dotenvPlain = "DB_URL=postgres://x\nAPI_KEY=secret\n"

	encryptedBytes, err := gobridge.Encrypt([]byte(dotenvPlain), gobridge.FormatDotenv,
		gobridge.EncryptOpts{AgeRecipients: []string{owner}})
	if err != nil {
		t.Fatalf("seed fixture: gobridge.Encrypt: %v", err)
	}

	encrypted := goToCString(string(encryptedBytes))
	dotenvFormat := goToCString("dotenv")
	yamlFormat := goToCString("yaml")
	key := goToCString(ownerPrivate)

	// format="dotenv" on a genuinely dotenv document succeeds and returns the
	// flat, one-segment-path rows only the dotenv store produces (see
	// gobridge/dotenv_test.go).
	var rowsOut *_Ctype_char
	status := sops_decrypt_to_rows(encrypted, dotenvFormat, key, &rowsOut)
	if status != statusOK {
		t.Fatalf("sops_decrypt_to_rows(format=dotenv) failed: %s", cToGoString(rowsOut))
	}
	rowsJSON := cToGoString(rowsOut)
	sops_free(rowsOut)

	var rows []struct {
		Path  []string `json:"path"`
		Value string   `json:"value"`
	}
	if err := json.Unmarshal([]byte(rowsJSON), &rows); err != nil {
		t.Fatalf("rows JSON did not decode: %v\n%s", err, rowsJSON)
	}
	got := map[string]string{}
	for _, row := range rows {
		if len(row.Path) != 1 {
			t.Fatalf("dotenv row has a nested path %v; dotenv has no nesting", row.Path)
		}
		got[row.Path[0]] = row.Value
	}
	if got["DB_URL"] != "postgres://x" || got["API_KEY"] != "secret" {
		t.Fatalf("dotenv rows did not round-trip the fixture: %v", got)
	}

	// The discriminating half: the same bytes, same export, format="yaml"
	// instead. The dotenv store's on-disk shape is not valid YAML, so this
	// must fail — proving the parameter, not a hardcoded default, decided
	// which store parsed encrypted.
	var wrongFormatOut *_Ctype_char
	status = sops_decrypt_to_rows(encrypted, yamlFormat, key, &wrongFormatOut)
	if status != statusFailure {
		t.Fatalf("sops_decrypt_to_rows(format=yaml) on a dotenv document unexpectedly succeeded: "+
			"the format parameter is not reaching gobridge (status=%v)", status)
	}
	sops_free(wrongFormatOut)

	// sops_update_recipients: format="dotenv" must both read and re-emit
	// dotenv, and the result must decrypt under the *new* recipient.
	newRecipient, newPrivate := newTestAgeKey(t)
	recipientsJSON := goToCString(mustJSONString(t, []string{newRecipient}))

	var updatedOut *_Ctype_char
	status = sops_update_recipients(encrypted, dotenvFormat, recipientsJSON, key, &updatedOut)
	if status != statusOK {
		t.Fatalf("sops_update_recipients(format=dotenv) failed: %s", cToGoString(updatedOut))
	}
	rewrapped := cToGoString(updatedOut)
	sops_free(updatedOut)

	dec, err := gobridge.Decrypt([]byte(rewrapped), gobridge.FormatDotenv, newPrivate)
	if err != nil {
		t.Fatalf("re-decrypting the rewrapped document with the new recipient failed: %v", err)
	}
	if !strings.Contains(string(dec), "DB_URL=postgres://x") || !strings.Contains(string(dec), "API_KEY=secret") {
		t.Fatalf("rewrapped dotenv document lost content: %s", dec)
	}
}

// TestResultRecoversToo. `result` is the one step that runs outside the guard,
// because it is what writes the guard's own message out. If it can panic, the
// whole chain has a hole at the end of it.
//
// What its recover covers is narrower than this test can see and narrower than
// this file once claimed — a nil `out` and C.CString's "string too large"
// panic, but *not* an allocation failure, which reaches runtime.throw and is
// fatal everywhere. `result`'s own doc comment in main.go states the three
// cases and why. All this test establishes is that the recover is still there.
func TestResultRecoversToo(t *testing.T) {
	complaints, err := inspectResultRecovery(nil)
	if err != nil {
		t.Fatalf("parse main.go: %v", err)
	}
	for _, complaint := range complaints {
		t.Error(complaint)
	}
}

// inspectResultRecovery checks `result`'s own recover by structure rather than
// by looking for the text "recover()" somewhere in the body.
//
// The substring version of this test passed with the whole deferred closure
// deleted and `// TODO: restore the recover() here before shipping.` left in
// its place — a comment is body text too. Its sibling
// TestEveryExportedEntryPointRecoversFromPanics had already been rewritten onto
// the AST for the same reason; this one was left behind, and the commit that
// rewrote the sibling claimed both.
//
// Three rules, each for a mutation the substring check waved through:
//
//  1. The body contains a `defer` of a function literal — not a bare mention of
//     recover in a comment, a string, or dead code.
//  2. That literal calls the builtin `recover()`.
//  3. It does something with the result. A `defer func() { recover() }()`
//     swallows the panic and then falls off the end of the function, returning
//     whatever the named results happen to hold — for `result` that is a zero
//     status, i.e. success reported for a call that panicked.
//  4. No nested function literal. `recover` only works called directly by the
//     deferred function, so `go func() { recover() }()` inside it is worse than
//     no recover at all: the panic escapes and the test says OK.
//  5. The closure assigns to a **named result**. This is the rule that means
//     something on its own — rules 2 and 3 ask whether recover is called and
//     used, this one asks whether the answer can reach the caller. It rejects
//     `r := recover(); _ = r`, an `if recover() != nil {}` with an empty body,
//     and anything else that notices the panic and returns success anyway.
func inspectResultRecovery(src any) (complaints []string, err error) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "main.go", src, parser.ParseComments)
	if err != nil {
		return nil, err
	}

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name.Name != "result" || fn.Body == nil {
			continue
		}
		return complaintsAboutResultRecovery(fn), nil
	}
	return []string{"no function named result in main.go"}, nil
}

// complaintsAboutResultRecovery requires the one canonical shape rather than
// trying to name the wrong ones.
//
// Three rounds of this rule each described a *shape* and each was walked
// around. "Assigns to a named result" fell to `status = status`. "Assigns
// something other than itself" fell to seven more, `status = statusOK` worst
// among them because it reads like error handling. "Assigns statusFailure"
// then fell to a review that pointed out the rule only asked whether the
// statement was *written*, not whether it *runs*: a later `status = statusOK`
// overwriting it, a locally shadowed `const statusFailure C.int = 0`, a second
// `defer` winning by LIFO, an inverted `if recover() == nil`, or the donor
// sitting in `if false`.
//
// Enumerating attacks loses. There is exactly one correct implementation of
// this function's recover, so this asserts that and nothing else:
//
//	defer func() {
//	    if recover() != nil {
//	        …optional statements…
//	        status = statusFailure
//	    }
//	}()
//
// Exactly one `defer` in the body; a function literal; whose body is exactly
// one `if`; whose condition is `recover() != nil`; whose final statement
// assigns the package-level `statusFailure` to a named result; and no other
// assignment to a named result anywhere in the closure. A legitimate refactor
// will fail this, and should — it is the one line deciding whether a panicking
// call is reported as a failure.
func complaintsAboutResultRecovery(fn *ast.FuncDecl) []string {
	say := func(reason string) []string {
		return []string{"result's recover is not the required shape: " + reason +
			". A panic here reaches the Swift caller as a success"}
	}

	var defers []*ast.DeferStmt
	for _, stmt := range fn.Body.List {
		if deferred, ok := stmt.(*ast.DeferStmt); ok {
			defers = append(defers, deferred)
		}
	}
	if len(defers) != 1 {
		return say(fmt.Sprintf("expected exactly 1 defer, found %d (deferred functions run "+
			"last-in-first-out, so a second one can undo the first)", len(defers)))
	}

	lit, ok := defers[0].Call.Fun.(*ast.FuncLit)
	if !ok || lit.Body == nil {
		return say("the deferred call is not a function literal")
	}

	// recover() only works called directly by the deferred function.
	var nested bool
	ast.Inspect(lit.Body, func(n ast.Node) bool {
		if _, ok := n.(*ast.FuncLit); ok {
			nested = true
			return false
		}
		return true
	})
	if nested {
		return say("it contains a nested function literal, and recover() returns nil " +
			"anywhere but directly inside the deferred function")
	}

	if len(lit.Body.List) != 1 {
		return say(fmt.Sprintf("its body has %d statements, expected exactly 1 `if`",
			len(lit.Body.List)))
	}
	ifStmt, ok := lit.Body.List[0].(*ast.IfStmt)
	if !ok {
		return say("its body is not a single `if`")
	}
	if ifStmt.Else != nil {
		return say("the `if` has an else branch")
	}
	if !isRecoverIsNotNil(ifStmt.Cond) {
		return say("the condition is not `recover() != nil` (an inverted comparison " +
			"is a one-character change that disables the whole guard)")
	}
	if len(ifStmt.Body.List) == 0 {
		return say("the recover branch is empty")
	}

	// The failure assignment must be last, so nothing after it can overwrite.
	last, ok := ifStmt.Body.List[len(ifStmt.Body.List)-1].(*ast.AssignStmt)
	if !ok || !assignsFailureToResult(fn, last) {
		return say("its last statement is not `<named result> = statusFailure`")
	}

	// And nothing else in the closure may write a named result, so the value
	// that reaches the caller is the one this branch chose.
	names := namedResults(fn)
	var extra bool
	ast.Inspect(lit.Body, func(n ast.Node) bool {
		assign, ok := n.(*ast.AssignStmt)
		if !ok || assign == last {
			return true
		}
		for _, lhs := range assign.Lhs {
			if ident, ok := lhs.(*ast.Ident); ok && names[ident.Name] {
				extra = true
				return false
			}
		}
		return true
	})
	if extra {
		return say("another statement also assigns a named result, so the failure status " +
			"can be overwritten before the function returns")
	}

	return nil
}

// isRecoverIsNotNil matches `recover() != nil` exactly.
func isRecoverIsNotNil(expr ast.Expr) bool {
	binary, ok := expr.(*ast.BinaryExpr)
	if !ok || binary.Op != token.NEQ {
		return false
	}
	ident, ok := binary.Y.(*ast.Ident)
	return isRecoverCall(binary.X) && ok && ident.Name == "nil"
}

// namedResults returns fn's named result parameters.
func namedResults(fn *ast.FuncDecl) map[string]bool {
	names := map[string]bool{}
	if fn.Type.Results == nil {
		return names
	}
	for _, field := range fn.Type.Results.List {
		for _, ident := range field.Names {
			if ident.Name != "_" {
				names[ident.Name] = true
			}
		}
	}
	return names
}

// assignsFailureToResult matches `<named result> = statusFailure`.
func assignsFailureToResult(fn *ast.FuncDecl, assign *ast.AssignStmt) bool {
	if assign.Tok != token.ASSIGN || len(assign.Lhs) != 1 || len(assign.Rhs) != 1 {
		return false
	}
	lhs, ok := assign.Lhs[0].(*ast.Ident)
	if !ok || !namedResults(fn)[lhs.Name] {
		return false
	}
	return assignsFailure(assign.Rhs[0])
}

// assignsToNamedResult reports whether body assigns to any of fn's named
// result parameters. An unnamed result cannot be set from a deferred closure
// at all, so a `result` whose status stopped being named would fail this and
// should — that refactor silently removes the only way the recover can matter.
func assignsToNamedResult(fn *ast.FuncDecl, body *ast.BlockStmt) bool {
	names := map[string]bool{}
	if fn.Type.Results != nil {
		for _, field := range fn.Type.Results.List {
			for _, ident := range field.Names {
				if ident.Name != "_" {
					names[ident.Name] = true
				}
			}
		}
	}
	if len(names) == 0 {
		return false
	}

	assigns := false
	ast.Inspect(body, func(n ast.Node) bool {
		assign, ok := n.(*ast.AssignStmt)
		if !ok || assign.Tok != token.ASSIGN {
			// `:=` shadows the result rather than setting it. A compound
			// assignment (`+=`, `|=`) is not a write of a chosen value either
			// — it is arithmetic on whatever was already there, and
			// `status += 0` swallows a panic exactly as `status = status` did.
			return true
		}
		for i, lhs := range assign.Lhs {
			ident, ok := lhs.(*ast.Ident)
			if !ok || !names[ident.Name] {
				continue
			}
			if i < len(assign.Rhs) && assignsFailure(assign.Rhs[i]) {
				assigns = true
				return false
			}
		}
		return true
	})
	return assigns
}

// assignsFailure reports whether expr is the `statusFailure` constant.
//
// The rule was first "assigns to a named result", then "assigns something
// other than itself". Both described a *shape*, and a review found seven ways
// past the second: `status = statusOK`, `status += 0`, `status = (status)`,
// `status = status + 0`, `status = C.int(0)`, assignment from a zero-valued
// local, and `status |= 0`. Each satisfied the rule and turned a recovered
// panic into a reported success. `status = statusOK` is the dangerous one — it
// reads like error handling.
//
// So the rule is about the *value* now. There is exactly one right answer for
// `result`'s recover branch, so it says that rather than trying to enumerate
// the wrong ones. A refactor that legitimately renames the constant will fail
// this, and should: it is a change to the one line deciding whether a
// panicking call is reported as a failure.
func assignsFailure(expr ast.Expr) bool {
	for {
		switch e := expr.(type) {
		case *ast.ParenExpr:
			expr = e.X
		case *ast.Ident:
			return e.Name == "statusFailure"
		default:
			return false
		}
	}
}

// isRecoverCall reports whether n is a call to the builtin `recover`. It is a
// builtin rather than a package function, so an unqualified identifier is the
// only shape it can take.
func isRecoverCall(n ast.Node) bool {
	call, ok := n.(*ast.CallExpr)
	if !ok {
		return false
	}
	ident, ok := call.Fun.(*ast.Ident)
	return ok && ident.Name == "recover" && len(call.Args) == 0
}

// MARK: - The rule

// inspectGuardWiring parses `src` (nil means "read main.go from this
// directory") and returns the names of the //export'ed entry points it found
// together with every way in which one of them departs from the required
// shape.
//
// The required shape, for an entry point with a status result:
//
//	x, err := gobridge.Guard(op, func() ([]byte, error) { …all the work… })
//	return result(out, x, err)
//
// and for one without:
//
//	_ = gobridge.GuardVoid(op, func() { …all the work… })
//
// Anything else is a complaint. See `complaintsAbout` for the four rules that
// spell that out and what each one exists to catch.
// When src is nil it parses **every** non-test Go file in this directory, not
// just main.go.
//
// The single-file version was the hole a review drove a truck through: adding
// `extra.go` with an unguarded `//export sops_decrypt_yaml_fast` left
// `go test ./cshim/` reporting `ok`, while `libprobe.h` gained a real,
// callable, completely unprotected entry point. `exportedEntryPointCount` did
// not help either — it counted the exports found in main.go, so a *moved*
// export reddened the count and a *new* one in another file did not. That is
// precisely the "thirteenth entry point six months from now" this test says, in its
// own comment, that it exists to catch.
func inspectGuardWiring(src any) (exports []string, complaints []string, err error) {
	fset := token.NewFileSet()

	var files []*ast.File
	if src != nil {
		// A synthetic fixture: one in-memory file, named main.go so parse
		// errors read sensibly.
		file, parseErr := parser.ParseFile(fset, "main.go", src, parser.ParseComments)
		if parseErr != nil {
			return nil, nil, parseErr
		}
		files = []*ast.File{file}
	} else {
		pkgs, parseErr := parser.ParseDir(fset, ".", func(info os.FileInfo) bool {
			return !strings.HasSuffix(info.Name(), "_test.go")
		}, parser.ParseComments)
		if parseErr != nil {
			return nil, nil, parseErr
		}
		// Every package in this directory, not a named one: a stray file
		// declaring `package cshim2` would otherwise be skipped silently, and
		// cgo would still refuse to build it — so if it is here and it parses,
		// it is in scope.
		var names []string
		for name := range pkgs {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			var paths []string
			for path := range pkgs[name].Files {
				paths = append(paths, path)
			}
			sort.Strings(paths)
			for _, path := range paths {
				files = append(files, pkgs[name].Files[path])
			}
		}
		if len(files) == 0 {
			return nil, nil, fmt.Errorf("no non-test Go files found in this directory")
		}
	}

	for _, file := range files {
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Doc == nil || fn.Body == nil || !hasExportDirective(fn.Doc) {
				continue
			}
			exports = append(exports, fn.Name.Name)
			complaints = append(complaints, complaintsAbout(fn)...)
		}
	}
	sort.Strings(exports)
	return exports, complaints, nil
}

// complaintsAbout applies four rules to one //export'ed function body. Each is
// here because a mutation that violates it used to pass.
//
//  1. There is at least one gobridge.Guard/GuardVoid call, and it is a
//     statement of the body rather than something nested inside an `if` or a
//     loop that might not run. Catches the guard being deleted outright —
//     including when a comment naming it is left behind, which is exactly what
//     defeated the previous substring check.
//  2. No call at all happens outside a guard, except the single `result(…)`
//     in the trailing return. Catches work hoisted above the guard or left
//     dangling after it: `plain := C.GoString(p)` on the line before
//     `gobridge.Guard(` is a call, and a panic there is not caught by a guard
//     that has not started yet.
//  3. No pointer dereference happens outside a guard either. Same reason as
//     rule 2 for the one kind of work that is not syntactically a call.
//  4. A function with results ends in exactly one `return result(out, x, err)`
//     whose payload and error are identifiers a guard call assigned. Catches
//     the guard running and its error then being thrown away — `_, _ :=
//     gobridge.Guard(…)` followed by `return result(out, nil, nil)` reports
//     success for a call that panicked. A function without results must not
//     call `result` at all.
func complaintsAbout(fn *ast.FuncDecl) []string {
	var out []string
	say := func(format string, args ...any) {
		out = append(out, fn.Name.Name+" "+fmt.Sprintf(format, args...))
	}

	// Everything lexically inside a guard call's *closure* is by definition
	// guarded, so the walk stops descending there and whatever it still finds
	// is, by construction, outside every guard.
	//
	// Its **arguments** are a different matter, and this distinction is the
	// whole of rule 5. `gobridge.Guard(op, func() {…})` evaluates its argument
	// list before `Guard` is entered, so a call written there runs unguarded
	// even though it sits lexically inside the guard's parentheses. Pruning the
	// whole `CallExpr`, which an earlier version did, made rule 2 depend on
	// where the author put the work rather than on when it runs: hoisted to the
	// previous statement it was caught, moved a few characters right into the
	// argument list it was not.
	var guardCalls, strayCalls []*ast.CallExpr
	var strayDerefs []*ast.StarExpr
	var strayReturns []*ast.ReturnStmt
	inspectGuardArgs := func(call *ast.CallExpr) {
		for _, arg := range call.Args {
			if _, isClosure := arg.(*ast.FuncLit); isClosure {
				continue
			}
			ast.Inspect(arg, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.CallExpr:
					strayCalls = append(strayCalls, node)
				case *ast.StarExpr:
					strayDerefs = append(strayDerefs, node)
				}
				return true
			})
		}
	}
	ast.Inspect(fn.Body, func(n ast.Node) bool {
		switch node := n.(type) {
		case *ast.CallExpr:
			if isGuardCall(node) {
				guardCalls = append(guardCalls, node)
				inspectGuardArgs(node)
				return false
			}
			strayCalls = append(strayCalls, node)
		case *ast.StarExpr:
			strayDerefs = append(strayDerefs, node)
		case *ast.ReturnStmt:
			// Counted at any depth, not just the body's own statement list.
			// An `if in == nil { return statusFailure }` above the guard is
			// nested, and it is exactly the kind of early exit that skips it.
			strayReturns = append(strayReturns, node)
		}
		return true
	})

	// Rule 1.
	if len(guardCalls) == 0 {
		say("runs no gobridge.Guard/GuardVoid at all: a panic in it aborts the host application")
		return out
	}
	if !hasTopLevelGuard(fn.Body) {
		say("has a gobridge.Guard/GuardVoid, but not as a statement of its own body — " +
			"a guard nested inside another statement does not always run")
	}

	// Rule 4, first half: identify the trailing `return result(…)` so rule 2
	// can exempt it.
	hasResults := fn.Type.Results != nil && len(fn.Type.Results.List) > 0
	resultCall := trailingResultCall(fn.Body)

	if hasResults {
		if resultCall == nil {
			say("does not end in `return result(out, …)`: the guard's error has no way " +
				"to reach the caller")
		} else if len(resultCall.Args) != 3 {
			say("calls result with %d arguments, expected 3", len(resultCall.Args))
		} else {
			assigned := guardAssignedNames(fn.Body)
			// A slice, not a map, so a body with both wrong produces its two
			// complaints in the same order every run.
			for _, arg := range []struct {
				position int
				label    string
			}{{1, "payload"}, {2, "error"}} {
				name, ok := resultCall.Args[arg.position].(*ast.Ident)
				if !ok || !assigned[name.Name] {
					say("passes something other than the guard's own %s to result: "+
						"a guard whose result is discarded reports success for a call that panicked",
						arg.label)
				}
			}
		}
		if count := len(strayReturns); count != 1 {
			say("has %d return statements outside its guard, expected exactly 1: "+
				"an early return is a path that skips the guard", count)
		}
		// Rule 6. Rule 4 checks that `result` is handed the identifiers the
		// guard bound; it says nothing about what those identifiers still
		// hold by then. A single `err = nil` between the guard and the return
		// satisfies every rule above and turns a recovered panic into status
		// 0 with an empty payload — the shape that reaches the editor as a
		// blank document the user then saves over their real file.
		for _, name := range reboundAfterGuard(fn.Body) {
			say("reassigns %s after the guard bound it: the guard's own answer is "+
				"then discarded, and a recovered panic is reported as success", name)
		}
	} else if resultCall != nil || callsResultAnywhere(strayCalls) {
		say("has no status to return but calls result anyway")
	}

	// Rule 2.
	for _, call := range strayCalls {
		if call == resultCall {
			continue
		}
		say("calls %s outside any guard: work above or below the guard is not covered by it",
			describeCall(call))
	}

	// Rule 3.
	if len(strayDerefs) > 0 {
		say("dereferences a pointer outside any guard (%d time(s)): same exposure as rule 2, "+
			"for the one kind of work that is not syntactically a call", len(strayDerefs))
	}

	return out
}

func isGuardCall(call *ast.CallExpr) bool {
	selector, ok := call.Fun.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	pkg, ok := selector.X.(*ast.Ident)
	if !ok || pkg.Name != "gobridge" {
		return false
	}
	return selector.Sel.Name == "Guard" || selector.Sel.Name == "GuardVoid"
}

// hasTopLevelGuard reports whether some statement of the body *is* a guard
// call — `x, err := gobridge.Guard(…)`, `_ = gobridge.GuardVoid(…)`, or the
// bare call as an expression statement.
func hasTopLevelGuard(body *ast.BlockStmt) bool {
	for _, stmt := range body.List {
		if guardCallIn(stmt) != nil {
			return true
		}
	}
	return false
}

func guardCallIn(stmt ast.Stmt) *ast.CallExpr {
	var candidate ast.Expr
	switch node := stmt.(type) {
	case *ast.AssignStmt:
		if len(node.Rhs) != 1 {
			return nil
		}
		candidate = node.Rhs[0]
	case *ast.ExprStmt:
		candidate = node.X
	default:
		return nil
	}
	call, ok := candidate.(*ast.CallExpr)
	if !ok || !isGuardCall(call) {
		return nil
	}
	return call
}

// reboundAfterGuard returns, in source order, the names a guard assignment
// bound and that a later top-level statement assigns to again.
//
// Only plain `=` counts. A second `:=` would shadow rather than overwrite and
// rule 4 would catch the mismatch at the `result` call; it is the assignment
// that keeps the same identifier while replacing what the guard put in it that
// slips past every other rule.
func reboundAfterGuard(body *ast.BlockStmt) []string {
	bound := guardAssignedNames(body)
	var rebound []string
	seen := map[string]bool{}
	sawGuard := false
	for _, stmt := range body.List {
		if guardCallIn(stmt) != nil {
			sawGuard = true
			continue
		}
		if !sawGuard {
			continue
		}
		assign, ok := stmt.(*ast.AssignStmt)
		if !ok || assign.Tok != token.ASSIGN {
			continue
		}
		for _, lhs := range assign.Lhs {
			ident, ok := lhs.(*ast.Ident)
			if !ok || !bound[ident.Name] || seen[ident.Name] {
				continue
			}
			seen[ident.Name] = true
			rebound = append(rebound, ident.Name)
		}
	}
	return rebound
}

// guardAssignedNames collects the identifiers the body's top-level guard
// assignments bind, so rule 4 can insist the trailing `result` call passes
// those and not something else.
func guardAssignedNames(body *ast.BlockStmt) map[string]bool {
	names := map[string]bool{}
	for _, stmt := range body.List {
		assign, ok := stmt.(*ast.AssignStmt)
		if !ok || guardCallIn(stmt) == nil {
			continue
		}
		for _, lhs := range assign.Lhs {
			if ident, ok := lhs.(*ast.Ident); ok && ident.Name != "_" {
				names[ident.Name] = true
			}
		}
	}
	return names
}

// trailingResultCall returns the `result(…)` call in the body's last statement
// when that statement is `return result(…)`, and nil otherwise — including
// when a `return result(…)` exists but is not last, which is itself a defect
// rule 4 reports.
func trailingResultCall(body *ast.BlockStmt) *ast.CallExpr {
	if len(body.List) == 0 {
		return nil
	}
	ret, ok := body.List[len(body.List)-1].(*ast.ReturnStmt)
	if !ok || len(ret.Results) != 1 {
		return nil
	}
	call, ok := ret.Results[0].(*ast.CallExpr)
	if !ok {
		return nil
	}
	name, ok := call.Fun.(*ast.Ident)
	if !ok || name.Name != "result" {
		return nil
	}
	return call
}

func callsResultAnywhere(calls []*ast.CallExpr) bool {
	for _, call := range calls {
		if name, ok := call.Fun.(*ast.Ident); ok && name.Name == "result" {
			return true
		}
	}
	return false
}

// describeCall names a call for an error message. It never sees a value from a
// document — this walks source text, not data — but it is deliberately limited
// to the callee's own name for the same habit.
func describeCall(call *ast.CallExpr) string {
	switch fn := call.Fun.(type) {
	case *ast.Ident:
		return fn.Name + "(…)"
	case *ast.SelectorExpr:
		if pkg, ok := fn.X.(*ast.Ident); ok {
			return pkg.Name + "." + fn.Sel.Name + "(…)"
		}
		return fn.Sel.Name + "(…)"
	default:
		return "a function"
	}
}

func hasExportDirective(doc *ast.CommentGroup) bool {
	for _, comment := range doc.List {
		if strings.HasPrefix(comment.Text, "//export ") {
			return true
		}
	}
	return false
}

func readSource(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}
