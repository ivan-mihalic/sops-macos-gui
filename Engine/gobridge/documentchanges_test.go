package gobridge

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// Adding and removing keys — the structural half of the document API.
//
// Every fixture here goes through the real `sops` binary, and every assertion
// that matters is checked against `sops --decrypt`, because the only claim
// worth making about a write path is what the standard tool sees afterwards.

// A document with a list of *scalars*, which richPlainYAML deliberately does
// not have: `servers` is a list of maps, so removing one of its entries is a
// map-key removal at a fixed index, not the index-shifting case. The
// index-shifting hazard only exists for a list whose elements are themselves
// rows, and that is `ports` below.
const listPlainYAML = `# a service and its ports
service: api
ports:
    - 8080
    - 8443
    - 9090
    - 9443
tags:
    - alpha
    - beta
db:
    host: localhost
    password: hunter2
empty_map: {}
empty_list: []
`

func applyChanges(t *testing.T, encrypted []byte, key ageKeyPair, changes ChangeSet) []byte {
	t.Helper()
	out, err := ApplyChangesAndEncrypt(encrypted, changes, key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesAndEncrypt: %v", err)
	}
	return out
}

func applyChangesExpectingRefusal(t *testing.T, encrypted []byte, key ageKeyPair, changes ChangeSet) string {
	t.Helper()
	out, err := ApplyChangesAndEncrypt(encrypted, changes, key.Private)
	if err == nil {
		t.Fatalf("expected the change set to be refused, but it was applied")
	}
	if out != nil {
		t.Fatalf("a refused change set must return no bytes at all")
	}
	return err.Error()
}

// -----------------------------------------------------------------------
// Which container a row sits in
// -----------------------------------------------------------------------

// The editor has to know whether a row's parent is a map or a list before it
// can offer to add a sibling: a map needs a name and a list is appended. It
// cannot read that off the path — a map key "0" and list index 0 are the same
// text — so the row carries it, decided by the walk looking at the container.
func TestRowsSayWhetherTheirParentIsAList(t *testing.T) {
	key := newAgeKeyPair(t)
	// A map whose keys are decimal, next to a real list, so that a path-shaped
	// guess would get it exactly backwards for one of them.
	encrypted := encryptWithCLI(t, key,
		"lookalike:\n    \"0\": zero\n    \"1\": one\nreal:\n    - first\n    - second\nplain: value\nempty_list: []\n")

	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	for path, wantInList := range map[string]bool{
		"lookalike.0": false,
		"lookalike.1": false,
		"real.0":      true,
		"real.1":      true,
		"plain":       false,
		"empty_list":  false, // the empty list itself sits in the root map
	} {
		row := rowByPath(t, rows, strings.Split(path, ".")...)
		if row.InList != wantInList {
			t.Fatalf("%s: InList = %v, want %v", path, row.InList, wantInList)
		}
	}
}

// -----------------------------------------------------------------------
// Adding
// -----------------------------------------------------------------------

// A new map key lands at the end of the map it was added to, and comes back
// through the real CLI as a value of the type it was given.
func TestAddingAKeyToAMap(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Key: "replica", Value: "replica.internal", Kind: KindString}},
	})

	plain := cliDecrypt(t, key, out)
	if !strings.Contains(plain, "replica: replica.internal") {
		t.Fatalf("the added key is not in the decrypted document:\n%s", plain)
	}
	// At the end of `db`, i.e. after `special`, and before the next top-level key.
	special := strings.Index(plain, "special:")
	replica := strings.Index(plain, "replica:")
	apiKey := strings.Index(plain, "api_key:")
	if !(special < replica && replica < apiKey) {
		t.Fatalf("the added key is not at the end of the map it was added to:\n%s", plain)
	}

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	added := rowByPath(t, rows, "db", "replica")
	if added.Kind != KindString || added.Value != "replica.internal" {
		t.Fatalf("added row round-tripped as %+v", added)
	}
	if !added.Encrypted {
		t.Fatalf("a value added to a fully encrypted file must be ciphertext on disk")
	}
}

// A key added at the document root, where the parent path is empty.
func TestAddingAKeyAtTheDocumentRoot(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: nil, Key: "region", Value: "eu-central-1", Kind: KindString}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	added := rowByPath(t, rows, "region")
	if added.Value != "eu-central-1" {
		t.Fatalf("added root key round-tripped as %+v", added)
	}
}

// A value added into a list is appended. The API has no way to express
// "insert at position N", deliberately: an insertion shifts every later
// index, which is the same ambiguity a removal creates.
func TestAddingAnEntryToAListAppendsIt(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"ports"}, Value: "9999", Kind: KindInt}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	appended := rowByPath(t, rows, "ports", "4")
	if appended.Kind != KindInt || appended.Value != "9999" {
		t.Fatalf("appended entry round-tripped as %+v", appended)
	}
	for i, want := range []string{"8080", "8443", "9090", "9443"} {
		if got := rowByPath(t, rows, "ports", string(rune('0'+i))).Value; got != want {
			t.Fatalf("appending disturbed ports.%d: %q", i, got)
		}
	}
}

