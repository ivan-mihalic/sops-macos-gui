package gobridge

// The document API: read a SOPS file into an ordered list of editable rows,
// and write edited values back.
//
// The rule this file exists to enforce is that **Swift never parses or
// re-emits the user's YAML**. A round trip through a second YAML
// implementation silently drops comments, reorders keys and rewrites scalar
// quoting — the user's file comes back subtly different from an app they
// asked to change one value. So the document stays in Go and sops's own
// stores do the round trip, exactly as ADR 0002 requires for `.sops.yaml`:
// where we already link the authoritative implementation of a format, we use
// it rather than growing a second one.
//
// The write path is deliberately "load the tree, change values in it,
// re-encrypt that same tree". Everything the file declares about itself — its
// recipients, `encrypted_regex`, `unencrypted_suffix`, MAC settings,
// `shamir_threshold`, the sops version that wrote it — comes from the loaded
// tree and is therefore preserved without anyone having to remember to
// preserve it. That is the point: a file whose rules have drifted from the
// project's `.sops.yaml` must not be silently rewritten to match the config.
// Changing who can read a file is `updatekeys`, an explicit operation the
// user asks for (M4), not a side effect of pressing save.

import (
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/getsops/sops/v3"
	"github.com/getsops/sops/v3/aes"
	"github.com/getsops/sops/v3/cmd/sops/codes"
	"github.com/getsops/sops/v3/cmd/sops/common"
	"github.com/getsops/sops/v3/config"
	"github.com/getsops/sops/v3/logging"
)

func init() {
	// sops logs through logrus at warn level, and at least one of those calls
	// carries user content: sops.Tree.Decrypt logs the *text of a comment* it
	// failed to decrypt ("Found possibly unencrypted comment in file"). In a
	// CLI that is a helpful warning; in a GUI it is a line of the user's
	// document in stderr, a system log, or a crash report. CLAUDE.md is
	// unambiguous — naming a file or a key is fine, printing content is not.
	//
	// Every sops logger is registered in its package's init, which Go runs
	// before this one, so the map is complete by the time we get here.
	for _, l := range logging.Loggers {
		l.SetOutput(io.Discard)
	}
}

// Row kinds. These are the YAML scalar types sops can carry through its
// cipher, plus two markers for containers that have no leaves of their own.
//
// The kind is not decoration: it is what stops a port number that the editor
// displayed as "5432" from being written back as the string "5432". Swift
// hands the kind back with the edited text and the value is reconstructed as
// that type, so an untouched type stays untouched and a deliberate change of
// type is something the caller had to ask for.
const (
	KindString    = "string"
	KindInt       = "int"
	KindFloat     = "float"
	KindBool      = "bool"
	KindNull      = "null"
	KindTimestamp = "timestamp"
	// KindEmptyMap and KindEmptyList mark a key whose value is an empty
	// container. They have no leaves, so without a row for them the key would
	// simply be missing from the editor — present in the file, invisible in
	// the app. They are reported and refused for editing rather than hidden.
	KindEmptyMap  = "emptyMap"
	KindEmptyList = "emptyList"
)

// Row is one editable line of a document, in the file's own order.
type Row struct {
	// Document is the index of the YAML document this row belongs to. Almost
	// always 0; a multi-document file carries one sops block per document but
	// a single set of metadata, so without this an edit could land in the
	// wrong document.
	Document int `json:"document"`
	// Path is the key path to the value. Map keys appear verbatim; list
	// elements appear as their decimal index. There is no ambiguity between
	// the two because the path is resolved against the tree, where each level
	// is either a map or a list but never both — so "0" means the key "0"
	// under a map and index 0 under a list, decided by what is actually
	// there rather than by how the segment looks.
	Path []string `json:"path"`
	// Value is the decrypted value rendered as text. Round-tripping it
	// through Kind reproduces the original value exactly.
	Value string `json:"value"`
	// Kind is one of the Kind* constants above.
	Kind string `json:"kind"`
	// InList reports whether this row's immediate parent is a list rather
	// than a map. The editor cannot work this out from the path — a map key
	// "0" and list index 0 look identical as text, which is exactly the
	// ambiguity Path's own doc comment describes — and it has to know,
	// because adding into a list appends while adding into a map needs a
	// name. So the walk, which is looking straight at the container, says.
	InList bool `json:"inList"`
	// Encrypted reports whether this value is ciphertext in the file on disk.
	// It is read from the file rather than derived from `.sops.yaml`, so with
	// an `encrypted_regex` the editor can tell which values are actually
	// protected — and note that sops never encrypts a null or an empty
	// string, so those report false however the rules are written.
	Encrypted bool `json:"encrypted"`
}

