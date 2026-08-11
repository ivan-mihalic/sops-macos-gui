// Command cshim exposes the gobridge API as a C archive so Swift can call SOPS
// in-process. Built with `go build -buildmode=c-archive`.
//
// Calling convention: every entry point returns 0 on success and 1 on failure.
// On success *out receives a C string with the result; on failure it receives a
// C string with the error message. Either way the caller owns the memory and
// must release it with sops_free.
//
// # Panics are part of that convention, not an exception to it
//
// A Go panic reaching one of these functions does not unwind into Swift. There
// is nothing on the C side to catch it: the runtime prints a trace and calls
// abort(), taking the host application and every unsaved document with it. And
// this is reachable from a file on disk — sops 3.13.3 panics on a value
// declared `type:bytes`, which authenticates perfectly and detonates on
// decryption (gobridge/enginefault.go has the full account, with the
// reproduction in gobridge/enginefault_test.go).
//
// So every entry point below runs its work inside gobridge.Guard or
// gobridge.GuardVoid, which turn a panic into an ordinary error carrying no
// part of the document.
//
// # What the guard does not cover, stated where someone might rely on it
//
// The argument conversions sit inside the guarded closure too, and an earlier
// version of this comment gave the wrong reason for that — it claimed
// C.GoString on a pointer Swift got wrong would panic and be caught here.
// Neither half is true, checked directly on this toolchain (go1.26.5,
// darwin/arm64) rather than reasoned about:
//
//   - C.GoString(nil) does not panic at all. It returns "". runtime.findnull
//     answers 0 for a nil pointer and runtime.gostring returns the empty
//     string, so a nil argument arrives here as an empty document and fails
//     as an ordinary parse error, which is the behaviour — just not a
//     recovered panic.
//   - C.GoString of a garbage non-nil pointer faults:
//     "unexpected fault address 0x… / fatal error: fault", raised through
//     runtime.throw. recover() never sees it and the host application dies.
//     No arrangement of guards in this file changes that; only Swift not
//     handing over a bad pointer does.
//
// The conversions stay inside the closure because that is where the work
// belongs and because hoisting them would put real work outside the guard for
// no gain — exports_test.go enforces that shape structurally. What the guard
// genuinely catches is a panic raised by sops's own code partway through a
// document it mis-parses, which is the case it was built for and the case
// gobridge/enginefault_test.go reproduces.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/ivan-mihalic/sops-macos-gui/engine/gobridge"
)

func main() {}

const (
	statusOK      C.int = 0
	statusFailure C.int = 1
)

// result writes either the payload or the error into *out and returns the status.
//
// Its own recover is the last link in the chain, and it is worth being exact
// about what that link actually holds. An earlier version of this comment said
// it covered C.CString failing to allocate. It does not, and cannot:
//
//   - It *does* catch a nil `out`. `*out = …` through a nil pointer is an
//     ordinary Go nil-pointer dereference, which recover() sees.
//   - It *does* catch C.CString's own panic("string too large"), which cgo
//     raises when len(s)+1 overflows int.
//   - It does *not* catch an allocation failure. cgo's C.CString reaches
//     _cgo_cmalloc, which calls runtime.throw("runtime: C malloc failed") when
//     malloc returns nil (go1.26.5, cmd/cgo/out.go's cMallocDefGo). A
//     runtime.throw is fatal by construction — no recover() anywhere in the
//     process sees it — so this function does not pretend otherwise.
//
// On the paths it does catch, leaving *out nil is a state the Swift side
// already handles — SopsBridge.call reports "bridge returned no result
// (status N)" — so the failure is still described rather than turning into a
// crash at the very step meant to prevent one.
func result(out **C.char, payload []byte, err error) (status C.int) {
	defer func() {
		if recover() != nil {
			if out != nil {
				*out = nil
			}
			status = statusFailure
		}
	}()

	if err != nil {
		*out = C.CString(err.Error())
		return statusFailure
	}
	*out = C.CString(string(payload))
	return statusOK
}

//export sops_encrypt_yaml
func sops_encrypt_yaml(plain *C.char, recipientsCSV *C.char, encryptedRegex *C.char, out **C.char) C.int {
	encrypted, err := gobridge.Guard(gobridge.OpEncrypting, func() ([]byte, error) {
		return gobridge.Encrypt(
			[]byte(C.GoString(plain)),
			gobridge.FormatYAML,
			gobridge.EncryptOpts{
				AgeRecipients:  gobridge.SplitRecipients(C.GoString(recipientsCSV)),
				EncryptedRegex: C.GoString(encryptedRegex),
			},
		)
	})
	return result(out, encrypted, err)
}