// Two entries appended to one list in a single save keep the order they were
// given. Nothing about this is ambiguous — "the end" is still the end.
func TestTwoEntriesCanBeAppendedToOneListInOneSave(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{
			{Parent: []string{"tags"}, Value: "gamma", Kind: KindString},
			{Parent: []string{"tags"}, Value: "delta", Kind: KindString},
		},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "tags", "2").Value; got != "gamma" {
		t.Fatalf("tags.2 = %q, want gamma", got)
	}
	if got := rowByPath(t, rows, "tags", "3").Value; got != "delta" {
		t.Fatalf("tags.3 = %q, want delta", got)
	}
}

// A key that is already there is not an add. Turning it into a set would
// overwrite a value nobody chose, and reporting success for a key that was
// not created would be worse.
func TestAddingAKeyThatAlreadyExistsIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Key: "password", Value: "something", Kind: KindString}},
	})
	if !strings.Contains(message, "db.password") {
		t.Fatalf("the refusal does not name the key: %q", message)
	}
	if strings.Contains(message, "something") {
		t.Fatalf("the refusal carries the value: %q", message)
	}
}

// The add is refused, not silently redirected somewhere plausible.
func TestAddingUnderAParentThatIsNotThereIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"nope"}, Key: "k", Value: "v", Kind: KindString}},
	})
	if !strings.Contains(message, "nope") {
		t.Fatalf("the refusal does not name the parent: %q", message)
	}
}

func TestAddingUnderAScalarIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"db", "password"}, Key: "k", Value: "v", Kind: KindString}},
	})
	if !strings.Contains(message, "db.password") {
		t.Fatalf("the refusal does not name the parent: %q", message)
	}
	if strings.Contains(message, "hunter2") {
		t.Fatalf("the refusal carries the parent's value: %q", message)
	}
}

// A map needs a key and a list must not be given one: the two containers are
// not interchangeable and guessing which was meant is exactly what this API
// does not do.
func TestAddNeedsAKeyForAMapAndNoneForAList(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	noKey := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Value: "v", Kind: KindString}},
	})
	if !strings.Contains(noKey, "db") {
		t.Fatalf("the refusal does not name the parent: %q", noKey)
	}

	keyedList := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"ports"}, Key: "8888", Value: "8888", Kind: KindInt}},
	})
	if !strings.Contains(keyedList, "ports") {
		t.Fatalf("the refusal does not name the parent: %q", keyedList)
	}
}

// An empty map and an empty list are rows in the editor, so they must be
// addable-into — otherwise `foo: {}` is a dead end nothing can ever be put in.
func TestAddingIntoAnEmptyContainer(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{
			{Parent: []string{"empty_map"}, Key: "first", Value: "one", Kind: KindString},
			{Parent: []string{"empty_list"}, Value: "two", Kind: KindString},
		},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "empty_map", "first").Value; got != "one" {
		t.Fatalf("empty_map.first = %q", got)
	}
	if got := rowByPath(t, rows, "empty_list", "0").Value; got != "two" {
		t.Fatalf("empty_list.0 = %q", got)
	}
}

// The file decides what gets encrypted, not the caller and not `.sops.yaml`.
func TestAddedValuesFollowTheFilesOwnEncryptionRules(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML,
		"--encrypted-regex", "^(password|api_key|token)$")

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{
			{Parent: []string{"db"}, Key: "token", Value: "t-123", Kind: KindString},
			{Parent: []string{"db"}, Key: "region", Value: "eu", Kind: KindString},
		},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if !rowByPath(t, rows, "db", "token").Encrypted {
		t.Fatalf("a key matching the file's encrypted_regex was added in the clear")
	}
	if rowByPath(t, rows, "db", "region").Encrypted {
		t.Fatalf("a key the file's rules do not cover was encrypted anyway")
	}
	if !strings.Contains(string(out), "region: eu") {
		t.Fatalf("a plaintext-by-rule added value is not readable on disk")
	}
	if strings.Contains(string(out), "t-123") {
		t.Fatalf("an encrypted-by-rule added value is readable on disk")
	}
}

// -----------------------------------------------------------------------
// Removing
// -----------------------------------------------------------------------

func TestRemovingAMapKey(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Removes: []Removal{{Path: []string{"db", "password"}}},
	})

	plain := cliDecrypt(t, key, out)
	if strings.Contains(plain, "password") {
		t.Fatalf("the removed key is still in the decrypted document:\n%s", plain)
	}
	// Its neighbours are untouched, in order.
	for _, want := range []string{"port: 5432", "enabled: true", "ratio: 0.75"} {
		if !strings.Contains(plain, want) {
			t.Fatalf("removing one key disturbed %q:\n%s", want, plain)
		}
	}
}