// Edit sets the value at Path to Value, interpreted as Kind.
//
// Only existing rows can be set. Adding and removing keys changes the shape
// of the document; those live in documentchanges.go as Add and Removal, and
// travel together with edits in a ChangeSet.
type Edit struct {
	Document int      `json:"document"`
	Path     []string `json:"path"`
	Value    string   `json:"value"`
	Kind     string   `json:"kind"`
}

// encValueRe recognises a value that is sops ciphertext on disk. Taken from
// aes/cipher.go's own `encre` so that "is this encrypted?" is answered the
// same way sops answers it, rather than by a prefix check that a plaintext
// value beginning "ENC[" could fool.
var encValueRe = regexp.MustCompile(`^ENC\[AES256_GCM,data:(.+),iv:(.+),tag:(.+),type:(.+)\]`)

// loadedDocument is a decrypted tree plus everything needed to write it back.
type loadedDocument struct {
	tree    *sops.Tree
	store   common.Store
	cipher  sops.Cipher
	dataKey []byte
	// encryptedPaths records which leaves were ciphertext before decryption.
	encryptedPaths map[string]bool
}

// loadAndDecrypt performs the read half that both entry points share.
func loadAndDecrypt(encrypted []byte, agePrivateKey string) (*loadedDocument, error) {
	// Validated before the document is even looked at, so the refusal can
	// never depend on how far parsing got. See parseDecryptionIdentities:
	// upstream treats "no identities" as an invitation to read the
	// environment, including a variable it executes as a command line.
	identities, err := parseDecryptionIdentities(agePrivateKey)
	if err != nil {
		return nil, err
	}

	sf, err := FormatYAML.toSopsFormat()
	if err != nil {
		return nil, err
	}
	store := common.StoreForFormat(sf, config.NewStoresConfig())

	tree, err := loadEncryptedDocument(store, encrypted)
	if err != nil {
		return nil, err
	}

	// Captured before decryption, because afterwards there is nothing left to
	// look at: the ciphertext has been replaced by the value it carried.
	encryptedPaths, err := collectEncryptedPaths(tree.Branches)
	if err != nil {
		return nil, err
	}

	ks := &ageKeyService{identities: identities}
	cipher := aes.NewCipher()
	dataKey, err := common.DecryptTree(common.DecryptTreeOpts{
		Tree:        tree,
		Cipher:      cipher,
		KeyServices: ks.clients(),
	})
	if err != nil {
		return nil, describeDecryptFailure(tree, err)
	}

	return &loadedDocument{
		tree:           tree,
		store:          store,
		cipher:         cipher,
		dataKey:        dataKey,
		encryptedPaths: encryptedPaths,
	}, nil
}

