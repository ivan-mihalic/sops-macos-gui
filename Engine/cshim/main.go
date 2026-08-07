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

//export sops_free
func sops_free(p *C.char) {
	C.free(unsafe.Pointer(p))
}

//export sops_engine_versions
func sops_engine_versions(outSops **C.char, outAge **C.char) {
	*outSops = C.CString(gobridge.SopsVersion())
	*outAge = C.CString(gobridge.AgeVersion())
}
