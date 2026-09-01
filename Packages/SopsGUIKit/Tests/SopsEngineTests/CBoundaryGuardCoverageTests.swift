import Foundation
import Testing

/// Ticket #17 claim 4. `String.crossesCBoundaryIntact` (`SopsBridge.swift`)
/// guards the NUL-truncation hazard at the Go↔Swift boundary — a raw NUL is
/// valid UTF-8, survives a file read, and then silently ends the argument at
/// `withGoString`'s `utf8CString`, so everything after it in the document is
/// gone with no error. Three call sites applied the guard by convention
/// before this test existed (`SecretDocumentViewModel.load()`,
/// `RecipientAccessModel.load()`, `ProjectRecipientApplier.applyToOne`), and
/// a fourth (`NewSecretFileModel.unlockChosenEncryptedFile()`) did not —
/// found by an earlier version of this test, before it had this file's
/// scanner attached to it, which is the whole reason it exists: nothing
/// enforced that a function reading a file and handing it to the bridge
/// also checked first.
///
/// ## Technique
///
/// No real Swift AST is available here the way `Engine/cshim/exports_test.go`
/// has `go/ast` — this package adds no swift-syntax dependency for one test
/// — so this hand-rolls a function-body extractor using brace/paren matching
/// (`functionBodies(in:)`) and pattern-matches the stripped source, the same
/// shape `GitIgnoreOracleSafetyTests.strippingComments` (a different test
/// target) established for the sibling git-chokepoint problem. Comment
/// stripping is reimplemented locally rather than shared across targets —
/// the existing helper is `internal` to `SopsHealthTests` and this file
/// lives in `SopsEngineTests`, which only reads raw source files off disk
/// and does not otherwise depend on `SopsHealth`.
///
/// ## What counts as "reads a file into a String"
///
/// A function body containing `readFile(` (the injectable seam
/// `SecretDocumentViewModel`/`RecipientAccessModel`/`ProjectRecipientApplier`
/// share) or both `Data(contentsOf:` and `String(data:` (the shape
/// `NewSecretFileModel.unlockChosenEncryptedFile` uses for a file chosen
/// outside any of those three models' own seam). `String(contentsOf:)`
/// alone is not scanned for as a *use* — it only appears as the default
/// value bound to the `readFile` seam's own parameter
/// (`SecretDocumentViewModel.swift:257`, `RecipientAccessModel.swift:181`,
/// `ProjectRecipientApplier.swift:239`), inside an `init`'s parameter list,
/// which `functionBodies(in:)` does not descend into (see its own doc
/// comment) — so it is never mistaken for a function *body* calling it.
///
/// ## What counts as "reaches the bridge"
///
/// Every name this codebase actually uses, today, to get file content to a
/// Go bridge call that treats it as an *existing* encrypted SOPS document —
/// `SopsBridge.decrypt(`, `SopsBridge.decryptToRows(`,
/// `SopsBridge.recipients(in:`, `SopsBridge.updateRecipients(` — plus
/// `SopsBridge.encrypt(` (ticket #30, below) and three known
/// indirections through a private/injected seam this codebase already uses
/// for testability (`Self.decrypt(` and `Self.applyChanges(` in
/// `SecretDocumentViewModel`; `readRecipients(` and `rewrapRecipients(` in
/// `ProjectRecipientApplier`). A **new** indirection name introduced later —
/// a new private static helper, a new injected closure property — is
/// exactly what this list will not see, the same limit
/// `exportedEntryPointCount` has for an export in a file the directory scan
/// has not been pointed at (it does not have that limit; this does, because
/// Swift has no `//export`-shaped, greppable-by-construction marker for "this
/// is a Go bridge call"). What this test buys regardless: every *known* sink
/// name is watched everywhere it appears, so the four real crossing points
/// this codebase has today cannot regress silently, and the count assertion
/// forces a deliberate look at this file the day a fifth is added using one
/// of those same names.
///
/// ## `SopsBridge.encrypt(` is in the sink list, and the count is still 4
///
/// Ticket #30. `NewSecretFileModel.loadPlainYAML`/`.loadDotEnv` used to read
/// an import source and hand it to `encrypt` unguarded, sharing the same
/// `withGoString` truncation mechanism as the four crossing points above —
/// milder, because there is no *existing* document whose second half is
/// destroyed (the file being composed does not exist on disk yet), but no
/// less silent: `SecretFileCreator.verifyRoundTrip`'s `.verbatimYAML` branch
/// only refuses a non-empty source coming back with *zero* rows, not one
/// missing *some*, so a NUL byte crossed, truncated, and `create()` still
/// reported success. Both are guarded now, proven by a reproducing test in
/// `NewSecretFileModelTests.swift` that failed against the unguarded code
/// and passes against the fix.
///
/// This scanner still reports 4, unchanged, and that is correct rather than
/// a gap this file is hiding: `readsAFile && reachesTheBridge` are both
/// required *in the same function body* (see `everyCrossingPointIsGuarded`
/// below), and neither `loadPlainYAML` nor `loadDotEnv` calls
/// `SopsBridge.encrypt` itself — the encrypt happens later, in
/// `SecretFileCreator.create`, a different type entirely, which in turn
/// never reads a file (it receives an already-loaded `Source`). So this is
/// the same structural limit the paragraph above already names for a new
/// *indirection name*, one level further out: a multi-hop handoff through a
/// stored property and a second call, not a same-body indirection, is
/// exactly what a single-function-body scan cannot see, with or without
/// `encrypt` in this list. `encrypt` stays in the sink list anyway —
/// it now watches every *direct* same-body pairing of a file read with an
/// encrypt call this codebase has today (there are none) or gains later, the
/// identical guarantee the other four names already give.
@Suite("Every Swift string built from file content is checked before it can cross into Go")
struct CBoundaryGuardCoverageTests {