// loadEncryptedDocument is common.LoadEncryptedFileWithBugFixes for bytes we
// already hold rather than a path we have to hand it.
//
// The upstream helper only reads from a file or from stdin, and its
// bug-fixing half is actively wrong for this app. FixAWSKMSEncryptionContextBug
// prints a page of explanation to stdout and then calls
// UpdateMasterKeysWithKeyServices *unconditionally* — it re-wraps every AWS KMS
// data key on every path through it. Its `term.IsTerminal(os.Stdout.Fd())`
// check gates only `persistFix`, i.e. whether the repaired tree is written back
// to the input path; the re-wrap itself is not optional. And an "in-memory
// only" re-wrap would reach disk anyway here, because this app emits the tree
// itself when the user saves.
//
// This build is age-only, and re-wrapping data keys is `updatekeys` — an
// operation the user asks for explicitly (M4), not something a save may do
// behind their back. So the detection is kept, called verbatim from sops, and
// the repair is refused with an explanation instead of being performed.
func loadEncryptedDocument(store common.Store, encrypted []byte) (*sops.Tree, error) {
	tree, err := store.LoadEncryptedFile(encrypted)
	if err != nil {
		// "This is not a SOPS file" is a different problem from "this does not
		// parse", and saying which is worth more than either generic message.
		if errors.Is(err, sops.MetadataNotFound) {
			return nil, errors.New("this file is not a SOPS document: it has no sops metadata")
		}
		// Never `%w`: go-yaml quotes duplicate keys, anchor names and scalar
		// values, and an encrypted file's keys are cleartext. See
		// describeYAMLFailure.
		return nil, describeYAMLFailure("this file could not be read as a SOPS document", err)
	}
	encCtxBug, err := common.DetectKMSEncryptionContextBug(&tree)
	if err != nil {
		return nil, errors.New("this file's sops metadata does not record a usable version")
	}
	if encCtxBug {
		return nil, fmt.Errorf(
			"this file carries an AWS KMS key affected by the encryption context bug fixed in sops 3.3.0; " +
				"repairing it means re-wrapping its data keys, which this app does not do behind your back — " +
				"run the sops CLI on it first")
	}
	return &tree, nil
}

// describeDecryptFailure turns a common.DecryptTree error into one this app is
// willing to show, and is the only way a decrypt failure may leave this
// package.
//
// sops's decrypt error text cannot be propagated. aes.Cipher.Decrypt unwraps
// the ciphertext first and converts second: it runs strconv.Atoi / ParseFloat /
// ParseBool / time.UnmarshalText over the *already-decrypted plaintext*, and
// hands strconv's error — which quotes its input — back to sops.Tree.Decrypt,
// which wraps it as "Could not decrypt value: …". The result is a decrypted
// secret inside an error string that the UI renders and the crash reporter
// collects.
//
// That is not a theoretical path. The declared type inside ENC[…,type:str] is
// not covered by the GCM additional data — the AAD is the key path — so
// changing type:str to type:int leaves the value authenticating perfectly and
// failing to convert. A corrupt file, a bad merge, or a hostile commit in a
// shared repository all get there.
//
// So the message is rebuilt rather than wrapped. The classification comes from
// sops's own exit codes, which cmd/sops/common attaches to every failure here,
// so it tracks upstream's own idea of what went wrong rather than matching on
// its prose.
func describeDecryptFailure(tree *sops.Tree, err error) error {
	// cli.ExitError, which common.NewExitError returns, satisfies this. Matched
	// structurally so that urfave/cli does not become an import of this package.
	coder, ok := err.(interface{ ExitCode() int })
	if !ok {
		return fmt.Errorf("this file could not be decrypted")
	}
	switch coder.ExitCode() {
	case codes.CouldNotRetrieveKey:
		return fmt.Errorf("none of the keys available to this app can decrypt this file")
	case codes.MacMismatch, codes.ErrorDecryptingMac:
		return fmt.Errorf("this file does not match its own message authentication code: " +
			"it has been modified since it was encrypted, or it is damaged")
	case codes.ErrorDecryptingTree:
		if where := firstUnreadablePath(tree, err); where != "" {
			return fmt.Errorf("a value in this file could not be read (%s); the file is damaged or was edited by hand", where)
		}
		return fmt.Errorf("a value in this file could not be read; the file is damaged or was edited by hand")
	default:
		return fmt.Errorf("this file could not be decrypted")
	}
}

