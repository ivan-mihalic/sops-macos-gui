package gobridge

// The structural half of the document API: adding and removing keys.
//
// Everything document.go says applies here too — Swift never parses or
// re-emits the user's YAML, the tree is mutated in place and handed back to
// sops's own store, and the file's own metadata rides along untouched. What
// this file adds is the two operations that change a document's *shape*, and
// the one hazard that comes with them.
//
// # The hazard: removing a list element renumbers the rest
//
// Paths address list elements by position. Remove `ports.1` and what used to
// be `ports.2` is now `ports.1`. So a batch containing "remove ports.1" and
// "set ports.3" is genuinely ambiguous: did the caller mean the element that
// was third before the removal, or the one that is third after it? Those are
// two different values, and there is no way to tell from the batch which was
// meant.
//
// # The rule
//
// **Every path in a change set is resolved against the document as it was
// loaded**, and a batch in which that convention could be misread is refused
// rather than guessed at.
//
// Concretely, a change set is refused when a removal takes an element out of
// a list and any other change in the same batch addresses a *later* position
// in that same list. For an accepted batch the two readings coincide — the
// result is the same whichever convention the caller held — so the outcome is
// certain rather than merely plausible. That is the property this project
// keeps having to relearn: doing something certain beats doing something that
// looks right.
//
// The cost is that removing two entries from one list needs two saves. That
// is a real cost, paid deliberately. The alternative — accepting the batch
// and applying removals in descending index order — is only correct if the
// caller shares our convention, and a caller that does not would silently
// delete the wrong entry. Silence is the failure mode this codebase cannot
// afford.
//
// Two consequences worth stating, because they are what keeps the rule from
// being wider than it needs to be:
//
//   - **An add carries no index.** It names the container to add into, not a
//     position, so it can never be shifted and never participates in the
//     ambiguity. Appending to the very list a removal came out of is fine.
//   - **Removing a map key shifts nothing.** Map keys are addressed by name,
//     so a batch full of map-key removals is never ambiguous however large.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/getsops/sops/v3"
	"github.com/getsops/sops/v3/cmd/sops/common"
)

// Add creates a new entry in a container that already exists.
//
// The new entry always goes at the **end** of its container: at the end of
// the map for a map, appended for a list. There is deliberately no way to
// express "insert at position N" — an insertion renumbers every later element
// exactly as a removal does, and this API refuses that ambiguity rather than
// resolving it by guesswork.
type Add struct {
	Document int `json:"document"`
	// Parent is the path of the map or list to add into. Empty means the
	// document's root map.
	Parent []string `json:"parent"`
	// Key is the name of the new map key. It is required when Parent is a
	// map and must be empty when Parent is a list, where position is decided
	// by appending rather than by the caller. A map and a list are not
	// interchangeable and which one was meant is not something to infer.
	Key string `json:"key"`
	// Value and Kind are interpreted exactly as Edit's are.
	Value string `json:"value"`
	Kind  string `json:"kind"`
}

// Removal deletes one entry: a map key or a list element.
//
// A removal that finds nothing is an error, never a quiet no-op. It means the
// caller's picture of the document and the file on disk disagree, and
// reporting a successful save for a change that did not happen is the exact
// failure this whole milestone exists to close.
//
// A key that still has entries under it is refused. Every row the editor can
// show is a leaf or an empty container, so nothing the editor can ask for is
// lost by refusing; what refusing buys is that a mis-specified path can never
// destroy a whole subtree on the strength of one click.
type Removal struct {
	Document int      `json:"document"`
	Path     []string `json:"path"`
}

// ChangeSet is everything one save does to a document.
//
// The three lists are applied as sets, then removals, then adds. With the
// ambiguity guard above in force no change in an accepted batch can affect
// another's path, so that order is an implementation detail rather than part
// of the contract — but it is fixed so that "appended to the end" means the
// end of the list as the save leaves it.
type ChangeSet struct {
	Sets    []Edit    `json:"sets"`
	Adds    []Add     `json:"adds"`
	Removes []Removal `json:"removes"`
}

// errPathNotFound is internal: callers turn it into a message naming the path
// they were resolving, because this type has no idea which one that was.
var errPathNotFound = errors.New("path not found")

// pathText names a location in a document. Paths only — a key is nameable
// under CLAUDE.md, a value never is.
func pathText(document int, path []string) string {
	if document == 0 {
		return pathLabel(path)
	}
	return fmt.Sprintf("document %d, %s", document, pathLabel(path))
}