    private static let shippedTargets = ["SopsUI", "SopsEngine", "SopsHealth", "SopsProjects"]

    private static let readSignals = ["readFile("]
    private static let sinkSignals = [
        "SopsBridge.decrypt(", "SopsBridge.decryptToRows(",
        "SopsBridge.recipients(in:", "SopsBridge.updateRecipients(",
        "SopsBridge.encrypt(",
        "Self.decrypt(", "Self.applyChanges(",
        "readRecipients(", "rewrapRecipients(",
    ]

    /// Asserted rather than derived, the same reason `exportedEntryPointCount`
    /// is a constant in `Engine/cshim/exports_test.go`: adding a function
    /// that reads a file and reaches the bridge must update this number
    /// deliberately, so it cannot happen by accident. Today's four:
    /// `SecretDocumentViewModel.load`, `RecipientAccessModel.load`,
    /// `ProjectRecipientApplier.applyToOne`,
    /// `NewSecretFileModel.unlockChosenEncryptedFile`.
    private static let knownCrossingPointCount = 4

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // this file
            .deletingLastPathComponent() // SopsEngineTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources")
    }

    @Test("every function that reads a file into a String and reaches the bridge checks crossesCBoundaryIntact first")
    func everyCrossingPointIsGuarded() throws {
        var crossingPoints: [String] = []
        var unguarded: [String] = []

        for target in Self.shippedTargets {
            let dir = Self.sourcesRoot.appendingPathComponent(target)
            for path in try Self.swiftFiles(under: dir) {
                let source = try String(contentsOf: path, encoding: .utf8)
                let stripped = Self.strippingComments(source)
                for (name, body) in Self.functionBodies(in: stripped) {
                    let readsAFile = Self.readSignals.contains { body.contains($0) }
                        || (body.contains("Data(contentsOf:") && body.contains("String(data:"))
                    guard readsAFile else { continue }
                    let reachesTheBridge = Self.sinkSignals.contains { body.contains($0) }
                    guard reachesTheBridge else { continue }

                    let label = "\(path.lastPathComponent):\(name)"
                    crossingPoints.append(label)
                    if !body.contains(".crossesCBoundaryIntact") {
                        unguarded.append(label)
                    }
                }
            }
        }

        let countMessage = "found \(crossingPoints.count) function(s) that read a file and reach "
            + "the bridge (\(crossingPoints.sorted())), expected \(Self.knownCrossingPointCount) — "
            + "update knownCrossingPointCount deliberately if this is a genuine new crossing "
            + "point, and confirm it guards with crossesCBoundaryIntact before doing so"
        #expect(crossingPoints.count == Self.knownCrossingPointCount, "\(countMessage)")

        for point in unguarded.sorted() {
            let message = "\(point) reads a file and hands it to the bridge without checking "
                + "crossesCBoundaryIntact first — a NUL byte in that file is silently "
                + "dropped past this point, with no error"
            Issue.record("\(message)")
        }
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil)
        else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Removes `//` line comments and `/* */` blocks so a matched literal
    /// cannot be satisfied by a comment describing code that no longer does
    /// what it says — the identical technique, and identical reason, as
    /// `GitIgnoreOracleSafetyTests.strippingComments` in the sibling test
    /// target, duplicated rather than shared (see this suite's own doc
    /// comment for why).
    private static func strippingComments(_ source: String) -> String {
        var out = ""
        var index = source.startIndex
        var inBlock = false
        while index < source.endIndex {
            let rest = source[index...]
            if inBlock {
                guard let close = rest.range(of: "*/") else { break }
                index = close.upperBound
                inBlock = false
                continue
            }
            if rest.hasPrefix("/*") {
                inBlock = true
                index = source.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("//") {
                guard let newline = rest.firstIndex(of: "\n") else { break }
                index = newline
                continue
            }
            out.append(source[index])
            index = source.index(after: index)
        }
        return out
    }

    /// Extracts each `func`'s name and body text using brace/paren matching,
    /// not a real parser — sufficient to find where a body starts and ends
    /// without being fooled by braces inside a parameter list's default-value
    /// closures. This codebase's DI seams all look exactly like that
    /// (`readFile: @escaping (URL) throws -> String = { try
    /// String(contentsOf: $0, encoding: .utf8) }`), so the scan tracks paren
    /// depth across the whole parameter list before it starts looking for the
    /// body's own opening brace — any `{`/`}` pair encountered while inside
    /// the parameter list's parens is invisible to the body-boundary search,
    /// exactly as it should be.
    static func functionBodies(in source: String) -> [(name: String, body: String)] {
        var results: [(String, String)] = []
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            if chars[i] == "f", Self.matches(chars, at: i, "func ") {
                var j = i + "func ".count
                while j < chars.count, chars[j] == " " { j += 1 }
                var name = ""
                while j < chars.count,
                      chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
                    name.append(chars[j])
                    j += 1
                }
                guard !name.isEmpty else { i += 1; continue }

                while j < chars.count, chars[j] != "(", chars[j] != "{", chars[j] != ";" { j += 1 }
                if j < chars.count, chars[j] == "(" {
                    var depth = 0
                    while j < chars.count {
                        if chars[j] == "(" { depth += 1 } else if chars[j] == ")" {
                            depth -= 1
                            if depth == 0 { j += 1; break }
                        }
                        j += 1
                    }
                }

                // Past the return type / throws / async clauses, up to the body.
                while j < chars.count, chars[j] != "{", chars[j] != ";" { j += 1 }
                guard j < chars.count, chars[j] == "{" else { i = j + 1; continue }

                let bodyStart = j
                var depth = 0
                while j < chars.count {
                    if chars[j] == "{" { depth += 1 } else if chars[j] == "}" {
                        depth -= 1
                        if depth == 0 { j += 1; break }
                    }
                    j += 1
                }
                results.append((name, String(chars[bodyStart..<j])))
                i = j
                continue
            }
            i += 1
        }
        return results
    }

    private static func matches(_ chars: [Character], at index: Int, _ literal: String) -> Bool {
        let lit = Array(literal)
        guard index + lit.count <= chars.count else { return false }
        for k in 0..<lit.count where chars[index + k] != lit[k] { return false }
        return true
    }
}
