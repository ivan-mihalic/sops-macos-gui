import Foundation
import ScratchCleanup
import SopsEngine
import SopsProjects
import Testing

@testable import SopsUI

// MARK: - Fixture plumbing
//
// Real temporary project roots, real `age-keygen` keys, and the real
// in-process bridge throughout — no mocks, matching the discipline phase 1
// stood on and Task 1's `CreationFailurePresenterTests.swift` already
// restates for this test target. Mirrors the per-file `AgeKeyPair`/
// `scratchDirectory` pattern that file and `ProjectRecipientApplierTests
// .swift`/`SecretFileCreatorTests.swift` all use — shelling out to
// `age-keygen` because there is no in-process keygen.

private struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func toolPath(_ name: String) throws -> String {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        .map { ($0 as NSString).appendingPathComponent(name) }
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw FixtureError("\(name) not found in \(candidates)")
    }
    return found
}

@discardableResult
private func run(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw FixtureError(
            "\(executable) \(arguments.joined(separator: " ")) exited \(process.terminationStatus): "
                + String(decoding: errData, as: UTF8.self))
    }
    return String(decoding: outData, as: UTF8.self)
}

private struct AgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> AgeKeyPair {
        let output = try run(try toolPath("age-keygen"), [])
        var priv = "", pub = ""
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw FixtureError("age-keygen produced no usable key pair")
        }
        return AgeKeyPair(private: priv, public: pub)
    }
}

private func scratchDirectory(_ label: String = "new-secret-file-model") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A `.sops.yaml` with one age-only creation rule naming `recipient`, in the
/// shape `CreationPlanResolverTests`/`ProjectRecipientApplierTests` already
/// use.
private func ageOnlyConfig(_ recipient: String) -> String {
    """
    creation_rules:
      - path_regex: .*\\.yaml$
        age: \(recipient)
    """ + "\n"
}

@MainActor
private func makeKeyStore(importing key: String? = nil) throws -> SessionKeyStore {
    let store = SessionKeyStore()
    if let key {
        try store.importKey(key)
    }
    return store
}

@Suite("NewSecretFileModel")
@MainActor
struct NewSecretFileModelTests {

    // MARK: - .needsName

    @Test("an empty name is needsName, and the resolver is never asked about the project root itself")
    func emptyNameIsNeedsName() async throws {
        let root = try scratchDirectory()
        // Deliberately never created: if `resolvePlan()` failed to
        // short-circuit and called `CreationPlanResolver.plan(forTarget:
        // projectRoot, in: projectRoot)` anyway, that project root not
        // existing would throw `.projectRootDoesNotExist`, and `readiness`
        // would come back `.blocked`, not `.needsName` — this is the
        // negative-space check that the short-circuit in `resolvePlan()`'s
        // own doc comment describes is real code, not just the default.
        let missingRoot = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: missingRoot, keyStore: keyStore)

        await model.resolvePlan()

        #expect(model.readiness == .needsName)
        #expect(model.plan == nil)
        #expect(model.planError == nil)
    }

    // MARK: - .ready

    @Test("a name governed by an age rule that includes this session's key is ready")
    func governedByRuleWithOwnKeyIsReady() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        #expect(model.readiness == .ready(recipients: [owner.public]))
        #expect(model.plan == .governedByRule(recipients: [owner.public], encryptedRegex: ""))
    }

    // MARK: - .needsAcknowledgement, discovered only by attempting create()

    @Test(
        """
        a plan whose recipients do not include this session's key is optimistically ready, \
        then needsAcknowledgement once create() actually discovers it, \
        then ready again once acknowledged — and creates a file the real recipient can read
        """
    )
    func selfReadabilityIsDiscoveredNotPredicted() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // The rule names only `stranger` — `owner`'s session key is nowhere
        // in it.
        try ageOnlyConfig(stranger.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        // Optimistic: `resolvePlan()` alone cannot know `owner`'s key is not
        // among `stranger`'s — see this type's doc comment, "Self-readability
        // cannot be predicted, only discovered".
        #expect(model.readiness == .ready(recipients: [stranger.public]))

        let firstAttempt = await model.create()

        #expect(firstAttempt == nil)
        #expect(model.readiness == .needsAcknowledgement)
        #expect(model.planError != nil)
        // Nothing was written — the acknowledgement gate refuses before
        // `finishWriting` in `SecretFileCreator` ever runs.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.yaml").path))

        model.acknowledgedUnreadable = true

        // Flips back to `.ready` immediately, without another
        // `resolvePlan()` call — the property observer on
        // `acknowledgedUnreadable`.
        #expect(model.readiness == .ready(recipients: [stranger.public]))

        let secondAttempt = await model.create()
        let destination = try #require(secondAttempt)

        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        // `owner`'s key cannot read this back — that is the whole point of
        // what was just acknowledged — but the real recipient, `stranger`,
        // can, proving the file really was encrypted for the rule's actual
        // recipient set and not silently for `owner` instead.
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: stranger.private)
        #expect(rows.isEmpty)
    }

    // MARK: - .blocked: no .sops.yaml (until Task 5 adds a manual picker)

    @Test("no .sops.yaml is blocked, until Task 5 adds a manual recipient picker")
    func noConfigIsBlocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        #expect(model.plan == .noConfig)
        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(!message.detail.isEmpty)
    }

    // MARK: - .blocked: unsupported backend, sentence names it

    @Test("a rule naming pgp is blocked, and the sentence names the backend")
    func pgpRuleIsBlockedNamingBackend() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(message.detail.contains("pgp"))
    }

    // MARK: - .blocked: deleted project root, sentence does not name .sops.yaml

    @Test("a project root that no longer exists is blocked, and the sentence does not name .sops.yaml")
    func deletedProjectRootDoesNotNameSopsYaml() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: project, keyStore: keyStore)

        try FileManager.default.removeItem(at: project)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(!message.detail.contains(".sops.yaml"))
    }

    // MARK: - .blocked: empty SessionKeyStore

    @Test("an empty session key store is blocked, with a sentence about needing a key")
    func emptySessionKeyStoreIsBlocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore()  // nothing imported
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(message.detail.localizedCaseInsensitiveContains("key"))
    }

    // MARK: - create() on .ready, end to end against the real bridge

    @Test("create() on a ready plan produces a file decryptToRows can read back")
    func createOnReadyPlanProducesReadableFile() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()
        guard case .ready = model.readiness else {
            Issue.record("expected .ready, got \(model.readiness)")
            return
        }

        let created = await model.create()
        let destination = try #require(created)

        #expect(destination.path == root.appendingPathComponent("secret.yaml").path)
        let encrypted = try String(contentsOf: destination, encoding: .utf8)
        let rows = try SopsBridge.decryptToRows(encrypted, agePrivateKey: owner.private)
        #expect(rows.isEmpty)
        #expect(model.planError == nil)
    }
}