// addLabel names what an add is trying to create.
func addLabel(a Add) string {
	if a.Key != "" {
		return pathText(a.Document, append(append([]string{}, a.Parent...), a.Key))
	}
	return fmt.Sprintf("a new entry in %s", pathText(a.Document, a.Parent))
}

// ApplyChangesAndEncrypt applies a whole change set to a SOPS document and
// returns the re-encrypted file.
//
// The change set is validated in full against the loaded document *before*
// anything is mutated, so a refusal leaves the document exactly as it was:
// there is no half-applied save. On failure it returns no bytes at all.
//
// Everything ApplyEditsAndEncrypt guarantees about metadata holds here
// unchanged. In particular a newly added value ends up on whichever side of
// the file's own encryption rules its key puts it — sops decides that per key
// when the tree is re-encrypted, from the rules the document arrived with.
// Nothing here reads `.sops.yaml`.
func ApplyChangesAndEncrypt(encrypted []byte, changes ChangeSet, agePrivateKey string) ([]byte, error) {
	doc, err := loadAndDecrypt(encrypted, agePrivateKey)
	if err != nil {
		return nil, err
	}

	plan, err := planChanges(doc.tree.Branches, changes)
	if err != nil {
		return nil, err
	}

	for _, set := range plan.sets {
		if err := setValueAtPath(doc.tree.Branches, set.edit, set.value); err != nil {
			return nil, err
		}
	}
	for _, removal := range plan.removes {
		if err := removeAtPath(doc.tree.Branches, removal); err != nil {
			return nil, err
		}
	}
	for _, add := range plan.adds {
		if err := addAtPath(doc.tree.Branches, add.add, add.value); err != nil {
			return nil, err
		}
	}

	if err := common.EncryptTree(common.EncryptTreeOpts{
		DataKey: doc.dataKey,
		Tree:    doc.tree,
		Cipher:  doc.cipher,
	}); err != nil {
		// Not wrapped, for the reason ApplyEditsAndEncrypt states: sops's
		// tree-encryption errors interpolate the value that failed.
		return nil, fmt.Errorf("the document could not be re-encrypted")
	}

	out, err := doc.store.EmitEncryptedFile(*doc.tree)
	if err != nil {
		return nil, fmt.Errorf("the saved document could not be rendered")
	}
	return out, nil
}

// changePlan is a validated change set: every path resolved, every value
// parsed, every conflict already refused.
type changePlan struct {
	sets    []plannedSet
	adds    []plannedAdd
	removes []Removal
}

type plannedSet struct {
	edit  Edit
	value interface{}
}

type plannedAdd struct {
	add   Add
	value interface{}
}

// planChanges validates a change set against the document as loaded and
// returns it ready to apply. It never mutates the tree.
func planChanges(branches sops.TreeBranches, changes ChangeSet) (*changePlan, error) {
	plan := &changePlan{
		sets:    make([]plannedSet, 0, len(changes.Sets)),
		adds:    make([]plannedAdd, 0, len(changes.Adds)),
		removes: append([]Removal(nil), changes.Removes...),
	}

	// targets is the set of document locations this batch writes to, so that
	// two changes for one location are refused rather than silently
	// resolved. Two edits for one row mean the caller lost track of its own
	// state; picking one would write a value nobody chose.
	targets := make(map[string]bool)
	claim := func(document int, path []string) error {
		key := pathKey(document, path)
		if targets[key] {
			return fmt.Errorf("%s: the same key is changed twice in one save", pathText(document, path))
		}
		targets[key] = true
		return nil
	}

	for _, edit := range changes.Sets {
		if err := claim(edit.Document, edit.Path); err != nil {
			return nil, err
		}
		value, err := parseEditValue(edit)
		if err != nil {
			return nil, err
		}
		if err := validateSet(branches, edit); err != nil {
			return nil, err
		}
		plan.sets = append(plan.sets, plannedSet{edit: edit, value: value})
	}

	for _, removal := range changes.Removes {
		if err := claim(removal.Document, removal.Path); err != nil {
			return nil, err
		}
		if err := validateRemoval(branches, removal); err != nil {
			return nil, err
		}
	}

	for _, add := range changes.Adds {
		value, err := validateAdd(branches, add)
		if err != nil {
			return nil, err
		}
		if add.Key != "" {
			// Only a map add has a nameable destination to collide over; two
			// appends to one list are two different new entries.
			if err := claim(add.Document, append(append([]string{}, add.Parent...), add.Key)); err != nil {
				return nil, err
			}
		}
		plan.adds = append(plan.adds, plannedAdd{add: add, value: value})
	}

	if err := refuseChangesUnderARemovedKey(changes); err != nil {
		return nil, err
	}
	if err := refuseShiftedPaths(branches, changes); err != nil {
		return nil, err
	}
	return plan, nil
}