// sops's own wording for the two leaf failures where the damaged value is no
// longer ciphertext. Matched to pick a search strategy — the result is a
// boolean, and no part of sops's message is ever propagated. Pinned by
// TestUpstreamDecryptFailureWordingIsUnchanged, so a change upstream is
// reported rather than silently sending users to the wrong key.
const (
	// sops.Tree.Decrypt, when a key it must decrypt does not hold a string.
	notCiphertextTypeMarker = "Expected encrypted value as string"
	// aes.Cipher.Decrypt's parse, when the string is not sops ciphertext.
	notSopsFormatMarker = "does not match sops' data format"
)

// firstUnreadablePath names the key whose value a failed decrypt stopped at.
//
// sops's error does not carry the path, and it is the one thing a user needs
// in order to repair a damaged file, so it is recovered from the tree. The
// guarantee that makes this possible: sops.Tree.Decrypt walks leaves in order,
// replaces each value in place, and returns on the first failure — so
// everything before the failing leaf is plaintext and everything from it
// onwards is untouched.
//
// A leaf can fail in three ways, and they need different searches:
//
//  1. it is still ciphertext but will not convert (a rewritten `type:` tag).
//     The leaf is still ENC[…], so it is the first such leaf. Nothing else is
//     needed.
//  2. it holds a non-string where ciphertext was expected (`beta: 42`), or
//  3. it holds a string that is not sops ciphertext (`beta: plain`).
//
// Cases 2 and 3 are the ones a naive "first leaf that still looks encrypted"
// scan gets wrong: the damaged leaf does not look encrypted, so the scan walks
// past it and names the *next* key, which is healthy. Someone following that
// advice edits the wrong thing.
//
// For those two, the damaged leaf is the last leaf sops meant to decrypt
// before the first one that is still ciphertext — because everything from the
// failure onwards is untouched. Which leaves sops meant to decrypt is decided
// by the file's own rules (encrypted_regex, suffixes, comment regexes), and
// those are not reimplemented here: the tree is handed to sops's own
// Tree.Encrypt with a throwaway key, and whichever leaves come back as ENC[…]
// are the ones its rules cover. That is what keeps a plaintext-by-rule key
// from ever being named as the damaged one.
//
// The probe destroys the tree, which is why this is only ever called on a
// failure path where the tree is about to be discarded.
//
// A key path is not a secret — CLAUDE.md permits naming a key, never a value —
// and nothing but a path can come out of here.
func firstUnreadablePath(tree *sops.Tree, cause error) string {
	leaves := encryptedLeafStates(tree)
	if len(leaves) == 0 {
		return ""
	}

	message := ""
	if cause != nil {
		message = cause.Error()
	}
	damagedLeafIsNoLongerCiphertext := strings.Contains(message, notCiphertextTypeMarker) ||
		strings.Contains(message, notSopsFormatMarker)

	if !damagedLeafIsNoLongerCiphertext {
		// Case 1. The first leaf still holding ciphertext is the one that
		// failed, because every earlier one was decrypted.
		for _, leaf := range leaves {
			if leaf.stillCiphertext {
				return leaf.label
			}
		}
		return ""
	}

	// Cases 2 and 3. Narrow to the leaves sops's own rules say are encrypted,
	// then take the last one before the untouched ciphertext begins.
	covered := leavesSopsWouldEncrypt(tree)
	if covered == nil {
		// Without the rules, any guess could name a healthy key. Say nothing.
		return ""
	}
	var previous string
	for _, leaf := range leaves {
		if !covered[leaf.key] {
			continue
		}
		if leaf.stillCiphertext {
			return previous
		}
		previous = leaf.label
	}
	// No ciphertext left at all: the damage is at the last covered leaf.
	return previous
}

// leafState is one leaf of a partially decrypted tree, in walk order.
type leafState struct {
	key             string
	label           string
	stillCiphertext bool
}

