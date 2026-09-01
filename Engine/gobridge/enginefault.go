package gobridge

// Panic containment for the cgo boundary.
//
// A Go panic that reaches a `//export`ed function does not unwind into Swift.
// There is no C-level exception to catch: the runtime prints the trace and
// calls abort(), so the *host application* dies. Every document the user had
// open, edited and not yet saved goes with it — because one file on disk was
// malformed.
//
// That is not hypothetical for this app. sops 3.13.3 panics on a value
// declared `type:bytes`: aes/cipher.go decrypts it to a []byte (cipher.go:108)
// and then uses the decrypted value as part of a map key (cipher.go:123),
// which for a []byte is `panic: runtime error: hash of unhashable type
// []uint8`. The declared type inside `ENC[…,type:…]` is not covered by the GCM
// additional data — the AAD is the key path — so rewriting `type:str` to
// `type:bytes` leaves the value authenticating perfectly and detonating on
// decryption. A corrupt file, a bad merge or one hostile commit in a shared
// repository all get there, and it reaches every read path including the
// MAC's own decryption, so a file whose values are all sound still kills the
// app. See enginefault_test.go for the live reproduction.
//
// So every entry point in cshim/main.go is wrapped in Guard or GuardVoid, and
// a panic becomes the same failure a wrong key or a bad MAC already produces:
// a non-zero status and a Go-allocated message the caller releases with
// sops_free.
//
// # Why the recovered value is never printed
//
// The obvious implementation — `fmt.Errorf("panic: %v", recovered)` — would
// create exactly the leak the rest of this package works to prevent. A panic
// payload is arbitrary: sops's own code panics with values built from what it
// was processing, and the whole file is document content. CLAUDE.md's rule is
// that no secret value reaches a log, an error or a crash report, and an error
// string here is rendered by the UI and collected by the crash reporter.
//
// What is reported instead is provably free of document content, because all
// three parts are compile-time facts about the program rather than runtime
// data: the operation the caller asked for, the Go *type* of the panic value,
// and the function and line it came from. That is enough to classify the
// fault and act on a bug report, and it cannot quote a secret.

import (
	"fmt"
	"path/filepath"
	"runtime"
	"strings"
)

// EngineFaultMarker begins every message a recovered panic produces, so a
// caller — or a test — can tell an engine defect apart from the ordinary
// refusals (wrong key, bad MAC, not a SOPS file) without matching on prose.
const EngineFaultMarker = "the sops engine faulted"

// The operations the twelve exported entry points perform. A fault says which
// one it happened in: it is the only classification a user can act on, and a
// fixed string cannot carry document content.
const (
	OpReading       = "reading this file"
	OpSaving        = "saving this file"
	OpEncrypting    = "encrypting this file"
	OpReadingConfig = "reading the project configuration"
	// Named for what a user asked for, not for what the bridge does: this
	// operation only ever *computes* the new project configuration text (see
	// UpdateConfigRecipients — it writes nothing), but a fault during it is
	// reported to someone who pressed a button called "update".
	OpUpdatingConfig    = "updating the project configuration"
	OpReportingVersions = "reporting its versions"
	OpReleasing         = "releasing memory"
	// SOPS-38 phase F3: deriving the session's own public key from its
	// imported private identity, so read-only ciphertext can be detected by
	// comparing public keys — never by decrypting. See
	// AgePublicKey (recipients.go's neighbour, agepublickey.go).
	OpDerivingPublicKey = "deriving your public key"
)

// Guard runs fn and converts any panic escaping it into an ordinary error.
//
// A clean call is passed through untouched — same payload, same error, no
// allocation — so wrapping every entry point costs nothing when nothing goes
// wrong. A faulting call returns no payload at all: a recovered panic must
// never present as an empty-but-valid document, which the editor would render
// as an empty form the user could save over their real file.
func Guard(operation string, fn func() ([]byte, error)) (payload []byte, err error) {
	completed := false
	defer func() {
		recovered := recover()
		if completed {
			return
		}
		// Reached whether the panic value was nil or not. `panic(nil)` yields a
		// *runtime.PanicNilError under this language version, but the flag is
		// what makes that irrelevant rather than something to depend on.
		payload, err = nil, engineFault(operation, recovered)
	}()

	payload, err = fn()
	completed = true
	return payload, err
}