// validateSet checks a set against the loaded document so that the whole
// batch is known to be applicable before any of it is applied. setValueAtPath
// keeps its own guards — they are what actually performs the write — but
// re-checking here is what makes a refusal atomic rather than "refused after
// the first two changes already landed in the tree".
func validateSet(branches sops.TreeBranches, edit Edit) error {
	if len(edit.Path) == 0 {
		return fmt.Errorf("%s: an edit needs a key path", editLabel(edit))
	}
	value, ok := valueAtPath(branches, edit.Document, edit.Path)
	if !ok {
		return fmt.Errorf("%s: no such value in this document", editLabel(edit))
	}
	if isContainer(value) {
		return fmt.Errorf("%s: this key holds a map or a list, not a value", editLabel(edit))
	}
	return nil
}

// validateRemoval checks that a removal names something that is there and
// that removing it cannot take anything else with it.
func validateRemoval(branches sops.TreeBranches, removal Removal) error {
	where := pathText(removal.Document, removal.Path)
	if len(removal.Path) == 0 {
		return fmt.Errorf("a removal needs a key path")
	}
	value, ok := valueAtPath(branches, removal.Document, removal.Path)
	if !ok {
		return fmt.Errorf("%s: there is no such key in this document, so it cannot be removed", where)
	}
	switch container := value.(type) {
	case sops.TreeBranch:
		if len(container) > 0 {
			return fmt.Errorf("%s: this key holds a map with entries in it; remove those first", where)
		}
	case []interface{}:
		if len(container) > 0 {
			return fmt.Errorf("%s: this key holds a list with entries in it; remove those first", where)
		}
	}
	return nil
}

// validateAdd checks that an add has somewhere to go and returns the parsed
// value it would write.
func validateAdd(branches sops.TreeBranches, add Add) (interface{}, error) {
	parentWhere := pathText(add.Document, add.Parent)
	parent, ok := valueAtPath(branches, add.Document, add.Parent)
	if !ok {
		return nil, fmt.Errorf("%s: there is no such map or list in this document to add to", parentWhere)
	}

	switch container := parent.(type) {
	case sops.TreeBranch:
		if add.Key == "" {
			return nil, fmt.Errorf("%s: a new key in a map needs a name", parentWhere)
		}
		if branchIndex(container, add.Key) >= 0 {
			return nil, fmt.Errorf("%s: this key is already in the document; changing its value is an edit, not an addition",
				pathText(add.Document, append(append([]string{}, add.Parent...), add.Key)))
		}
	case []interface{}:
		if add.Key != "" {
			return nil, fmt.Errorf("%s: this is a list, and a list entry is appended rather than named", parentWhere)
		}
	default:
		return nil, fmt.Errorf("%s: this key holds a value, not a map or a list, so nothing can be added inside it", parentWhere)
	}

	value, err := parseAddValue(add)
	if err != nil {
		return nil, err
	}
	return value, nil
}

// parseAddValue is parseEditValue for an add: same vocabulary, same refusal
// to echo the text it could not parse, a label naming the new key.
func parseAddValue(add Add) (interface{}, error) {
	value, err := parseEditValue(Edit{Value: add.Value, Kind: add.Kind})
	if err != nil {
		// parseEditValue labels its message with the *edit's* path, which for
		// this synthetic Edit is empty. Rebuild it around the add's own
		// label, keeping only the fixed explanation — never the value.
		_, explanation, _ := strings.Cut(err.Error(), ": ")
		if explanation == "" {
			explanation = "the value could not be read"
		}
		return nil, fmt.Errorf("%s: %s", addLabel(add), explanation)
	}
	return value, nil
}

