import Foundation
import ScratchCleanup
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

/// SOPS-44: the sheet's tabs are decided by where it was opened from, and the
/// Generate tab shows a key it made without installing it anywhere.
@Suite("AddNamedKeySheet modes and generation")
@MainActor
struct AddNamedKeySheetModeTests {

    private static let existing = [
        ConfigRules.NamedKey(name: "studio", recipient: "age1ccsm6kw9f5vx4znq75wufan68wtt6uzhn3aka7zpnyr252e87aeqt2pg0m"),
    ]

    private func sheet(offersExisting: Bool, keys: [ConfigRules.NamedKey]) -> AddNamedKeySheet {
        AddNamedKeySheet(
            keys: keys, existingKeys: Self.existing, offersExisting: offersExisting,
            onPick: { _ in }, onCreate: { _, _, _ in }, onCancel: {},
            generate: { GeneratedAgeKey(privateKey: "AGE-SECRET-KEY-1TEST", publicKey: "age1test") })
    }

    @Test("opened from a rule, all three tabs are offered")
    func ruleOffersEveryTab() {
        #expect(sheet(offersExisting: true, keys: Self.existing).modes == [.existing, .add, .generate])
    }

    /// The Named keys section declares a key the config does not have yet, so
    /// "pick one the config already declares" is not a thing it can mean.
    @Test("opened from the Named keys section, the Existing tab is not offered")
    func namedKeysSectionOffersTwoTabs() {
        #expect(sheet(offersExisting: false, keys: []).modes == [.add, .generate])
    }

    @Test("every tab has a title of its own")
    func everyTabIsNamed() {
        let titles = [AddNamedKeySheet.Mode.existing, .add, .generate].map { AddNamedKeySheet.title(for: $0) }
        #expect(Set(titles).count == 3)
    }

    /// The sheet opens on a form, never on a key: minting an identity is
    /// something the user asks for, and a sheet that generated one just by
    /// being shown would leave real key material behind every time someone
    /// opened it and cancelled.
    @Test("the sheet offers the Generate tab but mints nothing until asked")
    func generateTabIsOfferedButNotRunOnAppearance() {
        let key = GeneratedAgeKey(
            privateKey: "AGE-SECRET-KEY-1SUPERSECRETVALUE", publicKey: "age1publicpart")
        let nodes = AXProbe.tree(size: CGSize(width: 520, height: 520)) {
            AddNamedKeySheet(
                keys: [], existingKeys: Self.existing, offersExisting: false,
                onPick: { _ in }, onCreate: { _, _, _ in }, onCancel: {},
                generate: { key })
        }
        let flat = nodes.map { $0.label + " " + $0.value + " " + $0.help }.joined(separator: "\n")
        // Canary: an empty tree would make the assertions below vacuous.
        #expect(flat.contains(LocalizedKey.accessAddNamedModeGenerate.text),
                "the Generate tab is not offered: \(flat)")
        #expect(!flat.contains(key.privateKey), "a key was minted just by showing the sheet: \(flat)")
        #expect(!flat.contains(key.publicKey), "a key was minted just by showing the sheet: \(flat)")
    }
}

/// The two files a generated key can be saved as. Their exact text matters:
/// a private key file is what a user still has in a year, and a public key
/// file is what gets pasted into a config.
@Suite("GeneratedKeyFiles")
struct GeneratedKeyFilesTests {

    private static let key = GeneratedAgeKey(
        privateKey: "AGE-SECRET-KEY-1EXAMPLE", publicKey: "age1example")

    @Test("the private key file carries the created stamp, the public key and the identity")
    func privateKeyFileMatchesAgeKeygen() {
        let text = GeneratedKeyFiles.privateKeyFile(Self.key, created: Date(timeIntervalSince1970: 0))
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        #expect(lines[0] == "# created: 1970-01-01T00:00:00Z")
        #expect(lines[1] == "# public key: age1example")
        #expect(lines[2] == "AGE-SECRET-KEY-1EXAMPLE")
        #expect(lines.last == "")
    }

    @Test("the public key file is the recipient and nothing else")
    func publicKeyFileIsOneLine() {
        #expect(GeneratedKeyFiles.publicKeyFile(Self.key) == "age1example\n")
    }

    @Test("file names follow the key's own name, and survive one that is not a file name")
    func fileNames() {
        #expect(GeneratedKeyFiles.fileName(for: "studio", isPrivate: true) == "studio.key")
        #expect(GeneratedKeyFiles.fileName(for: "studio", isPrivate: false) == "studio.pub")
        #expect(GeneratedKeyFiles.fileName(for: "", isPrivate: true) == "age.key")
        #expect(GeneratedKeyFiles.fileName(for: "../../etc/passwd", isPrivate: false) == "etcpasswd.pub")
    }

    /// A private key file the rest of the machine can read is a private key
    /// file in name only.
    @Test("a saved private key is 0600, a public one is left alone")
    func privateKeyIsWrittenLockedDown() throws {
        let root = try ScratchDirectoryRegistry.shared.makeDirectory("generated-key")
        defer { try? FileManager.default.removeItem(at: root) }

        let priv = root.appendingPathComponent("k.key")
        #expect(GeneratedKeyFiles.write(GeneratedKeyFiles.privateKeyFile(Self.key), to: priv, isPrivate: true) == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: priv.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)

        let pub = root.appendingPathComponent("k.pub")
        #expect(GeneratedKeyFiles.write(GeneratedKeyFiles.publicKeyFile(Self.key), to: pub, isPrivate: false) == nil)
        #expect(try String(contentsOf: pub, encoding: .utf8) == "age1example\n")
    }

    @Test("a write that cannot happen is reported, and the message never quotes the key")
    func unwritableIsReported() {
        let failure = GeneratedKeyFiles.write(
            GeneratedKeyFiles.privateKeyFile(Self.key),
            to: URL(fileURLWithPath: "/no/such/directory/k.key"), isPrivate: true)
        let message = try? #require(failure)
        #expect(message?.contains("k.key") == true)
        #expect(message?.contains("AGE-SECRET-KEY-1EXAMPLE") == false)
    }
}