func TestRemovingAListElement(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Removes: []Removal{{Path: []string{"ports", "1"}}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	got := []string{
		rowByPath(t, rows, "ports", "0").Value,
		rowByPath(t, rows, "ports", "1").Value,
		rowByPath(t, rows, "ports", "2").Value,
	}
	want := []string{"8080", "9090", "9443"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("after removing ports.1 the list is %v, want %v", got, want)
		}
	}
	for _, path := range rowPaths(rows) {
		if path == "ports.3" {
			t.Fatalf("the list still has four entries after a removal")
		}
	}
}

// A removal that finds nothing is an error, never a quiet success. The
// caller's idea of the document disagrees with the file, and reporting
// "saved" for a change that did not happen is this project's cardinal sin.
func TestRemovingSomethingThatIsNotThereIsAnError(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	for _, path := range [][]string{
		{"nope"},
		{"db", "nope"},
		{"servers", "9"},
		{"db", "password", "deeper"},
	} {
		message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
			Removes: []Removal{{Path: path}},
		})
		if !strings.Contains(message, strings.Join(path, ".")) {
			t.Fatalf("the refusal for %v does not name the path: %q", path, message)
		}
	}
}

// Removing a key that still has entries under it would destroy every one of
// them on the strength of one click. Every row the editor shows is a leaf or
// an empty container, so nothing the editor can ask for is lost by refusing.
func TestRemovingAContainerWithEntriesInItIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	for _, path := range [][]string{{"db"}, {"servers"}, {"servers", "0"}} {
		message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
			Removes: []Removal{{Path: path}},
		})
		if !strings.Contains(message, strings.Join(path, ".")) {
			t.Fatalf("the refusal for %v does not name the path: %q", path, message)
		}
		if strings.Contains(message, "hunter2") {
			t.Fatalf("the refusal carries a value: %q", message)
		}
	}
}

// An empty container has no entries to lose, and it is a row in the editor,
// so it must be removable like any other row.
func TestRemovingAnEmptyContainerIsAllowed(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Removes: []Removal{{Path: []string{"empty_map"}}, {Path: []string{"empty_list"}}},
	})

	plain := cliDecrypt(t, key, out)
	if strings.Contains(plain, "empty_map") || strings.Contains(plain, "empty_list") {
		t.Fatalf("an empty container survived its removal:\n%s", plain)
	}
}

// Removing the last key of a map leaves the map behind, empty. That is what
// the tree says and what sops emits; inventing a cascade that also deletes
// the now-empty parent would be a structural change nobody asked for.
func TestRemovingTheLastKeyOfAMapLeavesAnEmptyMap(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, "outer:\n    only: value\nother: keep\n")

	out := applyChanges(t, encrypted, key, ChangeSet{
		Removes: []Removal{{Path: []string{"outer", "only"}}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "outer").Kind; got != KindEmptyMap {
		t.Fatalf("outer is %q, want %q", got, KindEmptyMap)
	}
}

// -----------------------------------------------------------------------
// The index-shift ambiguity
// -----------------------------------------------------------------------

// Removing a list element renumbers everything after it. A batch that also
// touches one of those later positions cannot be read with certainty: the
// caller may have meant the position before the removal or after it, and the
// two are different values. It is refused, naming both paths, rather than
// guessed at.
func TestABatchMixingAListRemovalWithAShiftedPathIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	cases := map[string]ChangeSet{
		// Adjacent, not a gap of two: an off-by-one in refuseShiftedPaths
		// (>= instead of >, or the wrong side of the comparison) survives a
		// gap and does not survive this.
		"a set at the very next index": {
			Sets:    []Edit{{Path: []string{"ports", "2"}, Value: "1234", Kind: KindInt}},
			Removes: []Removal{{Path: []string{"ports", "1"}}},
		},
		"a set further along": {
			Sets:    []Edit{{Path: []string{"ports", "3"}, Value: "1234", Kind: KindInt}},
			Removes: []Removal{{Path: []string{"ports", "1"}}},
		},
		"another removal at the very next index": {
			Removes: []Removal{
				{Path: []string{"ports", "1"}},
				{Path: []string{"ports", "2"}},
			},
		},
		"an add under a later index": {
			Adds:    []Add{{Parent: []string{"mixed", "1"}, Key: "k", Value: "v", Kind: KindString}},
			Removes: []Removal{{Path: []string{"mixed", "0"}}},
		},
	}
	// The third case needs a list whose *earlier* element is removable — a
	// container with entries in it never is — so a scalar followed by an
	// empty map, which is exactly what a user gets after emptying one entry
	// of a list of maps.
	mixedEncrypted := encryptWithCLI(t, key, "mixed:\n    - plain\n    - {}\n")

	for name, changes := range cases {
		t.Run(name, func(t *testing.T) {
			source := encrypted
			if name == "an add under a later index" {
				source = mixedEncrypted
			}
			message := applyChangesExpectingRefusal(t, source, key, changes)
			if !strings.Contains(message, "1") {
				t.Fatalf("the refusal does not name the removal: %q", message)
			}
			if !strings.Contains(strings.ToLower(message), "position") &&
				!strings.Contains(strings.ToLower(message), "shift") {
				t.Fatalf("the refusal does not explain why: %q", message)
			}
		})
	}
}

