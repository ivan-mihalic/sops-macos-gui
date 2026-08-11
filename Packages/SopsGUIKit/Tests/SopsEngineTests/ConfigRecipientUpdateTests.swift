import Foundation
import Testing

@testable import SopsEngine

/// The bridge's config *writer*, driven across the real C boundary.
///
/// The entry point is deliberately incapable of writing: it computes the text
/// a caller may write. These tests hold that from the Swift side — the config
/// on disk is compared byte for byte after every call — because the whole
/// separation between "propose" and "apply" rests on it.
@Suite("SopsBridge.updateConfigRecipients")
struct ConfigRecipientUpdateTests {

    /// A `.sops.yaml` plus the directory holding it, so a target path under
    /// the same directory can be built (sops matches `path_regex` against the
    /// target *relative to the config's own directory*).
    private func config(_ contents: String) throws -> (path: String, directory: URL) {
        let file = try TempFile(named: ".sops.yaml", contents: contents)
        return (file.path, URL(fileURLWithPath: file.path).deletingLastPathComponent())
    }

    @Test("a flat age-only rule comes back rewritable, with the new text and nothing written")
    func rewritesAFlatRule() throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let text = """
            # Team configuration
            creation_rules:
              - path_regex: .*\\.yaml$
                age:
                  - \(owner.public)

            """
        let (path, directory) = try config(text)
        let target = directory.appendingPathComponent("secret.yaml").path

        let update = try SopsBridge.updateConfigRecipients(
            configPath: path, targetFilePath: target,
            to: [owner.public, added.public], candidateFilePaths: [target])

        #expect(update.writable)
        #expect(update.changed)
        #expect(update.reason.isEmpty)
        #expect(update.ruleIndex == 0)
        #expect(update.currentRecipients == [owner.public])
        #expect(update.matchedFiles == [target])
        #expect(update.config.contains("# Team configuration"))
        #expect(update.config.contains(added.public))

        // Nothing was written. This is the whole contract.
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
    }

    @Test("an empty recipient list inspects the rule without proposing anything")
    func inspectsWithoutProposing() throws {
        let owner = try AgeKeyPair.generate()
        let text = """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)

            """
        let (path, directory) = try config(text)
        let target = directory.appendingPathComponent("secret.yaml").path

        let update = try SopsBridge.updateConfigRecipients(
            configPath: path, targetFilePath: target, to: [], candidateFilePaths: [target])

        #expect(update.writable)
        #expect(!update.changed)
        #expect(update.config.isEmpty)
        #expect(update.currentRecipients == [owner.public])
        #expect(update.matchedFiles == [target])
    }

    @Test("a rule mixing age with another backend is read-only, and says which backend")
    func refusesAMixedRule() throws {
        let owner = try AgeKeyPair.generate()
        let (path, directory) = try config("""
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)
                pgp: 0000000000000000000000000000000000AAAA
            """)
        let target = directory.appendingPathComponent("secret.yaml").path

        let update = try SopsBridge.updateConfigRecipients(
            configPath: path, targetFilePath: target, to: [owner.public])

        #expect(!update.writable)
        #expect(update.config.isEmpty)
        #expect(update.reason.contains("pgp"))
        // A refusal still says which rule it is about, so a caller can show
        // the file list alongside the explanation.
        #expect(update.ruleIndex == 0)
    }

    @Test("a private identity handed in as a recipient is refused without being quoted back")
    func refusesAPrivateIdentity() throws {
        let owner = try AgeKeyPair.generate()
        let (path, directory) = try config("""
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)
            """)
        let target = directory.appendingPathComponent("secret.yaml").path

        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.updateConfigRecipients(
                configPath: path, targetFilePath: target, to: [owner.private])
        }
        do {
            _ = try SopsBridge.updateConfigRecipients(
                configPath: path, targetFilePath: target, to: [owner.private])
        } catch let error as SopsBridgeError {
            #expect(!error.description.contains(owner.private))
        }
    }

    @Test("a missing config is an error, not a silent refusal")
    func missingConfigThrows() throws {
        let owner = try AgeKeyPair.generate()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sops-spike-" + UUID().uuidString)
        #expect(throws: SopsBridgeError.self) {
            try SopsBridge.updateConfigRecipients(
                configPath: directory.appendingPathComponent(".sops.yaml").path,
                targetFilePath: directory.appendingPathComponent("secret.yaml").path,
                to: [owner.public])
        }
    }
}