//export sops_decrypt_yaml
func sops_decrypt_yaml(encrypted *C.char, agePrivateKey *C.char, out **C.char) C.int {
	plain, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.Decrypt(
			[]byte(C.GoString(encrypted)),
			gobridge.FormatYAML,
			C.GoString(agePrivateKey),
		)
	})
	return result(out, plain, err)
}

// sops_recipients returns the document's native age recipient list as JSON.
// Metadata is public, so this operation never needs an age identity.
//
//export sops_recipients
func sops_recipients(encrypted *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.RecipientsJSON([]byte(C.GoString(encrypted)))
	})
	return result(out, payload, err)
}

// sops_update_recipients explicitly replaces the document's recipient list.
// recipientsJSON is a JSON string array; accepting a structured list avoids
// comma-delimited ambiguity at the C boundary.
//
//export sops_update_recipients
func sops_update_recipients(encrypted *C.char, recipientsJSON *C.char, agePrivateKey *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpSaving, func() ([]byte, error) {
		return gobridge.UpdateRecipientsJSON(
			[]byte(C.GoString(encrypted)),
			[]byte(C.GoString(recipientsJSON)),
			C.GoString(agePrivateKey),
		)
	})
	return result(out, payload, err)
}

// sops_lookup_creation_rule resolves which .sops.yaml creation rule governs
// targetFile, using sops's own config parser (github.com/getsops/sops/v3/config)
// rather than any bespoke parsing on either side of the boundary. On success
// *out carries the JSON encoding of a CreationRuleLookup (see gobridge/config.go)
// — including the case where no rule matched, which is not a failure.
//
//export sops_lookup_creation_rule
func sops_lookup_creation_rule(confPath *C.char, targetFile *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReadingConfig, func() ([]byte, error) {
		return gobridge.LookupCreationRuleJSON(C.GoString(confPath), C.GoString(targetFile))
	})
	return result(out, payload, err)
}

// sops_inspect_config_backends reports which key backends the whole .sops.yaml
// at confPath declares, across every creation rule — including a rule that has
// no matching encrypted file today, which sops's own per-file rule lookup
// cannot surface. On success *out carries the JSON encoding of a
// ConfigBackends (see gobridge/configbackends.go).
//
//export sops_inspect_config_backends
func sops_inspect_config_backends(confPath *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReadingConfig, func() ([]byte, error) {
		return gobridge.InspectConfigBackendsJSON(C.GoString(confPath))
	})
	return result(out, payload, err)
}

// sops_update_config_recipients computes what the .sops.yaml at confPath would
// look like if the creation rule governing targetFile declared exactly the age
// recipients in recipientsJSON (a JSON string array). candidatesJSON is a JSON
// string array of absolute paths to classify — the result says which of them
// the same rule governs.
//
// It never writes anything: on success *out carries the JSON encoding of a
// ConfigRecipientUpdate (see gobridge/configwrite.go) holding the proposed
// text, and the Swift side writes it — atomically, and only after the user has
// confirmed — or does not. A shape this app will not rewrite is not a failure
// here: it comes back with `writable: false` and a sentence saying why.
//
//export sops_update_config_recipients
func sops_update_config_recipients(
	confPath *C.char, targetFile *C.char, recipientsJSON *C.char, candidatesJSON *C.char, out **C.char,
) C.int {
	payload, err := gobridge.Guard(gobridge.OpUpdatingConfig, func() ([]byte, error) {
		return gobridge.UpdateConfigRecipientsJSON(
			C.GoString(confPath),
			C.GoString(targetFile),
			[]byte(C.GoString(recipientsJSON)),
			[]byte(C.GoString(candidatesJSON)),
		)
	})
	return result(out, payload, err)
}

// sops_decrypt_to_rows decrypts a SOPS YAML document into the ordered list of
// editable rows the editor renders. On success *out carries the JSON encoding
// of a []gobridge.Row (see gobridge/document.go) — always an array, never
// null. The document is parsed and emitted only by sops's own stores; nothing
// on the Swift side ever re-parses the user's YAML.
//
// agePrivateKey must be a native AGE-SECRET-KEY-1… identity. An argument that
// yields no identity is an error, never a signal to consult the environment.
//
//export sops_decrypt_to_rows
func sops_decrypt_to_rows(encrypted *C.char, agePrivateKey *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpReading, func() ([]byte, error) {
		return gobridge.DecryptToRowsJSON(
			[]byte(C.GoString(encrypted)),
			C.GoString(agePrivateKey),
		)
	})
	return result(out, payload, err)
}