// The guard is not a blanket ban on removals in a batch: a change that cannot
// have shifted goes through. Anything at a *lower* index than the removal, in
// another list, or under a map is unaffected and is applied.
func TestARemovalTogetherWithChangesThatCannotHaveShiftedIsApplied(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Sets: []Edit{
			{Path: []string{"ports", "0"}, Value: "80", Kind: KindInt},
			{Path: []string{"tags", "1"}, Value: "BETA", Kind: KindString},
			{Path: []string{"db", "password"}, Value: "new", Kind: KindString},
		},
		Adds:    []Add{{Parent: []string{"ports"}, Value: "7777", Kind: KindInt}},
		Removes: []Removal{{Path: []string{"ports", "3"}}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	want := map[string]string{
		"ports.0":     "80",
		"ports.1":     "8443",
		"ports.2":     "9090",
		"ports.3":     "7777",
		"tags.1":      "BETA",
		"db.password": "new",
	}
	for path, expected := range want {
		got := rowByPath(t, rows, strings.Split(path, ".")...).Value
		if got != expected {
			t.Fatalf("%s = %q, want %q", path, got, expected)
		}
	}
}

// Appending to the very list a removal came out of is not ambiguous: an add
// has no index at all, it goes at the end whatever the end turns out to be.
func TestAppendingToTheListARemovalCameOutOfIsAllowed(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds:    []Add{{Parent: []string{"ports"}, Value: "1111", Kind: KindInt}},
		Removes: []Removal{{Path: []string{"ports", "0"}}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	got := []string{
		rowByPath(t, rows, "ports", "0").Value,
		rowByPath(t, rows, "ports", "1").Value,
		rowByPath(t, rows, "ports", "2").Value,
		rowByPath(t, rows, "ports", "3").Value,
	}
	want := []string{"8443", "9090", "9443", "1111"}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("ports = %v, want %v", got, want)
		}
	}
}

// -----------------------------------------------------------------------
// Conflicting changes in one batch
// -----------------------------------------------------------------------

func TestOneRowCannotBeTargetedTwiceInOneSave(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	cases := map[string]ChangeSet{
		"set and removed": {
			Sets:    []Edit{{Path: []string{"api_key"}, Value: "x", Kind: KindString}},
			Removes: []Removal{{Path: []string{"api_key"}}},
		},
		"removed twice": {
			Removes: []Removal{{Path: []string{"api_key"}}, {Path: []string{"api_key"}}},
		},
		"added twice": {
			Adds: []Add{
				{Parent: []string{"db"}, Key: "extra", Value: "a", Kind: KindString},
				{Parent: []string{"db"}, Key: "extra", Value: "b", Kind: KindString},
			},
		},
	}
	for name, changes := range cases {
		t.Run(name, func(t *testing.T) {
			message := applyChangesExpectingRefusal(t, encrypted, key, changes)
			if strings.Contains(message, "\"a\"") || strings.Contains(message, "hunter2") {
				t.Fatalf("the refusal carries a value: %q", message)
			}
		})
	}
}

// Removing a container and writing into it in the same save is contradictory.
func TestWritingUnderSomethingTheSameSaveRemovesIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds:    []Add{{Parent: []string{"empty_map"}, Key: "k", Value: "v", Kind: KindString}},
		Removes: []Removal{{Path: []string{"empty_map"}}},
	})
	if !strings.Contains(message, "empty_map") {
		t.Fatalf("the refusal does not name the path: %q", message)
	}
	// It must be refused *as a contradiction*, not merely fail late with
	// "there is no such map to add to" because the removal happened to run
	// first. The order the two are applied in is an implementation detail;
	// the refusal is the contract.
	if !strings.Contains(message, "removed") || !strings.Contains(message, "written") {
		t.Fatalf("the refusal does not say the two changes contradict each other: %q", message)
	}
}

// -----------------------------------------------------------------------
// Nothing is applied unless everything is
// -----------------------------------------------------------------------

// A change set is validated whole before the tree is touched, so a refusal
// cannot leave half the batch written.
func TestARefusedBatchAppliesNoneOfItsChanges(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	_ = applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Sets:    []Edit{{Path: []string{"api_key"}, Value: "changed", Kind: KindString}},
		Adds:    []Add{{Parent: []string{"db"}, Key: "fresh", Value: "v", Kind: KindString}},
		Removes: []Removal{{Path: []string{"nope"}}},
	})

	// The input bytes are the only state there is; prove the document still
	// reads exactly as it did.
	rows, err := DecryptToRows(encrypted, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "api_key").Value; got != "sk-live-abc123" {
		t.Fatalf("api_key = %q after a refused batch", got)
	}
	for _, path := range rowPaths(rows) {
		if path == "db.fresh" {
			t.Fatalf("a refused batch added a key")
		}
	}
}