// refuseChangesUnderARemovedKey refuses a batch that removes a key and also
// writes to it or below it. Both readings of such a batch are defensible and
// they disagree, so neither is chosen.
func refuseChangesUnderARemovedKey(changes ChangeSet) error {
	refuse := func(removal Removal, document int, path []string) error {
		return fmt.Errorf("%s is removed by this save, and %s is written by the same save; "+
			"these two changes contradict each other",
			pathText(removal.Document, removal.Path), pathText(document, path))
	}
	for i, removal := range changes.Removes {
		// Compared change by change rather than against one merged list of
		// paths, so that a removal is never compared with its own entry —
		// and so that an add *into* the very container being removed, whose
		// parent path equals the removal path exactly, is caught rather than
		// mistaken for that self-comparison.
		for j, other := range changes.Removes {
			if i == j || other.Document != removal.Document {
				continue
			}
			if hasPrefix(other.Path, removal.Path) {
				return refuse(removal, other.Document, other.Path)
			}
		}
		for _, edit := range changes.Sets {
			if edit.Document == removal.Document && hasPrefix(edit.Path, removal.Path) {
				return refuse(removal, edit.Document, edit.Path)
			}
		}
		for _, add := range changes.Adds {
			if add.Document == removal.Document && hasPrefix(add.Parent, removal.Path) {
				return refuse(removal, add.Document, add.Parent)
			}
		}
	}
	return nil
}

// refuseShiftedPaths is the index-shift guard described at the top of this
// file: a list removal renumbers every later element, so a batch that also
// addresses one of those later positions is refused.
func refuseShiftedPaths(branches sops.TreeBranches, changes ChangeSet) error {
	for _, removal := range changes.Removes {
		if len(removal.Path) == 0 {
			continue
		}
		listPath := removal.Path[:len(removal.Path)-1]
		parent, ok := valueAtPath(branches, removal.Document, listPath)
		if !ok {
			continue
		}
		if _, isList := parent.([]interface{}); !isList {
			continue // a map key: nothing is renumbered by removing it
		}
		removedIndex, err := strconv.Atoi(removal.Path[len(removal.Path)-1])
		if err != nil {
			continue
		}

		for _, other := range referencePaths(changes) {
			// The removal's own entry needs no special case: its index is
			// the removed one, and only a *later* index can have shifted.
			if other.document != removal.Document {
				continue
			}
			if len(other.path) <= len(listPath) || !hasPrefix(other.path, listPath) {
				continue
			}
			index, err := strconv.Atoi(other.path[len(listPath)])
			if err != nil || index <= removedIndex {
				continue
			}
			return fmt.Errorf(
				"this save removes %s, which changes the position of %s in the same list; "+
					"save the removal on its own so neither change can be read the wrong way",
				pathText(removal.Document, removal.Path), pathText(other.document, other.path))
		}
	}
	return nil
}

// referencePath is one path a change set addresses. An add contributes its
// *parent* rather than the key it creates, because an add names a container
// and not a position — which is what keeps it out of the shift guard.
type referencePath struct {
	document int
	path     []string
}

func referencePaths(changes ChangeSet) []referencePath {
	out := make([]referencePath, 0, len(changes.Sets)+len(changes.Adds)+len(changes.Removes))
	for _, edit := range changes.Sets {
		out = append(out, referencePath{document: edit.Document, path: edit.Path})
	}
	for _, removal := range changes.Removes {
		out = append(out, referencePath{document: removal.Document, path: removal.Path})
	}
	for _, add := range changes.Adds {
		out = append(out, referencePath{document: add.Document, path: add.Parent})
	}
	return out
}

// hasPrefix reports whether prefix is an ancestor-or-self of path.
func hasPrefix(path, prefix []string) bool {
	if len(prefix) > len(path) {
		return false
	}
	for i := range prefix {
		if path[i] != prefix[i] {
			return false
		}
	}
	return true
}

// -----------------------------------------------------------------------
// Applying
// -----------------------------------------------------------------------

func removeAtPath(branches sops.TreeBranches, removal Removal) error {
	last := removal.Path[len(removal.Path)-1]
	err := mutateContainer(branches, removal.Document, removal.Path[:len(removal.Path)-1],
		func(parent interface{}) (interface{}, error) {
			switch container := parent.(type) {
			case sops.TreeBranch:
				index := branchIndex(container, last)
				if index < 0 {
					return nil, errPathNotFound
				}
				// The three-index slice caps capacity so the append allocates
				// rather than writing over a backing array the tree may still
				// be sharing.
				return append(container[:index:index], container[index+1:]...), nil
			case []interface{}:
				index, convErr := strconv.Atoi(last)
				if convErr != nil || index < 0 || index >= len(container) {
					return nil, errPathNotFound
				}
				return append(container[:index:index], container[index+1:]...), nil
			default:
				return nil, errPathNotFound
			}
		})
	if err != nil {
		return fmt.Errorf("%s: there is no such key in this document, so it cannot be removed",
			pathText(removal.Document, removal.Path))
	}
	return nil
}

