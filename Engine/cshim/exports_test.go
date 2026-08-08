package main

// The exported entry points cannot be called from a Go test: `go test` refuses
// cgo in _test.go files ("use of cgo in test not supported"), so there is no
// way to construct a *C.char here. Their behaviour is proved from both sides
// instead — gobridge/enginefault_test.go exercises the guard itself against the
// real hostile document, and Tests/SopsEngineTests/HostileDocumentTests.swift
// drives the actual C symbols through the built xcframework.
//
// What is left for this file is the thing neither of those can see: whether
// every //export is *wired* to the guard. That is the failure mode with a
// future — a tenth entry point added without one, six months from now, by
// someone who never read this. So it is checked structurally, against the
// source, rather than trusted to review.

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"strings"
	"testing"
)

// exportedEntryPointCount is asserted rather than derived so that adding an
// entry point is a deliberate act that updates this number, and cannot happen
// by accident.
const exportedEntryPointCount = 9

func TestEveryExportedEntryPointRecoversFromPanics(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "main.go", nil, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse main.go: %v", err)
	}
	source := readSource(t, "main.go")

	exported := map[string]string{}
	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Doc == nil || fn.Body == nil {
			continue
		}
		if !hasExportDirective(fn.Doc) {
			continue
		}
		start := fset.Position(fn.Body.Pos()).Offset
		end := fset.Position(fn.Body.End()).Offset
		exported[fn.Name.Name] = source[start:end]
	}

	if len(exported) != exportedEntryPointCount {
		t.Fatalf("found %d //export'ed entry points, expected %d: %v",
			len(exported), exportedEntryPointCount, names(exported))
	}

	for name, body := range exported {
		if !strings.Contains(body, "gobridge.Guard(") && !strings.Contains(body, "gobridge.GuardVoid(") {
			t.Errorf("%s does not run its work inside gobridge.Guard/GuardVoid: "+
				"a panic there terminates the host application", name)
		}
	}
}

// TestResultRecoversToo. `result` is the one step that runs outside the guard,
// because it is what writes the guard's own message out. If it can panic, the
// whole chain has a hole at the end of it.
func TestResultRecoversToo(t *testing.T) {
	fset := token.NewFileSet()
	file, err := parser.ParseFile(fset, "main.go", nil, parser.ParseComments)
	if err != nil {
		t.Fatalf("parse main.go: %v", err)
	}
	source := readSource(t, "main.go")

	for _, decl := range file.Decls {
		fn, ok := decl.(*ast.FuncDecl)
		if !ok || fn.Name.Name != "result" || fn.Body == nil {
			continue
		}
		start := fset.Position(fn.Body.Pos()).Offset
		end := fset.Position(fn.Body.End()).Offset
		if !strings.Contains(source[start:end], "recover()") {
			t.Fatal("result does not recover; a failure in C.CString would crash the host application")
		}
		return
	}
	t.Fatal("no function named result in main.go")
}

func hasExportDirective(doc *ast.CommentGroup) bool {
	for _, comment := range doc.List {
		if strings.HasPrefix(comment.Text, "//export ") {
			return true
		}
	}
	return false
}

func names(m map[string]string) []string {
	out := make([]string, 0, len(m))
	for name := range m {
		out = append(out, name)
	}
	return out
}

func readSource(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(data)
}