// -----------------------------------------------------------------------
// Multi-document files
// -----------------------------------------------------------------------

func TestAddingAndRemovingInASpecificDocument(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, "shared: first\ngone: yes\n---\nshared: second\n")

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds:    []Add{{Document: 1, Key: "only_second", Value: "x", Kind: KindString}},
		Removes: []Removal{{Document: 0, Path: []string{"gone"}}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	var found bool
	for _, row := range rows {
		if row.Document == 1 && strings.Join(row.Path, ".") == "only_second" {
			found = true
		}
		if row.Document == 0 && strings.Join(row.Path, ".") == "gone" {
			t.Fatalf("the removal landed in the wrong document")
		}
	}
	if !found {
		t.Fatalf("the add did not land in document 1; rows: %v", rowPaths(rows))
	}
}

// -----------------------------------------------------------------------
// Error hygiene
// -----------------------------------------------------------------------

const changeCanary = "STRUCTURALCANARY7777"

// Every refusal on the structural paths names a key and never a value.
func TestAddAndRemoveErrorsNameThePathAndNeverTheValue(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	cases := map[string]ChangeSet{
		"duplicate key": {
			Adds: []Add{{Parent: []string{"db"}, Key: "password", Value: changeCanary, Kind: KindString}},
		},
		"missing parent": {
			Adds: []Add{{Parent: []string{"nope"}, Key: "k", Value: changeCanary, Kind: KindString}},
		},
		"bad kind": {
			Adds: []Add{{Parent: []string{"db"}, Key: "count", Value: changeCanary, Kind: KindInt}},
		},
		"unknown kind": {
			Adds: []Add{{Parent: []string{"db"}, Key: "count", Value: changeCanary, Kind: "banana"}},
		},
		"missing removal": {
			Removes: []Removal{{Path: []string{"nope"}}},
			Sets:    []Edit{{Path: []string{"api_key"}, Value: changeCanary, Kind: KindString}},
		},
	}
	for name, changes := range cases {
		t.Run(name, func(t *testing.T) {
			message := applyChangesExpectingRefusal(t, encrypted, key, changes)
			if strings.Contains(message, changeCanary) {
				t.Fatalf("the refusal carries the value: %q", message)
			}
		})
	}
}

// -----------------------------------------------------------------------
// The existing contract
// -----------------------------------------------------------------------

// ApplyEditsAndEncrypt is unchanged for callers that only set values: same
// signature, same behaviour, same refusals.
func TestApplyEditsAndEncryptStillOnlySets(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out, err := ApplyEditsAndEncrypt(encrypted, []Edit{
		{Path: []string{"api_key"}, Value: "sk-live-rotated", Kind: KindString},
	}, key.Private)
	if err != nil {
		t.Fatalf("ApplyEditsAndEncrypt: %v", err)
	}
	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "api_key").Value; got != "sk-live-rotated" {
		t.Fatalf("api_key = %q", got)
	}
}

func TestApplyChangesJSONRoundTrip(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	payload, err := json.Marshal(ChangeSet{
		Sets:    []Edit{{Path: []string{"api_key"}, Value: "rotated", Kind: KindString}},
		Adds:    []Add{{Parent: []string{"db"}, Key: "replica", Value: "r", Kind: KindString}},
		Removes: []Removal{{Path: []string{"db", "nothing"}}},
	})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	out, err := ApplyChangesJSON(encrypted, payload, key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesJSON: %v", err)
	}
	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "api_key").Value; got != "rotated" {
		t.Fatalf("api_key = %q", got)
	}
	if got := rowByPath(t, rows, "db", "replica").Value; got != "r" {
		t.Fatalf("db.replica = %q", got)
	}
	for _, path := range rowPaths(rows) {
		if path == "db.nothing" {
			t.Fatalf("db.nothing survived its removal")
		}
	}
}

// An empty change set is the no-op save Task 7 pinned: only the timestamp and
// the MAC move.
func TestApplyChangesJSONAcceptsAnEmptyChangeSet(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out, err := ApplyChangesJSON(encrypted, []byte(`{}`), key.Private)
	if err != nil {
		t.Fatalf("ApplyChangesJSON: %v", err)
	}
	if len(out) == 0 {
		t.Fatalf("no bytes returned")
	}
}

// The JSON carries plaintext, so its decode error must not quote the input.
func TestApplyChangesJSONRefusesMalformedInputWithoutEchoingIt(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	_, err := ApplyChangesJSON(encrypted, []byte(`{"sets":[{"nope":"`+changeCanary+`"}]}`), key.Private)
	if err == nil {
		t.Fatalf("malformed change JSON was accepted")
	}
	if strings.Contains(err.Error(), changeCanary) {
		t.Fatalf("the decode error carries the input: %q", err.Error())
	}
}

