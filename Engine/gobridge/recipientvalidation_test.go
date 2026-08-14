package gobridge

// Ticket #9, claim 2. `Encrypt` used to carry its own hand-written copy of
// "native age recipient only, no private key, no plugin" instead of calling
// nativeAgeMasterKeys (recipients.go), the validator UpdateRecipients and
// validAgeRecipients (configwrite.go) already share. The two implementations
// happened to agree — bridge_test.go and recipients_test.go each proved their
// own side independently — but nothing made them agree: a third
// recipients-to-sops path could add a third copy, forget the plugin-prefix
// check, and every existing test would stay green, because none of them
// looks at another path's source.
//
// This is the same failure shape exports_test.go names for the Go/C
// boundary: a rule enforced by convention at N call sites has N-1 ways to
// rot silently. The fix there is structural rather than a strings.Contains,
// because a comment satisfies a substring check (verified there, by mutation
// — see that file's own header); this reuses the identical technique, an
// AST walk over this package's real, non-test source, scoped to this
// package's recipient-acceptance surface.
//
// Two things are asserted, both aimed at the exact shape the old Encrypt
// took:
//
//  1. sopsage.MasterKeysFromRecipients — upstream sops's own "parse a
//     comma-joined recipient string" helper, with none of this app's own
//     refusals built in — is never called anywhere in this package. It is
//     exactly what the old Encrypt reached for, and exactly what a new path
//     written in a hurry reaches for next: it is the obvious, unguarded API
//     with the right-shaped name.
//  2. `&sopsage.MasterKey{Recipient: ...}` — the composite literal that turns
//     a bare string into a member of a KeyGroup sops will actually encrypt
//     to or decrypt with — is constructed in exactly one function,
//     nativeAgeMasterKeys. The two other places this package builds a
//     sopsage.MasterKey (bridge.go's ageKeyService.Decrypt/Encrypt) do not
//     use this shape (no `&`, not appended to any KeyGroup): they wrap a
//     recipient the tree's own metadata already carried, for one keyservice
//     round trip, and never mint a new group member from a caller-supplied
//     string. This test does not, and must not, flag those.

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"sort"
	"strings"
	"testing"
)

func TestRecipientValidationHasExactlyOneChokepoint(t *testing.T) {
	files, fset, err := parseNonTestPackage(".")
	if err != nil {
		t.Fatalf("parse gobridge: %v", err)
	}

	var upstreamCalls []string
	var nativeKeyLiteralFuncs []string

	for _, file := range files {
		for _, decl := range file.Decls {
			fn, ok := decl.(*ast.FuncDecl)
			if !ok || fn.Body == nil {
				continue
			}
			ast.Inspect(fn.Body, func(n ast.Node) bool {
				switch node := n.(type) {
				case *ast.CallExpr:
					if isPackageSelector(node.Fun, "sopsage", "MasterKeysFromRecipients") {
						upstreamCalls = append(upstreamCalls,
							fmt.Sprintf("%s (%s)", fn.Name.Name, fset.Position(node.Pos())))
					}
				case *ast.UnaryExpr:
					if node.Op == token.AND && isNativeMasterKeyLiteral(node.X) {
						nativeKeyLiteralFuncs = append(nativeKeyLiteralFuncs, fn.Name.Name)
					}
				}
				return true
			})
		}
	}

	for _, call := range upstreamCalls {
		t.Errorf("%s calls sopsage.MasterKeysFromRecipients directly — this bypasses "+
			"nativeAgeMasterKeys's AGE-SECRET-KEY-1 and plugin-prefix refusals. Recipients "+
			"supplied to this package must be validated through nativeAgeMasterKeys "+
			"(recipients.go), the one place this app's own rules live", call)
	}

	if len(nativeKeyLiteralFuncs) == 0 {
		t.Fatal("found no &sopsage.MasterKey{Recipient: ...} construction at all in this " +
			"package — nativeAgeMasterKeys itself may have been rewritten to a different shape; " +
			"this test's premise no longer holds and needs re-checking, not a silent pass")
	}
	for _, fnName := range nativeKeyLiteralFuncs {
		if fnName != "nativeAgeMasterKeys" {
			t.Errorf("%s constructs &sopsage.MasterKey{Recipient: ...} directly — only "+
				"nativeAgeMasterKeys may mint a key-group member from a recipient string. A "+
				"second place doing this is a second, independent implementation of recipient "+
				"validation that can silently drift from the first", fnName)
		}
	}
}

// parseNonTestPackage parses every non-test .go file in dir, mirroring
// Engine/cshim/exports_test.go's inspectGuardWiring(nil): every file in the
// directory, not just one named file, so a new file introducing a second
// implementation is in scope from the moment it exists.
func parseNonTestPackage(dir string) ([]*ast.File, *token.FileSet, error) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, dir, func(info os.FileInfo) bool {
		return !strings.HasSuffix(info.Name(), "_test.go")
	}, 0)
	if err != nil {
		return nil, nil, err
	}

	var names []string
	for name := range pkgs {
		names = append(names, name)
	}
	sort.Strings(names)

	var files []*ast.File
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
		return nil, nil, fmt.Errorf("no non-test Go files found in %s", dir)
	}
	return files, fset, nil
}

func isPackageSelector(expr ast.Expr, pkg, name string) bool {
	sel, ok := expr.(*ast.SelectorExpr)
	if !ok {
		return false
	}
	ident, ok := sel.X.(*ast.Ident)
	return ok && ident.Name == pkg && sel.Sel.Name == name
}

func isNativeMasterKeyLiteral(expr ast.Expr) bool {
	lit, ok := expr.(*ast.CompositeLit)
	if !ok {
		return false
	}
	return isPackageSelector(lit.Type, "sopsage", "MasterKey")
}
