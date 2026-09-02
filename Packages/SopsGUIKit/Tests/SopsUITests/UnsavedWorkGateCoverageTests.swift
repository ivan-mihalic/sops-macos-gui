import Foundation
import Testing
@testable import SopsUI

/// Ticket #23's acceptance criterion: "a new exit from the editor that does
/// not pass through the decision point knocks the check over." Pinning
/// `UnsavedWorkGate.isClear`'s own behaviour (`UnsavedWorkGateTests`) says
/// nothing about whether a *new* gate actually calls it — a fourth exit that
/// writes its own `!isDirty && !isSaving` next to a fourth pair of
/// `isDirty`/`isSaving`-shaped parameters would pass that suite too, because
/// nothing there ever looks outside `UnsavedWorkGate.swift`.
///
/// This is the codebase-wide half, in the shape
/// `ProcessSpawningChokepointTests`/`CBoundaryGuardCoverageTests` already
/// established for the identical class of problem (a rule that is easy to
/// honour today and easy to silently reintroduce tomorrow, because nothing
/// but review stops a new call site from not knowing the rule exists).
///
/// ## What counts as "a gate of this shape"
///
/// Any function, anywhere in the shipped app, whose parameter list carries
/// both something naming "dirty" and something naming "saving" — case
/// insensitively, so `isDirty`/`documentIsDirty` and
/// `isSaving`/`documentIsSaving`/`saveIsInFlight` all match. That is the
/// exact fingerprint of a function asking "is this document's pending state
/// settled" — every real gate this codebase has today
/// (`WorkspaceSwitchDecision.forSwitch`, `.forQuit`,
/// `SecretEditorView.canOpenAccessPanel`, and `UnsavedWorkGate.isClear`
/// itself) matches it, and nothing else in the
/// shipped app does — verified by this test's own count, not assumed.
///
/// A function matching the shape must either *be* `UnsavedWorkGate.isClear`,
/// call it directly, appear in `allowedDelegators`, or appear in
/// `knownNonGateFunctions`.
///
/// `allowedDelegators` is for a function whose whole body is handing the
/// same two booleans to another function this test has already checked —
/// `forQuit` does this (hands `documentIsDirty`/`saveIsInFlight` straight to
/// `forSwitch`), and so do `WorkspaceSwitchGate.decision` (straight to
/// `forSwitch`) and `QuitRequest.answerTerminationRequest` (straight to
/// `forQuit`, which is itself a delegator, so the chain still ends at
/// `UnsavedWorkGate.isClear`).
///
/// `knownNonGateFunctions` is for a function the fingerprint catches for a
/// different reason: it names both terms in its parameters without asking
/// "is it safe to act" at all. `UnsavedChangesTracker.update(isDirty:
/// isSaving:save:awaitSaveInFlight:)` is the one real case — a plain setter
/// that stores the two flags (and the closures to act on them later) for
/// `WorkspaceSwitchDecision`'s own callers to read back out, not a decision
/// function itself. Kept as its own list rather than folded into
/// `allowedDelegators`, because "not a gate" and "a gate that delegates" are
/// different claims a reviewer should be able to tell apart at a glance.
///
/// A new function added to either list without also being read here would
/// defeat the point, which is why both stay this small and this file names
/// each entry's reason.
///
/// ## Why source text and not `go/ast`-style parsing
///
/// Same reason as the two prior art tests: no Swift AST facility is wired
/// into this package, adding one for a single test was judged not worth it,
/// so this reuses `CBoundaryGuardCoverageTests`'s hand-rolled
/// brace/paren-matching extractor — reimplemented locally rather than
/// shared across test targets, the same choice that test's own doc comment
/// makes and for the same reason (it lives in `SopsEngineTests`; this lives
/// in `SopsUITests`).
@Suite("Every gate deciding whether a document's pending state blocks an action consults UnsavedWorkGate")
struct UnsavedWorkGateCoverageTests {

    private static let shippedTargets = ["SopsUI", "SopsEngine", "SopsHealth", "SopsProjects"]

    /// Asserted rather than derived — the same reason
    /// `CBoundaryGuardCoverageTests.knownCrossingPointCount` is a constant: a
    /// eighth match must update this number deliberately, so it cannot arrive
    /// by accident. Today's seven: `UnsavedWorkGate.isClear` itself (the
    /// canonical definition), two direct callers
    /// (`WorkspaceSwitchDecision.forSwitch`,
    /// `SecretEditorView.canOpenAccessPanel`), three delegators
    /// (`WorkspaceSwitchDecision.forQuit`, `AppShell.sectionSwitchDecision`,
    /// `QuitRequest.answerTerminationRequest`), and one non-gate
    /// (`UnsavedChangesTracker.update`) — see the type-level doc comment for
    /// what each list means.
    ///
    /// Was eight until SOPS-39 task 10. The one that went is
    /// `ProjectAccessGate.canOpen`, and it went because the button it gated
    /// does not exist: Access is a sidebar destination now, so the
    /// unsaved-work question for reaching it is asked by
    /// `WorkspaceSwitchGate.decision` — already on this list, as a delegator
    /// — rather than by a gate of its own. One fewer place to get it wrong,
    /// not one fewer guard.
    private static let knownGateFunctionCount = 6  // SOPS-42 removed SecretEditorView.canOpenAccessPanel