// The structural paths validate the identity before they look at the
// document, exactly as the set-only path does.
func TestApplyChangesRejectsAnEmptyKey(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	for _, bad := range []string{"", "   ", "# only a comment\n", key.Public} {
		if _, err := ApplyChangesAndEncrypt(encrypted, ChangeSet{
			Removes: []Removal{{Path: []string{"api_key"}}},
		}, bad); err == nil {
			t.Fatalf("an identity of %q was accepted", bad)
		}
	}
}

// -----------------------------------------------------------------------
// The round trip that matters
// -----------------------------------------------------------------------

// One save that adds a key, removes a different key and edits a third. What
// the standard tool sees afterwards must differ in exactly those three ways.
func TestAddRemoveAndEditInOneSave(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)
	before := cliDecrypt(t, key, encrypted)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Sets:    []Edit{{Path: []string{"db", "port"}, Value: "6432", Kind: KindInt}},
		Adds:    []Add{{Parent: []string{"db"}, Key: "replica", Value: "replica.internal", Kind: KindString}},
		Removes: []Removal{{Path: []string{"api_key"}}},
	})
	after := cliDecrypt(t, key, out)

	// Line-level: exactly one line changed, one gone, one new.
	removed, added := lineDifference(before, after)
	wantRemoved := []string{"    port: 5432", "api_key: sk-live-abc123"}
	wantAdded := []string{"    port: 6432", "    replica: replica.internal"}
	if !sameLines(removed, wantRemoved) || !sameLines(added, wantAdded) {
		t.Fatalf("the plaintext diff is not the three changes asked for:\n-%v\n+%v\n\nbefore:\n%s\nafter:\n%s",
			removed, added, before, after)
	}
}

func lineDifference(before, after string) (removed, added []string) {
	beforeLines := strings.Split(before, "\n")
	afterLines := strings.Split(after, "\n")
	count := map[string]int{}
	for _, line := range beforeLines {
		count[line]++
	}
	for _, line := range afterLines {
		count[line]--
	}
	for _, line := range beforeLines {
		if count[line] > 0 {
			removed = append(removed, line)
			count[line]--
		}
	}
	for _, line := range afterLines {
		if count[line] < 0 {
			added = append(added, line)
			count[line]++
		}
	}
	return removed, added
}

func sameLines(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if got[i] != want[i] {
			return false
		}
	}
	return true
}

// Task 7's property, carried onto the structural paths: a value nobody
// touched keeps its exact ciphertext, so the encrypted file's diff is only
// ever the lines that really changed.
func TestUntouchedValuesKeepTheirExactCiphertextAcrossAStructuralSave(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Sets:    []Edit{{Path: []string{"db", "port"}, Value: "6432", Kind: KindInt}},
		Adds:    []Add{{Parent: []string{"db"}, Key: "replica", Value: "replica.internal", Kind: KindString}},
		Removes: []Removal{{Path: []string{"api_key"}}},
	})

	removed, added := lineDifference(string(encrypted), string(out))
	// Every changed line must be one of: the edited key, the removed key, the
	// new key, or sops's own per-save metadata.
	allowed := func(line string) bool {
		trimmed := strings.TrimSpace(line)
		for _, prefix := range []string{"port:", "api_key:", "replica:", "lastmodified:", "mac:"} {
			if strings.HasPrefix(trimmed, prefix) {
				return true
			}
		}
		return false
	}
	for _, line := range append(append([]string{}, removed...), added...) {
		if !allowed(line) {
			t.Fatalf("a line nobody touched changed: %q\n-%v\n+%v", line, removed, added)
		}
	}
	// And the untouched ciphertext really is byte-identical, not merely
	// re-encrypted to something that happens to decrypt the same.
	for _, keyName := range []string{"password:", "host:", "name: ", "ip:"} {
		for _, line := range append(append([]string{}, removed...), added...) {
			if strings.HasPrefix(strings.TrimSpace(line), keyName) {
				t.Fatalf("%s changed across a save that did not touch it: %q", keyName, line)
			}
		}
	}
}

// Comments, key order, quoting and scalar styles survive a structural save
// exactly as they survive a value-only one.
func TestAStructuralSavePreservesCommentsOrderAndQuoting(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds:    []Add{{Parent: []string{"db"}, Key: "replica", Value: "r", Kind: KindString}},
		Removes: []Removal{{Path: []string{"api_key"}}},
	})
	plain := cliDecrypt(t, key, out)

	for _, want := range []string{
		"# who this file belongs to",
		"# the host is not a secret",
		`quoted_number: "5432"`,
		"multiline: |",
		"special: 'value: with colon'",
		"created: 2024-01-02T03:04:05Z",
		"empty_map: {}",
		"empty_list: []",
		"nothing: null",
	} {
		if !strings.Contains(plain, want) {
			t.Fatalf("a structural save lost %q:\n%s", want, plain)
		}
	}
}

// -----------------------------------------------------------------------
// Key names a new key may not have
// -----------------------------------------------------------------------

