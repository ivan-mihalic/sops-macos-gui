package gobridge

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
)

// A Go panic that reaches the cgo boundary does not unwind into Swift: the Go
// runtime prints the trace and calls abort(). The host process dies, and with
// it every unsaved document the user had open — because one file on disk was
// malformed.
//
// The trigger is upstream, in sops 3.13.3's own cipher:
//
//	aes/cipher.go:108   case "bytes": plaintext = decryptedBytes
//	aes/cipher.go:123   c.stash[stashKey{plaintext: plaintext, ...}] = ...
//
// stashKey holds the plaintext in an interface{} field, so the key is only
// hashable if the value in it is. A `type:bytes` value decrypts to []byte,
// which is not: `panic: runtime error: hash of unhashable type []uint8`.
//
// The declared type inside ENC[…,type:…] is *not* covered by the GCM
// additional data — the AAD is the key path — so rewriting `type:str` to
// `type:bytes` leaves the value authenticating perfectly and detonating on
// decryption. Every read path reaches it: Decrypt, DecryptToRows,
// ApplyEditsAndEncrypt, ApplyChangesAndEncrypt, and the MAC's own decryption,
// which means a file whose *values* are all sound still kills the app.
//
// These tests pin both halves of the contract: the panic never leaves the
// package as a panic, and what leaves instead carries no part of the document.

// faultCanary is planted as a plaintext value in the hostile document and as
// the payload of a deliberately thrown panic. It may not appear in any message
// this package produces.
const faultCanary = "canary-8f2c11d0-must-never-appear-in-an-error"

func hostileDocument(t *testing.T, key ageKeyPair) string {
	t.Helper()
	healthy := healthyDocument(t, key)
	hostile := strings.Replace(healthy, ",type:str]", ",type:bytes]", 1)
	if hostile == healthy {
		t.Fatal("fixture unchanged: the encrypted document had no type:str value to rewrite")
	}
	return hostile
}

func healthyDocument(t *testing.T, key ageKeyPair) string {
	t.Helper()
	encrypted, err := Encrypt(
		[]byte("alpha: "+faultCanary+"\nbeta: 42\n"),
		FormatYAML,
		EncryptOpts{AgeRecipients: []string{key.Public}},
	)
	if err != nil {
		t.Fatalf("encrypt fixture: %v", err)
	}
	return string(encrypted)
}

// --- the reproduction --------------------------------------------------------

// unguardedProbes are the calls that panic today. Each one runs in a child
// process, because an unrecovered panic takes the whole test binary with it.
var unguardedProbes = map[string]func(key ageKeyPair, doc string) (interface{}, error){
	"Decrypt": func(key ageKeyPair, doc string) (interface{}, error) {
		return Decrypt([]byte(doc), FormatYAML, key.Private)
	},
	"DecryptToRows": func(key ageKeyPair, doc string) (interface{}, error) {
		return DecryptToRows([]byte(doc), key.Private)
	},
	"ApplyEditsAndEncrypt": func(key ageKeyPair, doc string) (interface{}, error) {
		return ApplyEditsAndEncrypt([]byte(doc), nil, key.Private)
	},
	"ApplyChangesJSON": func(key ageKeyPair, doc string) (interface{}, error) {
		return ApplyChangesJSON([]byte(doc), []byte(`{"sets":[]}`), key.Private)
	},
}

// TestHostileDocumentPanicsUnguarded is the reproduction, kept as a live test
// rather than a comment. It documents the upstream defect *and* proves the
// fixture is genuinely hostile — without it, every "the guard caught it" test
// below would still pass against a fixture that never panicked at all.
func TestHostileDocumentPanicsUnguarded(t *testing.T) {
	if name := os.Getenv("SOPS_FAULT_PROBE"); name != "" {
		key := ageKeyPair{Private: os.Getenv("SOPS_FAULT_KEY")}
		probe, ok := unguardedProbes[name]
		if !ok {
			fmt.Printf("UNKNOWN PROBE %s\n", name)
			return
		}
		_, err := probe(key, os.Getenv("SOPS_FAULT_DOC"))
		fmt.Printf("RETURNED err=%v\n", err)
		return
	}

	key := newAgeKeyPair(t)
	hostile := hostileDocument(t, key)

	for name := range unguardedProbes {
		t.Run(name, func(t *testing.T) {
			output, err := runProbe(t, name, key.Private, hostile)
			if err == nil {
				t.Fatalf("expected %s to panic on the hostile document, but it returned:\n%s", name, output)
			}
			if !strings.Contains(output, "hash of unhashable type") {
				t.Fatalf("%s died for a different reason than the known trigger:\n%s", name, output)
			}
		})
	}
}

