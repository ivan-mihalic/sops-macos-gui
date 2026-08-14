import Foundation
import Testing
@testable import SopsEngine

/// Ticket #4's "buffers this app actually owns" — `agePrivateKey.withGoString`
/// (`SopsBridge.swift`) copies a `String` into a heap-allocated `[CChar]` to
/// hand a mutable pointer across the cgo boundary. That copy is real,
/// app-owned storage this type *can* zero on the way out, unlike the `String`
/// it came from (see `SessionKeyStore`'s doc comment for why a `String`
/// itself cannot be).
///
/// `zeroCString` is tested directly, against a real buffer this suite
/// controls, rather than by trying to read `bytes` back out of `withGoString`
/// after it returns: by the time that call returns, `bytes` has already gone
/// out of scope and reading its freed storage would be undefined behavior —
/// not a test, a crash waiting to happen. `withGoStringZeroesOnTheWayOut`
/// below proves the two are actually wired together, from source, the same
/// way `ClipboardRoutingTests` proves a call site without a runtime probe
/// that could see it.
@Suite("withGoString zeroes its buffer")
struct WithGoStringZeroingTests {

    @Test("zeroCString overwrites every byte, not just the ones before the NUL terminator")
    func zeroCStringOverwritesEveryByte() {
        var bytes: [CChar] = Array("AGE-SECRET-KEY-1EXAMPLE".utf8CString)
        #expect(bytes.contains { $0 != 0 }, "the fixture must start non-zero or this test proves nothing")

        SopsBridge.zeroCString(&bytes)

        #expect(bytes.allSatisfy { $0 == 0 }, "a byte survived zeroing")
        // The length must not have changed either — zeroing a buffer is not
        // the same operation as truncating it, and a shorter array would
        // still read as "no leftover key bytes" by accident rather than by
        // the mechanism this test is supposed to prove.
        #expect(bytes.count == "AGE-SECRET-KEY-1EXAMPLE".utf8CString.count)
    }

    @Test("an empty buffer is a no-op, not a crash")
    func emptyBufferIsANoOp() {
        var bytes: [CChar] = []
        SopsBridge.zeroCString(&bytes)
        #expect(bytes.isEmpty)
    }

    /// Source-text guard, for the reason `ClipboardRoutingTests` states at
    /// length: what this asserts is that a particular call sits at a
    /// particular site, guaranteed to run whether `body` returns normally or
    /// throws — no runtime probe can observe that from outside, because the
    /// buffer it protects is gone the moment the call returns either way.
    @Test("withGoString zeroes its buffer in a defer, so it runs on every exit path")
    func withGoStringZeroesOnTheWayOut() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WithGoStringZeroingTests.swift -> SopsEngineTests
            .deletingLastPathComponent()   // SopsEngineTests -> Tests
            .deletingLastPathComponent()   // Tests -> package root
            .appendingPathComponent("Sources/SopsEngine/SopsBridge.swift")
        let text = Self.strippingComments(try String(contentsOf: sourceRoot, encoding: .utf8))

        guard let range = text.range(of: "func withGoString"),
              let bodyStart = text[range.upperBound...].firstIndex(of: "{")
        else {
            Issue.record("could not find withGoString's declaration in SopsBridge.swift")
            return
        }
        // From the opening brace to the matching close, by depth — the same
        // technique `LocalizationTests.formatCalls` uses to bound a call
        // without truncating on a nested brace.
        var depth = 0
        var index = bodyStart
        var end = text.endIndex
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 { end = text.index(after: index); break }
            }
            index = text.index(after: index)
        }
        let functionBody = text[bodyStart..<end]

        #expect(functionBody.contains("defer"),
                "withGoString no longer zeroes on every exit path: \(functionBody)")
        #expect(functionBody.contains("zeroCString"),
                "withGoString no longer zeroes its buffer before returning: \(functionBody)")
    }

    /// Copied locally rather than shared across test targets — `SopsUITests`'
    /// `ClipboardRoutingTests` and `SopsHealthTests`' `GitIgnoreOracleSafetyTests`
    /// each keep their own copy for the same reason: different test targets,
    /// no shared test-support module to put it in.
    static func strippingComments(_ source: String) -> String {
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
}