// The one that destroys a file. go-yaml tags a key named `<<` as `!!merge`,
// and a merge key whose value is not a map is invalid YAML — so a scalar
// under that name makes every other secret in the file unreadable, by the
// sops CLI and by this app, while the save reports success.
//
// This test drives the real CLI on the result rather than trusting the
// bridge, because the bridge is not the thing that breaks.
func TestAKeyNamedAsYAMLsMergeKeyIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	for _, parent := range [][]string{nil, {"db"}, {"empty_map"}} {
		message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
			Adds: []Add{{Parent: parent, Key: "<<", Value: "anything", Kind: KindString}},
		})
		if !strings.Contains(message, "<<") {
			t.Fatalf("the refusal does not name the key: %q", message)
		}
		if strings.Contains(message, "anything") {
			t.Fatalf("the refusal carries the value: %q", message)
		}
	}
}

// The proof the refusal is worth having: without it, this is what the file
// becomes. Built by writing the broken document the old code would have
// produced and asking the real CLI to read it.
func TestUpstreamStillRejectsAMergeKeyHoldingAScalar(t *testing.T) {
	key := newAgeKeyPair(t)
	broken := "db:\n    host: localhost\n    <<: not-a-map\n"
	path := writeTemp(t, "broken.yaml", []byte(broken))
	if _, err := runSopsCLIAllowFailDoc(t, key, "--encrypt", "--age", key.Public, path); err == nil {
		t.Fatalf("sops accepted a merge key holding a scalar; the refusal in " +
			"refuseReservedKey may no longer be needed — re-derive it before removing it")
	}
}

// An existing merge key is untouched by that refusal. Its children are
// ordinary rows, and emptying it leaves `<<: {}`, which is a map and
// therefore still valid — verified through the real CLI.
func TestAnExistingMergeKeyStillEditsRemovesAndEmptiesCleanly(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key,
		"base: &base\n    a: one\n    b: two\nderived:\n    <<: *base\n    c: three\n")

	current := encrypted
	current = applyChanges(t, current, key, ChangeSet{
		Sets: []Edit{{Path: []string{"derived", "<<", "a"}, Value: "edited", Kind: KindString}},
	})
	if !strings.Contains(cliDecrypt(t, key, current), "edited") {
		t.Fatalf("editing under a merge key did not take")
	}
	for _, path := range [][]string{{"derived", "<<", "a"}, {"derived", "<<", "b"}} {
		current = applyChanges(t, current, key, ChangeSet{Removes: []Removal{{Path: path}}})
	}
	plain := cliDecrypt(t, key, current)
	if !strings.Contains(plain, "<<: {}") {
		t.Fatalf("an emptied merge key is not `<<: {}`:\n%s", plain)
	}
	// And it can be filled back in, and removed outright.
	current = applyChanges(t, current, key, ChangeSet{
		Adds: []Add{{Parent: []string{"derived", "<<"}, Key: "a", Value: "back", Kind: KindString}},
	})
	if !strings.Contains(cliDecrypt(t, key, current), "back") {
		t.Fatalf("adding back into an emptied merge key did not take")
	}
}

// `sops` at a document root is where SOPS keeps its own metadata. The emitter
// already failed on it, but with a message that told the user nothing.
func TestAKeyNamedSopsAtTheDocumentRootIsRefused(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	message := applyChangesExpectingRefusal(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: nil, Key: "sops", Value: "anything", Kind: KindString}},
	})
	if !strings.Contains(message, "sops") || !strings.Contains(message, "metadata") {
		t.Fatalf("the refusal does not explain what is wrong: %q", message)
	}

	// Nested, it is an ordinary key and must not be refused.
	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds: []Add{{Parent: []string{"db"}, Key: "sops", Value: "fine", Kind: KindString}},
	})
	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	if got := rowByPath(t, rows, "db", "sops").Value; got != "fine" {
		t.Fatalf("db.sops = %q", got)
	}
}

// Everything else this project could think of round-trips, so the two
// refusals above are two missing refusals and not general fragility. Each
// name is checked through the real CLI *and* read back through the bridge.
func TestHostileKeyNamesRoundTripThroughTheRealCLI(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	names := []string{
		"!!str", "!custom", "&anchor", "*alias", "? question", "- dash", ": colon",
		"#hash", "%TAG", "---", "...", "null", "~", "true", "false", "no", "on", "y",
		"0", "007", ".inf", ".nan", "1.2", "2024-01-02", "a: b", "[a]", "{a}",
		"\"quoted\"", "'single'", " leading", "trailing ", "with\nnewline",
		"with\ttab", "üñí🎉", "a.b", "0x1F", "=", "<<<", "<< ", " <<", "sops",
	}
	for _, name := range names {
		t.Run(fmt.Sprintf("%q", name), func(t *testing.T) {
			// `sops` is only reserved at a document root, so everything here
			// goes into `db`, which is also the harder case for the emitter.
			out, err := ApplyChangesAndEncrypt(encrypted, ChangeSet{
				Adds: []Add{{Parent: []string{"db"}, Key: name, Value: "probe-value", Kind: KindString}},
			}, key.Private)
			if err != nil {
				t.Fatalf("refused: %v", err)
			}
			if !strings.Contains(cliDecrypt(t, key, out), "probe-value") {
				t.Fatalf("the sops CLI cannot see the added value")
			}
			rows, rowErr := DecryptToRows(out, key.Private)
			if rowErr != nil {
				t.Fatalf("the bridge cannot read back its own output: %v", rowErr)
			}
			if got := rowByPath(t, rows, "db", name).Value; got != "probe-value" {
				t.Fatalf("db.%q = %q", name, got)
			}
		})
	}
}