// TestHealthyDocumentSurvivesUnguarded is the control: the same probes on the
// same file with `type:str` intact must not die, so the failures above are
// attributable to the one-word edit and nothing else.
func TestHealthyDocumentSurvivesUnguarded(t *testing.T) {
	key := newAgeKeyPair(t)
	healthy := healthyDocument(t, key)

	for name := range unguardedProbes {
		t.Run(name, func(t *testing.T) {
			output, err := runProbe(t, name, key.Private, healthy)
			if err != nil {
				t.Fatalf("%s died on a healthy document:\n%s", name, output)
			}
			if !strings.Contains(output, "RETURNED err=<nil>") {
				t.Fatalf("%s failed on a healthy document:\n%s", name, output)
			}
		})
	}
}

func runProbe(t *testing.T, name, privateKey, document string) (string, error) {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run", "^TestHostileDocumentPanicsUnguarded$")
	cmd.Env = append(os.Environ(),
		"SOPS_FAULT_PROBE="+name,
		"SOPS_FAULT_KEY="+privateKey,
		"SOPS_FAULT_DOC="+document,
	)
	output, err := cmd.CombinedOutput()
	return string(output), err
}

// --- the fix -----------------------------------------------------------------

// TestGuardTurnsTheHostileDocumentIntoAnError is the other side of the
// reproduction: the same call, wrapped the way every //export'ed entry point
// now wraps it, comes back as an ordinary error.
func TestGuardTurnsTheHostileDocumentIntoAnError(t *testing.T) {
	key := newAgeKeyPair(t)
	hostile := hostileDocument(t, key)

	payload, err := Guard(OpReading, func() ([]byte, error) {
		return DecryptToRowsJSON([]byte(hostile), key.Private)
	})

	if err == nil {
		t.Fatalf("the hostile document reported success with payload %q", payload)
	}
	if payload != nil {
		t.Fatalf("a failed call returned a payload: %q", payload)
	}
	if !strings.Contains(err.Error(), EngineFaultMarker) {
		t.Fatalf("the failure is not distinguishable as an engine fault: %q", err)
	}
	// It must be attributable, or a bug report cannot be acted on.
	if !strings.Contains(err.Error(), "getsops/sops") {
		t.Fatalf("the failure does not name where it happened: %q", err)
	}
}

// TestNoCanaryReachesTheCaller is the constraint that makes this fix worth
// having rather than a new leak. A recover() that formats %v of the panic
// straight into the message would publish whatever the panic carried — and a
// panic payload can be any part of the document.
func TestNoCanaryReachesTheCaller(t *testing.T) {
	key := newAgeKeyPair(t)
	hostile := hostileDocument(t, key)

	t.Run("hostile document", func(t *testing.T) {
		_, err := Guard(OpReading, func() ([]byte, error) {
			return DecryptToRowsJSON([]byte(hostile), key.Private)
		})
		if err == nil {
			t.Fatal("expected a failure")
		}
		assertNoLeak(t, err.Error())
	})

	// The stronger form: the panic payload *is* the secret. The document
	// trigger happens to panic with a type name, so on its own it would not
	// prove anything about a payload that carries content.
	payloads := map[string]interface{}{
		"string payload": faultCanary,
		"error payload":  fmt.Errorf("value was %s", faultCanary),
		"struct payload": struct{ Secret string }{faultCanary},
		"bytes payload":  []byte(faultCanary),
	}
	for name, payload := range payloads {
		t.Run(name, func(t *testing.T) {
			_, err := Guard(OpReading, func() ([]byte, error) {
				panic(payload)
			})
			if err == nil {
				t.Fatal("the panic did not become an error")
			}
			assertNoLeak(t, err.Error())
			if !strings.Contains(err.Error(), EngineFaultMarker) {
				t.Fatalf("not marked as an engine fault: %q", err)
			}
		})
	}
}

func assertNoLeak(t *testing.T, message string) {
	t.Helper()
	if strings.Contains(message, faultCanary) {
		t.Fatalf("the message carries the canary: %q", message)
	}
	// Even a fragment is too much: the canary is one token, and a message that
	// quoted half of it would still be quoting the document.
	if strings.Contains(message, "canary") || strings.Contains(message, "8f2c11d0") {
		t.Fatalf("the message carries part of the canary: %q", message)
	}
}

// TestGuardDoesNotFabricateSuccess: a recovered call must not look like a
// document that simply had nothing in it. The editor would render that as an
// empty form the user could save over their real file.
func TestGuardDoesNotFabricateSuccess(t *testing.T) {
	payload, err := Guard(OpReading, func() ([]byte, error) {
		return []byte("[]"), nil // what a genuinely empty document returns
	})
	if err != nil || string(payload) != "[]" {
		t.Fatalf("Guard altered a successful call: payload=%q err=%v", payload, err)
	}

	payload, err = Guard(OpReading, func() ([]byte, error) {
		panic("anything at all")
	})
	if err == nil {
		t.Fatal("a panic became a success")
	}
	if len(payload) != 0 {
		t.Fatalf("a panic returned a payload: %q", payload)
	}
}

