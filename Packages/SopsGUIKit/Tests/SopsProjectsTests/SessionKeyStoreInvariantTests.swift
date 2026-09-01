import Foundation
import Testing
@testable import SopsProjects

/// Ticket #4's third structural guard: "no raw getter can exist" for the
/// session key, today held only by the type's own doc comment ("Why `withKey`
/// instead of a getter") with nothing to enforce it. A `private var key:
/// String?` behind `withKey`'s lend-for-one-call discipline is worth exactly
/// as much as the next contributor's willingness to keep it that way — this
/// is what makes "the next contributor added `public var rawKey: String? {
/// key }` to unblock some caller in a hurry" fail a test instead of quietly
/// shipping.
///
/// A source-text guard, for the same reason `ClipboardRoutingTests` (SopsUI)
/// and `WithGoStringZeroingTests` (SopsEngine) are one: what is asserted is a
/// property of the *source* — no public member exposes the key directly — and
/// no runtime probe can see that from outside; a getter that is never called
/// by this suite is invisible to a behavioral test but perfectly real to the
/// next caller who finds it. Comments are stripped first, the same defense
/// `ClipboardRoutingTests`' own header describes being needed against.
@Suite("SessionKeyStore never exposes the raw key")
struct SessionKeyStoreInvariantTests {

    private static let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SessionKeyStoreInvariantTests.swift -> SopsProjectsTests
        .deletingLastPathComponent()   // SopsProjectsTests -> Tests
        .deletingLastPathComponent()   // Tests -> package root
        .appendingPathComponent("Sources/SopsProjects/SessionKeyStore.swift")

    private static func source() throws -> String {
        strippingComments(try String(contentsOf: sourceURL, encoding: .utf8))
    }

    @Test("the key is still stored behind a private property")
    func keyStorageIsPrivate() throws {
        let text = try Self.source()
        #expect(text.contains("private var key: String?"),
                "the session key is no longer a private String? — this guard was written against that exact shape")
    }

    /// Every `public func`'s parameter list and every `public var`'s type
    /// annotation, in turn, must not name `String` as what comes *out* of it.
    /// `String` parameters (`importKey(_ text: String)`) are fine — the key
    /// only ever flows in that direction through this type's public surface,
    /// never out.
    @Test("no public member's return type or property type is String, except the session's own public key")
    func noPublicMemberReturnsStringDirectly() throws {
        // `sessionPublicKey` (SOPS-38 phase F3) is the one deliberate
        // exception to this guard: it hands back a public age recipient
        // ("age1…"), not the private identity this guard exists to protect —
        // see `publicKey` (the backing storage)'s own doc comment for why
        // that is safe by construction, the same way `SopsBridge.recipients
        // (in:format:)` and `EncryptedFileMetadata.recipients` already hand
        // back public keys as plain `[String]` elsewhere in this app.
        // Excluded by removing its one declaration line before the regex
        // runs below, not by narrowing the regex itself, so any OTHER public
        // String-typed member — the actual defect this test exists to catch
        // — still fails it exactly as before.
        let text = try Self.source()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("var sessionPublicKey") }
            .joined(separator: "\n")

        // `public func … -> String` / `-> String?`: a func whose declared
        // return type is String itself. `withKey`'s `-> R?`/`-> R` are
        // generic and never match this literally, which is exactly the
        // point — the type parameter is what stands between "the store hands
        // back a value" and "the store hands back the key by name".
        let returnsString = try Regex(#"public\s+func\b[^\n{]*->\s*String\??"#)
        #expect(!text.contains(returnsString),
                "a public func now returns String directly — this bypasses withKey's lend-for-one-call discipline: \(text)")

        // `public var name: String` / `String?`: a property whose declared
        // type is String — a computed `{ key }` getter would be exactly this
        // shape.
        let propertyIsString = try Regex(#"public\s+var\s+\w+\s*:\s*String\??"#)
        #expect(!text.contains(propertyIsString),
                "a public var now exposes a String directly — this is the raw getter the type's own doc comment says must not exist")
    }

    /// Copied locally — see `WithGoStringZeroingTests`' identical note on why
    /// this is not shared across test targets.
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
