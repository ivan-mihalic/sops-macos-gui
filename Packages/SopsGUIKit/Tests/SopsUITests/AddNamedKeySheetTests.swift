import Foundation
@testable import SopsEngine
import Testing
@testable import SopsUI

/// The "New key" half of `AddNamedKeySheet` (SOPS-42): the same refusals
/// `gobridge.AddNamedKey` gives, answered before the bridge is asked so the
/// Create button is dead rather than the write refused.
@Suite("AddNamedKeySheet.validateNewKey")
@MainActor
struct AddNamedKeySheetTests {

    private static let existing = [
        ConfigRules.NamedKey(name: "studio", recipient: "age1ccsm6kw9f5vx4znq75wufan68wtt6uzhn3aka7zpnyr252e87aeqt2pg0m"),
    ]
    private static let fresh = "age1fz69490r89f7gvuhcypsqn6v2yquxdw7pgryw0ujqrmx009qg4yspxs2de"

    @Test("refuses empty, flow-indicator, dotted and taken anchors", arguments: [
        ("", AddNamedKeySheet.NewKeyRefusal.emptyName),
        ("   ", .emptyName),
        ("two words", .invalidAnchor),
        ("x[y]", .invalidAnchor),
        ("a.b", .invalidAnchor),
        ("&x", .invalidAnchor),
        ("studio", .nameTaken),
    ])
    func refusesBadNames(_ name: String, _ expected: AddNamedKeySheet.NewKeyRefusal) {
        #expect(AddNamedKeySheet.validateNewKey(name: name, recipient: Self.fresh, existing: Self.existing) == expected)
    }

    @Test("refuses a private identity, garbage and a key the config already declares")
    func refusesBadKeys() {
        let priv = "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
        #expect(AddNamedKeySheet.validateNewKey(name: "deploy", recipient: priv, existing: Self.existing) == .privateIdentity)
        #expect(AddNamedKeySheet.validateNewKey(name: "deploy", recipient: "not-a-key", existing: Self.existing) == .invalidRecipient)
        #expect(AddNamedKeySheet.validateNewKey(name: "deploy", recipient: "", existing: Self.existing) == .invalidRecipient)
        #expect(AddNamedKeySheet.validateNewKey(
            name: "deploy", recipient: Self.existing[0].recipient, existing: Self.existing) == .recipientDeclared)
    }

    @Test("accepts a fresh name and key, with surrounding whitespace")
    func acceptsAFreshKey() {
        #expect(AddNamedKeySheet.validateNewKey(name: " deploy_host-2 ", recipient: " \(Self.fresh)\n", existing: Self.existing) == nil)
    }

    @Test("every refusal worth a sentence has one, and the private-key one names the rule")
    func explanations() {
        for refusal in [AddNamedKeySheet.NewKeyRefusal.invalidAnchor, .nameTaken, .invalidRecipient, .privateIdentity, .recipientDeclared] {
            #expect(AddNamedKeySheet.explanation(for: refusal) != nil, "\(refusal)")
        }
        #expect(AddNamedKeySheet.explanation(for: .emptyName) == nil)
        #expect(LocalizedKey.accessAddNamedRefusalPrivateKey.text.contains("private"))
    }
}
