import Foundation
import SopsEngine
import Testing

@testable import SopsProjects

@Suite("AccessInventory")
struct AccessInventoryTests {

    @Test("a file encrypted for fewer keys than its rule declares is flagged for rewrap")
    func ruleDiffersIsFlagged() throws {
        // `build` gates the whole config-inspection path on a real
        // `.sops.yaml` existing at `projectRoot` (see its own doc comment on
        // `missingConfigIsNotAnError`'s guard) — so this test needs a real
        // scratch directory with a real (content-irrelevant, since `inspect`
        // is stubbed below) file at that path, not the brief's bare
        // `URL(fileURLWithPath:)` literals, which name nothing on disk.
        let root = try applierScratchDirectory("access-inventory")
        try Data().write(to: root.appendingPathComponent(".sops.yaml"))
        let a = try AgeKeyPair.generate().public
        let b = try AgeKeyPair.generate().public
        let c = try AgeKeyPair.generate().public
        let prod = root.appendingPathComponent("secrets/prod.sops.env")
        let local = root.appendingPathComponent("secrets/local.sops.env")
        let rules = ConfigRules(
            keys: [
                .init(name: "studio", recipient: a), .init(name: "laptop", recipient: b),
                .init(name: "vps", recipient: c),
            ],
            rules: [
                .init(
                    index: 0, pathRegex: "prod",
                    recipients: [
                        .init(name: "studio", recipient: a), .init(name: "laptop", recipient: b),
                        .init(name: "vps", recipient: c),
                    ], usesKeyGroups: true, usesAnchors: true, nonAgeBackends: [], comment: ""),
                .init(
                    index: 1, pathRegex: ".*",
                    recipients: [
                        .init(name: "studio", recipient: a), .init(name: "laptop", recipient: b),
                    ], usesKeyGroups: false, usesAnchors: false, nonAgeBackends: [], comment: ""),
            ],
            governedBy: [prod.path: 0, local.path: 1])
        let files = [
            AccessInventory.EncryptedFile(url: prod, format: .dotenv, recipients: [a, b]),
            AccessInventory.EncryptedFile(url: local, format: .dotenv, recipients: [b, a]),
        ]
        let inv = AccessInventory.build(projectRoot: root, files: files, inspect: { _, _ in rules })
        #expect(inv.files.map(\.relativePath) == ["secrets/local.sops.env", "secrets/prod.sops.env"])
        #expect(inv.files[0].status == .inSync)
        #expect(
            inv.files[1].status
                == .ruleDiffers(fileHas: [a, b].sorted(), ruleWants: [a, b, c].sorted()))
        #expect(inv.filesNeedingRewrap.map(\.relativePath) == ["secrets/prod.sops.env"])
        #expect(inv.name(for: c) == "vps")
        #expect(inv.files(governedBy: 1).map(\.relativePath) == ["secrets/local.sops.env"])
    }

    @Test("a missing .sops.yaml yields ungoverned files and no error")
    func missingConfigIsNotAnError() throws {
        let root = URL(fileURLWithPath: "/tmp/inv-none-\(UUID().uuidString)")
        let files = [
            AccessInventory.EncryptedFile(
                url: root.appendingPathComponent("a.env"), format: .dotenv, recipients: ["age1x"])
        ]
        let inv = AccessInventory.build(
            projectRoot: root, files: files,
            inspect: { _, _ in
                Issue.record("must not inspect")
                throw CancellationError()
            })
        #expect(inv.configError == nil && inv.rules.isEmpty && inv.files[0].status == .ungoverned)
    }

    @Test("a bridge failure inspecting an existing config is surfaced, not swallowed")
    func configErrorIsSurfaced() throws {
        let root = try applierScratchDirectory("access-inventory-error")
        try Data().write(to: root.appendingPathComponent(".sops.yaml"))
        let file = root.appendingPathComponent("a.env")
        let files = [AccessInventory.EncryptedFile(url: file, format: .dotenv, recipients: ["age1x"])]
        struct Boom: Error, CustomStringConvertible { let description = "bridge exploded" }
        let inv = AccessInventory.build(
            projectRoot: root, files: files,
            inspect: { _, _ in throw Boom() })
        #expect(inv.configError != nil)
        #expect(inv.rules.isEmpty)
        #expect(inv.files[0].status == .ungoverned)
    }
}