func encryptedLeafStates(tree *sops.Tree) []leafState {
	var out []leafState
	// A walk error (a non-string key) just truncates what is available.
	_ = walkLeaves(tree.Branches, func(document int, path []string, value interface{}, _ bool) error {
		label := pathLabel(path)
		if document != 0 {
			label = fmt.Sprintf("document %d, %s", document, label)
		}
		text, isString := value.(string)
		out = append(out, leafState{
			key:             pathKey(document, path),
			label:           label,
			stillCiphertext: isString && encValueRe.MatchString(text),
		})
		return nil
	})
	return out
}

// leavesSopsWouldEncrypt asks sops which leaves this file's rules cover, by
// encrypting the tree with a throwaway key and seeing which values come back
// as ciphertext. Returns nil if sops could not answer.
//
// Destroys the tree. Callers must be on their way out.
func leavesSopsWouldEncrypt(tree *sops.Tree) map[string]bool {
	probeKey := make([]byte, 32)
	if _, err := rand.Read(probeKey); err != nil {
		return nil
	}
	if _, err := tree.Encrypt(probeKey, aes.NewCipher()); err != nil {
		return nil
	}
	covered := make(map[string]bool)
	if err := walkLeaves(tree.Branches, func(document int, path []string, value interface{}, _ bool) error {
		if text, isString := value.(string); isString && encValueRe.MatchString(text) {
			covered[pathKey(document, path)] = true
		}
		return nil
	}); err != nil {
		return nil
	}
	return covered
}

// describeYAMLFailure rebuilds a go-yaml error as a message that carries its
// position and nothing else.
//
// go-yaml is not purely positional, which is easy to assume and wrong. Three
// of its messages quote the document itself:
//
//	mapping key "…" already defined at line N   — the key text
//	unknown anchor '…' referenced               — the anchor name
//	cannot unmarshal !!str `…` into map…        — the value, truncated
//
// A key is a perfectly realistic place for a secret to sit — an allow-list or
// a feature-flag map keyed by a token — and the duplicate-key check is not an
// exotic path: stores/yaml.LoadPlainFile runs a pre-decode pass for it on
// every single load, as a workaround for go-yaml/yaml#814.
//
// The line number is not secret and is the only thing in these messages worth
// keeping, so it is the only thing kept. It is extracted by matching go-yaml's
// own "line N:" prefix anchored at the start of a line — quoted text is
// escaped by %#v and %q, so it can never contain a real newline and can never
// masquerade as that prefix. Nothing but digits is copied out.
func describeYAMLFailure(summary string, err error) error {
	positions := yamlErrorPositions(err)
	switch len(positions) {
	case 0:
		return errors.New(summary)
	case 1:
		return fmt.Errorf("%s (line %s)", summary, positions[0])
	default:
		return fmt.Errorf("%s (lines %s)", summary, strings.Join(positions, ", "))
	}
}

var yamlErrorLineRe = regexp.MustCompile(`(?m)^[ \t]*(?:yaml: )?line (\d+):`)

func yamlErrorPositions(err error) []string {
	if err == nil {
		return nil
	}
	var positions []string
	seen := make(map[string]bool)
	for _, match := range yamlErrorLineRe.FindAllStringSubmatch(err.Error(), -1) {
		if number := match[1]; !seen[number] {
			seen[number] = true
			positions = append(positions, number)
			if len(positions) == 5 {
				break
			}
		}
	}
	return positions
}

// pathKey is an injective encoding of a document index and key path, used to
// look up per-path facts. Length-prefixing each segment is what makes it
// injective: no separator character has to be assumed absent from key names.
func pathKey(document int, path []string) string {
	var b strings.Builder
	b.WriteString(strconv.Itoa(document))
	for _, segment := range path {
		b.WriteByte(':')
		b.WriteString(strconv.Itoa(len(segment)))
		b.WriteByte(':')
		b.WriteString(segment)
	}
	return b.String()
}