// -----------------------------------------------------------------------
// Replacing a key: remove it and add it again in one save
// -----------------------------------------------------------------------

// The natural gesture for "rename this key" or "change this key's type".
// Removals run before adds, so by the time the add runs the key is gone —
// the outcome is one key, at the end of its map, with the new value.
func TestAKeyCanBeRemovedAndAddedAgainInOneSave(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	out := applyChanges(t, encrypted, key, ChangeSet{
		Adds:    []Add{{Parent: []string{"db"}, Key: "port", Value: "6432", Kind: KindString}},
		Removes: []Removal{{Path: []string{"db", "port"}}},
	})

	rows, err := DecryptToRows(out, key.Private)
	if err != nil {
		t.Fatalf("DecryptToRows: %v", err)
	}
	replaced := rowByPath(t, rows, "db", "port")
	if replaced.Kind != KindString || replaced.Value != "6432" {
		t.Fatalf("the replaced key came back as %+v", replaced)
	}
	// Exactly one of it, and it moved to the end of the map, which is what
	// the editor shows while the change is pending.
	count := 0
	for _, path := range rowPaths(rows) {
		if path == "db.port" {
			count++
		}
	}
	if count != 1 {
		t.Fatalf("db.port appears %d times", count)
	}
	plain := cliDecrypt(t, key, out)
	if strings.Index(plain, "special:") > strings.Index(plain, "port: \"6432\"") {
		t.Fatalf("the replaced key did not move to the end of its map:\n%s", plain)
	}
}

// Every other same-key pair is still a contradiction.
func TestReplacingIsTheOnlySameKeyPairAllowed(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, richPlainYAML)

	for name, changes := range map[string]ChangeSet{
		"set and removed": {
			Sets:    []Edit{{Path: []string{"api_key"}, Value: "x", Kind: KindString}},
			Removes: []Removal{{Path: []string{"api_key"}}},
		},
		"set and re-created": {
			Sets:    []Edit{{Path: []string{"api_key"}, Value: "x", Kind: KindString}},
			Adds:    []Add{{Parent: nil, Key: "api_key", Value: "y", Kind: KindString}},
			Removes: []Removal{{Path: []string{"api_key"}}},
		},
		"added twice after one removal": {
			Adds: []Add{
				{Parent: nil, Key: "api_key", Value: "x", Kind: KindString},
				{Parent: nil, Key: "api_key", Value: "y", Kind: KindString},
			},
			Removes: []Removal{{Path: []string{"api_key"}}},
		},
	} {
		t.Run(name, func(t *testing.T) {
			applyChangesExpectingRefusal(t, encrypted, key, changes)
		})
	}
}

// -----------------------------------------------------------------------
// Non-canonical list indices
// -----------------------------------------------------------------------

// Every guard here compares paths as text, so "servers.1" and "servers.01"
// would be two names for one element and a conflict between them would go
// unseen — defeating the shift rule. A non-canonical index resolves to
// nothing instead.
func TestANonCanonicalListIndexResolvesToNothing(t *testing.T) {
	key := newAgeKeyPair(t)
	encrypted := encryptWithCLI(t, key, listPlainYAML)

	for _, segment := range []string{"01", "+1", " 1", "1 ", "0x1"} {
		if _, err := ApplyChangesAndEncrypt(encrypted, ChangeSet{
			Sets: []Edit{{Path: []string{"ports", segment}, Value: "1", Kind: KindInt}},
		}, key.Private); err == nil {
			t.Fatalf("a set at ports.%q was accepted", segment)
		}
		if _, err := ApplyChangesAndEncrypt(encrypted, ChangeSet{
			Removes: []Removal{{Path: []string{"ports", segment}}},
		}, key.Private); err == nil {
			t.Fatalf("a removal at ports.%q was accepted", segment)
		}
	}

	// And so the shift guard cannot be walked around with one.
	if _, err := ApplyChangesAndEncrypt(encrypted, ChangeSet{
		Sets:    []Edit{{Path: []string{"ports", "01"}, Value: "1", Kind: KindInt}},
		Removes: []Removal{{Path: []string{"ports", "1"}}},
	}, key.Private); err == nil {
		t.Fatalf("a batch addressing one element by two different strings was accepted")
	}
}