    /// See the type-level doc comment's "What counts as a gate of this
    /// shape" section for what belongs here and why: each entry's whole body
    /// hands the same two booleans on to a function this test has already
    /// checked, so the chain to `UnsavedWorkGate.isClear` is unbroken, just
    /// not direct.
    private static let allowedDelegators: Set<String> = [
        "WorkspaceSwitchDecision.swift:forQuit",
        "WorkspaceSelection.swift:decision",
        "QuitRequest.swift:answerTerminationRequest",
    ]

    /// A function the fingerprint catches without it being a gate at all —
    /// see the type-level doc comment's "What counts as a gate of this
    /// shape" section.
    private static let knownNonGateFunctions: Set<String> = [
        "UnsavedChangesTracker.swift:update",
    ]

    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // this file
            .deletingLastPathComponent() // SopsUITests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Sources")
    }

    @Test("every dirty/saving-shaped function calls UnsavedWorkGate.isClear, directly or through an approved delegate")
    func everyUnsavedWorkGateIsWired() throws {
        var gateFunctions: [String] = []
        var violations: [String] = []

        for target in Self.shippedTargets {
            let dir = Self.sourcesRoot.appendingPathComponent(target)
            for path in try Self.swiftFiles(under: dir) {
                let source = try String(contentsOf: path, encoding: .utf8)
                let stripped = Self.strippingComments(source)
                for function in Self.functions(in: stripped) {
                    let params = function.parameterList.lowercased()
                    let namesDirty = params.contains("dirty")
                    let namesSaving = params.contains("saving") || params.contains("saveisinflight")
                    guard namesDirty, namesSaving else { continue }

                    let label = "\(path.lastPathComponent):\(function.name)"
                    gateFunctions.append(label)

                    let isCanonicalDefinition =
                        path.lastPathComponent == "UnsavedWorkGate.swift" && function.name == "isClear"
                    let callsTheGateDirectly = function.body.contains("UnsavedWorkGate.isClear(")
                    let isApprovedDelegate = Self.allowedDelegators.contains(label)
                    let isKnownNonGate = Self.knownNonGateFunctions.contains(label)

                    if !isCanonicalDefinition, !callsTheGateDirectly, !isApprovedDelegate, !isKnownNonGate {
                        violations.append(label)
                    }
                }
            }
        }

        let countMessage = "found \(gateFunctions.count) function(s) whose parameters name both "
            + "\"dirty\" and \"saving\" (\(gateFunctions.sorted())), expected \(Self.knownGateFunctionCount) "
            + "— update knownGateFunctionCount deliberately, and confirm the new function either calls "
            + "UnsavedWorkGate.isClear, belongs in allowedDelegators (it delegates to an already-checked "
            + "gate), or belongs in knownNonGateFunctions (it isn't a decision function at all) — each "
            + "with a stated reason — before doing so"
        #expect(gateFunctions.count == Self.knownGateFunctionCount, "\(countMessage)")

        for violation in violations.sorted() {
            let message = "\(violation) takes both a dirty- and a saving-shaped parameter but never "
                + "calls UnsavedWorkGate.isClear — a new exit from a dirty document that reimplements "
                + "this check by hand instead of sharing it, exactly what ticket #23 found three of"
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

    /// Removes `//` line comments and `/* */` blocks, identical technique to
    /// `CBoundaryGuardCoverageTests.strippingComments` and
    /// `GitIgnoreOracleSafetyTests.strippingComments` — duplicated rather
    /// than shared across test targets, the same choice both of those make.
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

    private struct ExtractedFunction {
        let name: String
        /// The raw text between the function's own `(` and matching `)` —
        /// i.e. everything a caller would see as its parameter list,
        /// including default values, so a parameter renamed only in its
        /// external label still matches.
        let parameterList: String
        let body: String
    }

    /// Extracts every `func`'s name, parameter-list text and body text using
    /// brace/paren matching, not a real parser — the same technique and the
    /// same reason as `CBoundaryGuardCoverageTests.functionBodies(in:)`,
    /// reimplemented here because it additionally needs the parameter-list
    /// text that test never had to capture.
    private static func functions(in source: String) -> [ExtractedFunction] {
        var results: [ExtractedFunction] = []
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

                // Skip a generic parameter list (`<Target: Equatable>`)
                // before looking for the real parameter list's `(`.
                while j < chars.count, chars[j] == " " { j += 1 }
                if j < chars.count, chars[j] == "<" {
                    var depth = 0
                    while j < chars.count {
                        if chars[j] == "<" { depth += 1 } else if chars[j] == ">" {
                            depth -= 1
                            if depth == 0 { j += 1; break }
                        }
                        j += 1
                    }
                }

                while j < chars.count, chars[j] != "(", chars[j] != "{", chars[j] != ";" { j += 1 }
                var parameterList = ""
                if j < chars.count, chars[j] == "(" {
                    var depth = 0
                    let paramsStart = j
                    while j < chars.count {
                        if chars[j] == "(" { depth += 1 } else if chars[j] == ")" {
                            depth -= 1
                            if depth == 0 { j += 1; break }
                        }
                        j += 1
                    }
                    parameterList = String(chars[paramsStart..<j])
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
                results.append(ExtractedFunction(
                    name: name, parameterList: parameterList, body: String(chars[bodyStart..<j])))
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