// collectEncryptedPaths records which leaves hold sops ciphertext.
func collectEncryptedPaths(branches sops.TreeBranches) (map[string]bool, error) {
	out := make(map[string]bool)
	err := walkLeaves(branches, func(document int, path []string, value interface{}, _ bool) error {
		text, ok := value.(string)
		out[pathKey(document, path)] = ok && encValueRe.MatchString(text)
		return nil
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// walkLeaves visits every editable value in document order.
//
// Comments are skipped: a comment has no key path, so it is not a row the
// editor can render as key/value. It is not lost by being skipped — nothing
// here rebuilds the tree, values are changed in place, so anything not
// visited simply stays exactly as it was.
func walkLeaves(branches sops.TreeBranches, visit leafVisitor) error {
	for document, branch := range branches {
		if err := walkBranchLeaves(document, branch, nil, visit); err != nil {
			return err
		}
	}
	return nil
}

// leafVisitor receives one editable value. inList says whether the value's
// immediate parent is a list — see Row.InList for why that has to come from
// the walk rather than be inferred from the path.
type leafVisitor func(document int, path []string, value interface{}, inList bool) error

func walkBranchLeaves(document int, branch sops.TreeBranch, path []string, visit leafVisitor) error {
	for _, item := range branch {
		if _, isComment := item.Key.(sops.Comment); isComment {
			continue
		}
		key, ok := item.Key.(string)
		if !ok {
			// sops's own tree walk refuses these too, so this is unreachable
			// for any file sops could have written. The type is named; the
			// key itself is not, because a non-string key is not a string we
			// can vouch for.
			return fmt.Errorf("document %d: %s contains a key of type %T, and only string keys are supported",
				document, pathLabel(path), item.Key)
		}
		if err := walkValueLeaves(document, childPath(path, key), item.Value, false, visit); err != nil {
			return err
		}
	}
	return nil
}

func walkValueLeaves(document int, path []string, value interface{}, inList bool, visit leafVisitor) error {
	switch v := value.(type) {
	case sops.Comment:
		return nil
	case sops.TreeBranch:
		if len(v) == 0 {
			return visit(document, path, v, inList)
		}
		return walkBranchLeaves(document, v, path, visit)
	case []interface{}:
		if len(v) == 0 {
			return visit(document, path, v, inList)
		}
		for i, element := range v {
			if _, isComment := element.(sops.Comment); isComment {
				continue
			}
			if err := walkValueLeaves(document, childPath(path, strconv.Itoa(i)), element, true, visit); err != nil {
				return err
			}
		}
		return nil
	default:
		return visit(document, path, v, inList)
	}
}

// childPath appends a segment without ever sharing a backing array with a
// sibling — `append` on a shared slice would let one row's path overwrite the
// next one's.
func childPath(path []string, segment string) []string {
	out := make([]string, len(path)+1)
	copy(out, path)
	out[len(path)] = segment
	return out
}

func pathLabel(path []string) string {
	if len(path) == 0 {
		return "the document root"
	}
	return strings.Join(path, ".")
}

// editLabel names the row an error is about — path only. An error string is
// exactly the sort of text that reaches a log, a screenshot or a crash
// report, and this API handles plaintext.
func editLabel(e Edit) string {
	if e.Document == 0 {
		return pathLabel(e.Path)
	}
	return fmt.Sprintf("document %d, %s", e.Document, pathLabel(e.Path))
}

// describeValue renders a decrypted value as the text the editor shows,
// paired with the kind that reconstructs it.
func describeValue(value interface{}) (kind string, text string, err error) {
	switch v := value.(type) {
	case nil:
		return KindNull, "", nil
	case string:
		return KindString, v, nil
	case []byte:
		// sops's cipher has a "bytes" datatype. The YAML store never produces
		// it, but a file written by another sops front end could.
		return KindString, string(v), nil
	case int:
		return KindInt, strconv.Itoa(v), nil
	case float64:
		// Same formatting sops's own cipher uses for floats, so the text the
		// editor shows is the text sops would have stored.
		return KindFloat, strconv.FormatFloat(v, 'f', -1, 64), nil
	case bool:
		return KindBool, strconv.FormatBool(v), nil
	case time.Time:
		encoded, marshalErr := v.MarshalText()
		if marshalErr != nil {
			return "", "", fmt.Errorf("timestamp could not be rendered")
		}
		return KindTimestamp, string(encoded), nil
	case sops.TreeBranch:
		return KindEmptyMap, "", nil
	case []interface{}:
		return KindEmptyList, "", nil
	default:
		return "", "", fmt.Errorf("value of unsupported type %T", value)
	}
}

// parseEditValue is describeValue's inverse. It never echoes the text it
// failed to parse.
func parseEditValue(e Edit) (interface{}, error) {
	switch e.Kind {
	case KindString:
		return e.Value, nil
	case KindInt:
		n, err := strconv.Atoi(e.Value)
		if err != nil {
			return nil, fmt.Errorf("%s: the value is not a whole number", editLabel(e))
		}
		return n, nil
	case KindFloat:
		f, err := strconv.ParseFloat(e.Value, 64)
		if err != nil {
			return nil, fmt.Errorf("%s: the value is not a number", editLabel(e))
		}
		return f, nil
	case KindBool:
		b, err := strconv.ParseBool(e.Value)
		if err != nil {
			return nil, fmt.Errorf("%s: the value is not true or false", editLabel(e))
		}
		return b, nil
	case KindNull:
		return nil, nil
	case KindTimestamp:
		var t time.Time
		if err := t.UnmarshalText([]byte(e.Value)); err != nil {
			return nil, fmt.Errorf("%s: the value is not an RFC 3339 timestamp", editLabel(e))
		}
		return t, nil
	case KindEmptyMap, KindEmptyList:
		return nil, fmt.Errorf("%s: this key holds a container, not a value, and cannot be edited as one", editLabel(e))
	case "":
		return nil, fmt.Errorf("%s: the edit did not say what type the value is", editLabel(e))
	default:
		return nil, fmt.Errorf("%s: unknown value type %q", editLabel(e), e.Kind)
	}
}

// DecryptToRows decrypts a SOPS YAML document and returns its values as an
// ordered list of rows, using the caller-supplied age identity
// (AGE-SECRET-KEY-1…) and nothing else.
//
// The plaintext never leaves this list: the caller holds values to display
// them and hands them back through ApplyEditsAndEncrypt. The document itself
// is never re-parsed outside Go.
func DecryptToRows(encrypted []byte, agePrivateKey string) ([]Row, error) {
	doc, err := loadAndDecrypt(encrypted, agePrivateKey)
	if err != nil {
		return nil, err
	}

	rows := make([]Row, 0)
	err = walkLeaves(doc.tree.Branches, func(document int, path []string, value interface{}, inList bool) error {
		kind, text, describeErr := describeValue(value)
		if describeErr != nil {
			return fmt.Errorf("%s: %w", pathLabel(path), describeErr)
		}
		rows = append(rows, Row{
			Document:  document,
			Path:      path,
			Value:     text,
			Kind:      kind,
			InList:    inList,
			Encrypted: doc.encryptedPaths[pathKey(document, path)],
		})
		return nil
	})
	if err != nil {
		return nil, err
	}
	return rows, nil
}

// ApplyEditsAndEncrypt applies edits to the values of an existing SOPS
// document and returns the re-encrypted file.
//
// The file's own metadata is preserved, because the metadata is the one the
// document arrived with: recipients, `encrypted_regex`, `unencrypted_suffix`,
// MAC settings, `shamir_threshold` and the recorded sops version are all
// carried through untouched. Nothing here reads `.sops.yaml`. Only the
// timestamp and the MAC bound to it are rewritten, which sops does on every
// encrypt.
//
// An edited value ends up on whichever side of the file's encryption rules
// its key already put it on, for the same reason: the rules come from the
// document, and sops decides per key, so a value that was plaintext by rule
// stays readable and one that was ciphertext stays ciphertext.
//
// This is the set-only entry point and its contract is unchanged: a caller
// that only edits values passes a []Edit and gets the same behaviour and the
// same refusals it always did. Structural changes go through
// ApplyChangesAndEncrypt, which this delegates to — one implementation, so
// the two can never drift on metadata handling or error hygiene.
func ApplyEditsAndEncrypt(encrypted []byte, edits []Edit, agePrivateKey string) ([]byte, error) {
	return ApplyChangesAndEncrypt(encrypted, ChangeSet{Sets: edits}, agePrivateKey)
}

// setValueAtPath resolves a path against the tree and replaces one value.
//
// The resolution is contextual — at each step the container decides whether
// the segment is a map key or a list index — which is what makes a []string
// path unambiguous: a level is a map or a list, never both.
func setValueAtPath(branches sops.TreeBranches, edit Edit, value interface{}) error {
	notFound := func() error {
		return fmt.Errorf("%s: no such value in this document", editLabel(edit))
	}
	if len(edit.Path) == 0 {
		return fmt.Errorf("%s: an edit needs a key path", editLabel(edit))
	}
	if edit.Document < 0 || edit.Document >= len(branches) {
		return notFound()
	}

	var current interface{} = branches[edit.Document]
	for i, segment := range edit.Path {
		last := i == len(edit.Path)-1
		switch container := current.(type) {
		case sops.TreeBranch:
			index := -1
			for j := range container {
				if key, ok := container[j].Key.(string); ok && key == segment {
					index = j
					break
				}
			}
			if index < 0 {
				return notFound()
			}
			if last {
				if isContainer(container[index].Value) {
					return fmt.Errorf("%s: this key holds a map or a list, not a value", editLabel(edit))
				}
				// TreeBranch is a slice sharing its backing array with the
				// tree, so this assignment edits the document in place.
				container[index].Value = value
				return nil
			}
			current = container[index].Value
		case []interface{}:
			// Canonical indices only — see listIndex in documentchanges.go for
			// why "01" must not resolve to element 1.
			n, ok := listIndex(segment, len(container))
			if !ok {
				return notFound()
			}
			if _, isComment := container[n].(sops.Comment); isComment {
				return notFound()
			}
			if last {
				if isContainer(container[n]) {
					return fmt.Errorf("%s: this entry holds a map or a list, not a value", editLabel(edit))
				}
				container[n] = value
				return nil
			}
			current = container[n]
		default:
			// The path continues through something that has no children.
			return notFound()
		}
	}
	return notFound()
}

func isContainer(value interface{}) bool {
	switch value.(type) {
	case sops.TreeBranch, []interface{}:
		return true
	default:
		return false
	}
}

// DecryptToRowsJSON is DecryptToRows encoded for the C boundary. The row list
// is always a JSON array, never null, so the Swift side has no empty-versus-
// missing case to get wrong.
func DecryptToRowsJSON(encrypted []byte, agePrivateKey string) ([]byte, error) {
	rows, err := DecryptToRows(encrypted, agePrivateKey)
	if err != nil {
		return nil, err
	}
	payload, err := json.Marshal(rows)
	if err != nil {
		// Would mean a row value is not encodable, which cannot happen for
		// strings — but the message must still not carry one.
		return nil, fmt.Errorf("the row list could not be encoded")
	}
	return payload, nil
}

// ApplyEditsJSON is ApplyEditsAndEncrypt with the edit list carried as JSON.
func ApplyEditsJSON(encrypted []byte, editsJSON []byte, agePrivateKey string) ([]byte, error) {
	var edits []Edit
	if len(editsJSON) > 0 {
		decoder := json.NewDecoder(strings.NewReader(string(editsJSON)))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&edits); err != nil {
			// The JSON carries the values being written, so the decoder's
			// error — which quotes the offending input — is not propagated.
			return nil, fmt.Errorf("the list of edits was not valid JSON")
		}
	}
	return ApplyEditsAndEncrypt(encrypted, edits, agePrivateKey)
}
