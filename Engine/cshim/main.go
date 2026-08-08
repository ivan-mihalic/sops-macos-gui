// Command cshim exposes the gobridge API as a C archive so Swift can call SOPS
// in-process. Built with `go build -buildmode=c-archive`.
//
// Calling convention: every entry point returns 0 on success and 1 on failure.
// On success *out receives a C string with the result; on failure it receives a
// C string with the error message. Either way the caller owns the memory and
// must release it with sops_free.
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

// result writes either the payload or the error into *out and returns the status.
func result(out **C.char, payload []byte, err error) C.int {
	if err != nil {
		*out = C.CString(err.Error())
		return 1
	}
	*out = C.CString(string(payload))
	return 0
}

//export sops_encrypt_yaml
func sops_encrypt_yaml(plain *C.char, recipientsCSV *C.char, encryptedRegex *C.char, out **C.char) C.int {
	encrypted, err := gobridge.Encrypt(
		[]byte(C.GoString(plain)),
		gobridge.FormatYAML,
		gobridge.EncryptOpts{
			AgeRecipients:  gobridge.SplitRecipients(C.GoString(recipientsCSV)),
			EncryptedRegex: C.GoString(encryptedRegex),
		},
	)
	return result(out, encrypted, err)
}

//export sops_decrypt_yaml
func sops_decrypt_yaml(encrypted *C.char, agePrivateKey *C.char, out **C.char) C.int {
	plain, err := gobridge.Decrypt(
		[]byte(C.GoString(encrypted)),
		gobridge.FormatYAML,
		C.GoString(agePrivateKey),
	)
	return result(out, plain, err)
}

// sops_lookup_creation_rule resolves which .sops.yaml creation rule governs
// targetFile, using sops's own config parser (github.com/getsops/sops/v3/config)
// rather than any bespoke parsing on either side of the boundary. On success
// *out carries the JSON encoding of a CreationRuleLookup (see gobridge/config.go)
// — including the case where no rule matched, which is not a failure.
//
//export sops_lookup_creation_rule
func sops_lookup_creation_rule(confPath *C.char, targetFile *C.char, out **C.char) C.int {
	payload, err := gobridge.LookupCreationRuleJSON(C.GoString(confPath), C.GoString(targetFile))
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
	payload, err := gobridge.InspectConfigBackendsJSON(C.GoString(confPath))
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
	payload, err := gobridge.DecryptToRowsJSON(
		[]byte(C.GoString(encrypted)),
		C.GoString(agePrivateKey),
	)
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
	payload, err := gobridge.ApplyEditsJSON(
		[]byte(C.GoString(encrypted)),
		[]byte(C.GoString(editsJSON)),
		C.GoString(agePrivateKey),
	)
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
	payload, err := gobridge.ApplyChangesJSON(
		[]byte(C.GoString(encrypted)),
		[]byte(C.GoString(changesJSON)),
		C.GoString(agePrivateKey),
	)
	return result(out, payload, err)
}

//export sops_free
func sops_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

//export sops_engine_versions
func sops_engine_versions(outSops **C.char, outAge **C.char) {
	*outSops = C.CString(gobridge.SopsVersion())
	*outAge = C.CString(gobridge.AgeVersion())
}