func addAtPath(branches sops.TreeBranches, add Add, value interface{}) error {
	err := mutateContainer(branches, add.Document, add.Parent,
		func(parent interface{}) (interface{}, error) {
			switch container := parent.(type) {
			case sops.TreeBranch:
				return append(container[:len(container):len(container)],
					sops.TreeItem{Key: add.Key, Value: value}), nil
			case []interface{}:
				return append(container[:len(container):len(container)], value), nil
			default:
				return nil, errPathNotFound
			}
		})
	if err != nil {
		return fmt.Errorf("%s: there is no such map or list in this document to add to",
			pathText(add.Document, add.Parent))
	}
	return nil
}

// mutateContainer hands the container at path to mutate and writes whatever
// comes back into its holder.
//
// Going through a callback rather than returning a pointer is what makes
// adding and removing work at all: both change the *length* of a slice, and
// a Go append may return a different slice header, so the result has to be
// stored back into the parent that owns it. Values are the easy case
// (setValueAtPath assigns in place); containers are not.
func mutateContainer(
	branches sops.TreeBranches, document int, path []string,
	mutate func(interface{}) (interface{}, error),
) error {
	if document < 0 || document >= len(branches) {
		return errPathNotFound
	}
	updated, err := mutateIn(branches[document], path, mutate)
	if err != nil {
		return err
	}
	branch, ok := updated.(sops.TreeBranch)
	if !ok {
		// A document's root is a map. Nothing here can turn it into
		// something else, but the tree would be corrupt if it did.
		return errPathNotFound
	}
	branches[document] = branch
	return nil
}

func mutateIn(current interface{}, path []string, mutate func(interface{}) (interface{}, error)) (interface{}, error) {
	if len(path) == 0 {
		return mutate(current)
	}
	switch container := current.(type) {
	case sops.TreeBranch:
		index := branchIndex(container, path[0])
		if index < 0 {
			return nil, errPathNotFound
		}
		child, err := mutateIn(container[index].Value, path[1:], mutate)
		if err != nil {
			return nil, err
		}
		container[index].Value = child
		return container, nil
	case []interface{}:
		index, err := strconv.Atoi(path[0])
		if err != nil || index < 0 || index >= len(container) {
			return nil, errPathNotFound
		}
		if _, isComment := container[index].(sops.Comment); isComment {
			return nil, errPathNotFound
		}
		child, mutateErr := mutateIn(container[index], path[1:], mutate)
		if mutateErr != nil {
			return nil, mutateErr
		}
		container[index] = child
		return container, nil
	default:
		return nil, errPathNotFound
	}
}

// valueAtPath resolves a path against the tree the same way setValueAtPath
// does — contextually, with each level deciding whether a segment is a map
// key or a list index — and returns the value it names.
func valueAtPath(branches sops.TreeBranches, document int, path []string) (interface{}, bool) {
	if document < 0 || document >= len(branches) {
		return nil, false
	}
	var current interface{} = branches[document]
	for _, segment := range path {
		switch container := current.(type) {
		case sops.TreeBranch:
			index := branchIndex(container, segment)
			if index < 0 {
				return nil, false
			}
			current = container[index].Value
		case []interface{}:
			index, err := strconv.Atoi(segment)
			if err != nil || index < 0 || index >= len(container) {
				return nil, false
			}
			if _, isComment := container[index].(sops.Comment); isComment {
				return nil, false
			}
			current = container[index]
		default:
			return nil, false
		}
	}
	return current, true
}

// branchIndex finds a map key. Comment entries carry a sops.Comment key, so
// they never match a string key and are skipped for free.
func branchIndex(branch sops.TreeBranch, key string) int {
	for i := range branch {
		if name, ok := branch[i].Key.(string); ok && name == key {
			return i
		}
	}
	return -1
}

// ApplyChangesJSON is ApplyChangesAndEncrypt with the change set carried as
// JSON across the C boundary.
func ApplyChangesJSON(encrypted []byte, changesJSON []byte, agePrivateKey string) ([]byte, error) {
	var changes ChangeSet
	if len(changesJSON) > 0 {
		decoder := json.NewDecoder(strings.NewReader(string(changesJSON)))
		decoder.DisallowUnknownFields()
		if err := decoder.Decode(&changes); err != nil {
			// The JSON carries the values being written, and the decoder's
			// error quotes the input it choked on.
			return nil, fmt.Errorf("the list of changes was not valid JSON")
		}
	}
	return ApplyChangesAndEncrypt(encrypted, changes, agePrivateKey)
}