// TestGuardPassesOrdinaryFailuresThrough: wrapping must not blur the existing
// error vocabulary. A wrong key still says it is a wrong key.
func TestGuardPassesOrdinaryFailuresThrough(t *testing.T) {
	key := newAgeKeyPair(t)
	other := newAgeKeyPair(t)
	healthy := healthyDocument(t, key)

	_, err := Guard(OpReading, func() ([]byte, error) {
		return DecryptToRowsJSON([]byte(healthy), other.Private)
	})
	if err == nil {
		t.Fatal("decrypting with the wrong identity succeeded")
	}
	if strings.Contains(err.Error(), EngineFaultMarker) {
		t.Fatalf("an ordinary failure was reported as an engine fault: %q", err)
	}
	if !strings.Contains(err.Error(), "none of the keys available to this app") {
		t.Fatalf("the original message did not survive the guard: %q", err)
	}
}

// TestBridgeStillWorksAfterAFault: a recover that leaves the package unusable
// has only moved the outage. Nothing here holds state across calls — the
// cipher and the tree are per-call — and that is asserted rather than assumed.
func TestBridgeStillWorksAfterAFault(t *testing.T) {
	key := newAgeKeyPair(t)
	hostile := hostileDocument(t, key)
	healthy := healthyDocument(t, key)

	for round := 1; round <= 3; round++ {
		if _, err := Guard(OpReading, func() ([]byte, error) {
			return DecryptToRowsJSON([]byte(hostile), key.Private)
		}); err == nil {
			t.Fatalf("round %d: the hostile document did not fail", round)
		}

		rows, err := Guard(OpReading, func() ([]byte, error) {
			return DecryptToRowsJSON([]byte(healthy), key.Private)
		})
		if err != nil {
			t.Fatalf("round %d: a healthy document failed after a fault: %v", round, err)
		}
		if !strings.Contains(string(rows), faultCanary) {
			t.Fatalf("round %d: the healthy document did not decrypt to its own contents", round)
		}

		// The write path too, since it is the one that touches the user's file.
		if _, err := Guard(OpSaving, func() ([]byte, error) {
			return ApplyEditsJSON([]byte(healthy), []byte(`[]`), key.Private)
		}); err != nil {
			t.Fatalf("round %d: saving failed after a fault: %v", round, err)
		}

		// The version entry points share the same runtime and must keep
		// answering. What they answer is versionunknown_test.go's business;
		// what matters here is that a fault did not silence them.
		if SopsVersion() == "" || AgeVersion() == "" {
			t.Fatalf("round %d: the engine stopped reporting its versions", round)
		}
	}
}

// TestGuardVoidReportsRatherThanSwallows covers the two entry points with no
// payload to return.
func TestGuardVoidReportsRatherThanSwallows(t *testing.T) {
	if err := GuardVoid(OpReportingVersions, func() {}); err != nil {
		t.Fatalf("a clean call reported a fault: %v", err)
	}
	err := GuardVoid(OpReportingVersions, func() { panic(faultCanary) })
	if err == nil {
		t.Fatal("a panic was swallowed silently")
	}
	if !strings.Contains(err.Error(), EngineFaultMarker) {
		t.Fatalf("not marked as an engine fault: %q", err)
	}
	assertNoLeak(t, err.Error())
}

// TestFaultNamesTheOperation: seven of the nine entry points do different
// things, and "which one faulted" is the only classification a user can act on.
func TestFaultNamesTheOperation(t *testing.T) {
	for _, operation := range []string{OpReading, OpSaving, OpEncrypting, OpReadingConfig, OpReportingVersions, OpReleasing} {
		_, err := Guard(operation, func() ([]byte, error) { panic("boom") })
		if err == nil {
			t.Fatalf("%s: no error", operation)
		}
		if !strings.Contains(err.Error(), operation) {
			t.Fatalf("the message does not name the operation %q: %q", operation, err)
		}
	}
}

// TestNilPanicIsStillAFault. `panic(nil)` became a *runtime.PanicNilError in
// Go 1.21, but a package compiled with an older language version can still
// deliver a literal nil. Either way it must not read as success.
func TestNilPanicIsStillAFault(t *testing.T) {
	_, err := Guard(OpReading, func() ([]byte, error) {
		panic(nil)
	})
	if err == nil {
		t.Fatal("panic(nil) was treated as success")
	}
	if !strings.Contains(err.Error(), EngineFaultMarker) {
		t.Fatalf("not marked as an engine fault: %q", err)
	}
}

// TestGuardIsTransparentToACleanCall. Wrapping every entry point is only
// acceptable if it changes nothing when nothing goes wrong.
func TestGuardIsTransparentToACleanCall(t *testing.T) {
	key := newAgeKeyPair(t)
	healthy := healthyDocument(t, key)

	direct, directErr := DecryptToRowsJSON([]byte(healthy), key.Private)
	guarded, guardedErr := Guard(OpReading, func() ([]byte, error) {
		return DecryptToRowsJSON([]byte(healthy), key.Private)
	})
	if directErr != nil || guardedErr != nil {
		t.Fatalf("healthy document failed: direct=%v guarded=%v", directErr, guardedErr)
	}
	if string(direct) != string(guarded) {
		t.Fatalf("the guard altered the payload:\n direct: %s\nguarded: %s", direct, guarded)
	}
}