// GuardVoid is Guard for the entry points that have no payload to return. The
// error is still produced rather than discarded here: a caller that has
// nowhere to put it has to say so at its own call site, so that swallowing a
// programmer error is always a visible decision.
func GuardVoid(operation string, fn func()) (err error) {
	completed := false
	defer func() {
		recovered := recover()
		if completed {
			return
		}
		err = engineFault(operation, recovered)
	}()

	fn()
	completed = true
	return nil
}

func engineFault(operation string, recovered interface{}) error {
	return fmt.Errorf(
		"%s while %s: %s in %s. The call produced nothing, so nothing was written. "+
			"This is a defect in the engine rather than something an edit to the document can fix; "+
			"no part of the document is reported here, because a fault can carry any of it",
		EngineFaultMarker, operation, panicKind(recovered), panicSite())
}

// panicKind names the Go type of the recovered value and nothing else.
//
// A type name is fixed at compile time, so it cannot be a secret however the
// panic arose — whereas the value's own text routinely is. The distinction
// between a runtime fault and a deliberate panic is worth keeping because it
// says whether the engine hit a bug or refused something loudly.
func panicKind(recovered interface{}) string {
	if recovered == nil {
		return "a fault of unrecorded kind"
	}
	if _, isRuntime := recovered.(runtime.Error); isRuntime {
		return fmt.Sprintf("a runtime fault (%T)", recovered)
	}
	return fmt.Sprintf("a fault (%T)", recovered)
}

// panicSite names the function that panicked, with its file and line.
//
// Function names and source positions are program identity, not program data —
// a stack frame's *arguments* would be another matter, which is why the
// formatted trace is never used. The frames wanted are those beneath
// runtime.gopanic: a deferred recover still has the panicking frames below it
// on the stack, so they are reachable from here.
//
// The first of them is usually not the interesting one. A runtime fault is
// raised inside the runtime's own machinery — the []byte map key detonates in
// runtime.nilinterhash, via a compiler-generated type:.hash.… thunk — and
// neither names the code that made the mistake. Both are skipped so the site
// reported is the first frame belonging to a real package, which for the known
// trigger is sops's own aes.Cipher.Decrypt.
func panicSite() string {
	var pcs [64]uintptr
	n := runtime.Callers(1, pcs[:])
	if n == 0 {
		return "an unrecorded location"
	}
	frames := runtime.CallersFrames(pcs[:n])
	pastPanic := false
	for {
		frame, more := frames.Next()
		if frame.Function == "runtime.gopanic" {
			pastPanic = true
		} else if pastPanic && isAttributableFrame(frame) {
			return describeFrame(frame)
		}
		if !more {
			return "an unrecorded location"
		}
	}
}

// isAttributableFrame reports whether a frame names code someone could go and
// look at, as opposed to the runtime's internals or a compiler-generated thunk.
func isAttributableFrame(frame runtime.Frame) bool {
	switch {
	case frame.Function == "":
		return false
	case strings.HasPrefix(frame.Function, "runtime."):
		return false
	case strings.HasPrefix(frame.Function, "internal/"):
		return false
	// Generated equality and hash functions, named `type:.hash.<type>`.
	case strings.HasPrefix(frame.Function, "type:."):
		return false
	case frame.File == "" || frame.File == "<autogenerated>":
		return false
	}
	return true
}

// describeFrame renders one frame as `function (dir/file.go:line)`.
//
// Only the last two path components are kept. The full path of a dependency
// is a module-cache location under the developer's home directory: it names
// the machine the binary was built on and tells the reader nothing they could
// use.
func describeFrame(frame runtime.Frame) string {
	if frame.File == "" {
		return frame.Function
	}
	dir, base := filepath.Split(frame.File)
	if parent := filepath.Base(filepath.Clean(dir)); parent != "." && parent != string(filepath.Separator) {
		base = parent + "/" + base
	}
	return fmt.Sprintf("%s (%s:%d)", frame.Function, base, frame.Line)
}