// sops_apply_edits applies edited values to an existing SOPS YAML document and
// returns the re-encrypted file in *out. editsJSON is the JSON encoding of a
// []gobridge.Edit.
//
// The saved file keeps its own metadata — recipients, encrypted_regex, MAC
// settings, shamir_threshold. Nothing here reads .sops.yaml: re-deriving a
// file's recipients from the project config during a save would change who can
// read it without saying so, which is `updatekeys`' job (M4).
//
//export sops_apply_edits
func sops_apply_edits(encrypted *C.char, editsJSON *C.char, agePrivateKey *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpSaving, func() ([]byte, error) {
		return gobridge.ApplyEditsJSON(
			[]byte(C.GoString(encrypted)),
			[]byte(C.GoString(editsJSON)),
			C.GoString(agePrivateKey),
		)
	})
	return result(out, payload, err)
}

// sops_apply_changes is sops_apply_edits plus the two operations that change
// a document's shape. changesJSON is the JSON encoding of a
// gobridge.ChangeSet: `sets` (the same []Edit sops_apply_edits takes), `adds`
// and `removes`.
//
// The same metadata guarantee holds: the saved file keeps its own recipients,
// encrypted_regex, MAC settings and shamir_threshold, and a newly added value
// lands on whichever side of the file's own encryption rules its key puts it.
// Nothing here reads .sops.yaml.
//
// Removing a list element renumbers everything after it, so a change set in
// which that renumbering could be read two ways is refused rather than
// guessed at — see gobridge/documentchanges.go's header for the rule.
//
//export sops_apply_changes
func sops_apply_changes(encrypted *C.char, changesJSON *C.char, agePrivateKey *C.char, out **C.char) C.int {
	payload, err := gobridge.Guard(gobridge.OpSaving, func() ([]byte, error) {
		return gobridge.ApplyChangesJSON(
			[]byte(C.GoString(encrypted)),
			[]byte(C.GoString(changesJSON)),
			C.GoString(agePrivateKey),
		)
	})
	return result(out, payload, err)
}

// sops_free releases a string one of the entry points above returned.
//
// # The guard here protects nothing, and saying so is the point
//
// An earlier version of this comment claimed the GuardVoid turned a
// double-free or a foreign pointer into a discarded error instead of a crash.
// It does not. Misusing free() does not produce a Go panic at all — checked
// directly on this toolchain (go1.26.5, darwin/arm64):
//
//   - a second free of the same pointer traps inside libc:
//     "SIGTRAP: trace trap … signal arrived during cgo execution";
//   - a free of a pointer this process never allocated aborts the same way
//     (SIGABRT).
//
// Both kill the host application with the user's unsaved documents in it, and
// recover() is never reached, so GuardVoid neither catches nor mitigates
// either. The only protection is correct use: exactly one sops_free per
// non-nil out pointer, which is what SopsBridge.call's defer does, and the nil
// check below so that freeing a never-populated out parameter is a no-op.
//
// What the guard is still doing here is holding the shape rather than the
// promise: every //export in this file runs inside one and exports_test.go
// enforces that structurally, so an exception here would be an invitation to
// add the tenth entry point without one. The error it produces is discarded
// because there is genuinely nowhere to report to — no out-parameter, no
// status.
//
//export sops_free
func sops_free(p *C.char) {
	_ = gobridge.GuardVoid(gobridge.OpReleasing, func() {
		if p == nil {
			return
		}
		C.free(unsafe.Pointer(p))
	})
}

// sops_engine_versions reports the sops and age versions compiled into this
// bridge. It has no status to return, so a fault answers with the same
// UnknownVersion sentinel an undeterminable version already produces — which
// the Swift side must handle explicitly, because it deliberately does not
// parse as a version number.
//
// The out-parameters are cleared to nil first, in a guarded step of their own,
// before anything that could fault runs. This file's header states the whole
// calling convention as "either way the caller owns the memory and must
// release it with sops_free"; a fault that left *outSops holding whatever was
// in that memory beforehand would break exactly that, and the caller would
// free a pointer it never received. Clearing first means the worst case is a
// nil, which sops_free accepts. The Swift caller happens to pre-initialise
// both, so nothing observable changes today — this is the contract being kept
// by the side that declares it rather than by the side that reads it.
//
//export sops_engine_versions
func sops_engine_versions(outSops **C.char, outAge **C.char) {
	_ = gobridge.GuardVoid(gobridge.OpReportingVersions, func() {
		*outSops, *outAge = nil, nil
	})
	sopsVersion, ageVersion := gobridge.UnknownVersion, gobridge.UnknownVersion
	_ = gobridge.GuardVoid(gobridge.OpReportingVersions, func() {
		sopsVersion, ageVersion = gobridge.SopsVersion(), gobridge.AgeVersion()
	})
	_ = gobridge.GuardVoid(gobridge.OpReportingVersions, func() {
		*outSops = C.CString(sopsVersion)
		*outAge = C.CString(ageVersion)
	})
}
