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

// `allStrings(reachableFrom:)`/`modelRetains(_:_:)` — the Mirror-sweep leak
// proof both this file and `EncryptedImportPreviewTests.swift` need — live
// in `MirrorSweepTestSupport.swift`, `internal` to this test target. A
// review round found two byte-identical `private` copies and asked for the
// third, shared one instead of a third copy.

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

    // MARK: - targetFormat (task SOPS-38)
    //
    // Pure, name-only, and needs no resolve at all — `SopsFileFormat
    // .forDestinationName(_:)` is the single place this decision is made;
    // these tests are the model-level proof that `targetFormat` calls it and
    // nothing else, mirroring `SopsFileFormatDestinationNameTests`'s own
    // coverage of that function one layer down.

    @Test("no name typed yet has no target format")
    func blankNameHasNoTargetFormat() throws {
        let root = try scratchDirectory()
        let model = NewSecretFileModel(projectRoot: root, keyStore: try makeKeyStore())

        #expect(model.targetFormat == nil)
        model.relativeName = "   "
        #expect(model.targetFormat == nil, "whitespace-only is still blank")
    }

    @Test("a .yaml-named target reports .yaml")
    func yamlNamedTargetReportsYAML() throws {
        let root = try scratchDirectory()
        let model = NewSecretFileModel(projectRoot: root, keyStore: try makeKeyStore())

        model.relativeName = "secrets/production.yaml"

        #expect(model.targetFormat == .yaml)
    }

    @Test("a .env-named target reports .dotenv, and it tracks every keystroke live — no resolve needed")
    func dotEnvNamedTargetReportsDotenv() throws {
        let root = try scratchDirectory()
        let model = NewSecretFileModel(projectRoot: root, keyStore: try makeKeyStore())

        model.relativeName = "secret.yaml"
        #expect(model.targetFormat == .yaml)

        model.relativeName = ".sops.env"
        #expect(model.targetFormat == .dotenv, "no resolvePlan() call in between — targetFormat is pure")
    }

    @Test("a .json-named target reports .json, a .ini-named target reports .ini (SOPS-38 phase F2 task 5)")
    func jsonAndINITargetsReportTheirOwnFormat() throws {
        let root = try scratchDirectory()
        let model = NewSecretFileModel(projectRoot: root, keyStore: try makeKeyStore())

        model.relativeName = "secret.json"
        #expect(model.targetFormat == .json)

        model.relativeName = "secret.ini"
        #expect(model.targetFormat == .ini, "no resolvePlan() call in between — targetFormat is pure")
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
        // Deliberately `nil`, not the `wouldBeUnreadable` message — fixed
        // after a second-review finding (Task 4's SDD ledger): nothing
        // renders `planError` while `readiness == .needsAcknowledgement`,
        // and leaving it set let `computeReadiness()`'s own `if let
        // planError { return .blocked(planError) }` short-circuit ahead of
        // the `discoveredUnreadable`/`acknowledgedUnreadable` check, so a
        // later recompute from anywhere other than a direct tick (picking a
        // different source file, in the wizard the checkbox actually ships
        // in) silently swapped the checkbox for a stale failure banner
        // about a create attempt the user had already moved on from.
        #expect(model.planError == nil)
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
        // The real recipient, `stranger`, can read it back — proving the
        // file really was encrypted for the rule's actual recipient set and
        // not silently for `owner` instead.
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: stranger.private)
        #expect(rows.isEmpty)
        // And `owner`'s key genuinely cannot — not just "almost certainly
        // can't" by construction of age recipients: this is the one
        // assertion the whole acknowledgement path leans on, so it is
        // proven directly rather than left to a comment.
        #expect(throws: (any Error).self) {
            try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        }
    }

    // MARK: - acknowledgedUnreadable does not survive a name change

    /// Regression test for a real hole: `acknowledgedUnreadable` used to stay
    /// `true` after `relativeName` changed to a second, differently-governed
    /// path, so `create()` skipped `SecretFileCreator`'s round-trip
    /// verification entirely for a plan the user was never actually warned
    /// about — see `resolvePlan()`'s own comment on why it resets
    /// `acknowledgedUnreadable`, not only `discoveredUnreadable`. This test
    /// fails on the old behavior: without the reset, the second `create()`
    /// call below would succeed silently instead of demanding a fresh
    /// acknowledgement.
    @Test("acknowledging unreadability for one name does not silently cover a second, differently-governed name")
    func acknowledgementDoesNotCarryAcrossANameChange() async throws {
        let owner = try AgeKeyPair.generate()
        let strangerA = try AgeKeyPair.generate()
        let strangerB = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // Two rules, each excluding `owner` in favor of a different
        // stranger, so the second plan is not just a different path but a
        // genuinely different recipient set.
        try """
            creation_rules:
              - path_regex: a\\.yaml$
                age: \(strangerA.public)
              - path_regex: b\\.yaml$
                age: \(strangerB.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)

        model.relativeName = "a.yaml"
        await model.resolvePlan()
        _ = await model.create()  // discovers wouldBeUnreadable for a.yaml
        #expect(model.readiness == .needsAcknowledgement)
        model.acknowledgedUnreadable = true
        #expect(model.readiness == .ready(recipients: [strangerA.public]))

        // Switch to a second name, governed by a different rule that also
        // excludes `owner`.
        model.relativeName = "b.yaml"
        await model.resolvePlan()

        // The acknowledgement must not have carried over: `resolvePlan()`
        // reset it, so this is the same optimistic `.ready` every fresh
        // resolve produces, not a state that skips verification.
        #expect(model.acknowledgedUnreadable == false)
        #expect(model.readiness == .ready(recipients: [strangerB.public]))

        let bAttempt = await model.create()

        // If the acknowledgement had survived, this would have succeeded
        // silently with no content verification at all. Instead, the
        // round-trip runs again, discovers the same problem for the new
        // plan, and refuses — exactly as if `b.yaml` had never been
        // preceded by an acknowledged `a.yaml`.
        #expect(bAttempt == nil)
        #expect(model.readiness == .needsAcknowledgement)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("b.yaml").path))
    }

    // MARK: - whitespace-only name

    @Test("a whitespace-only name is needsName, and never reaches the resolver")
    func whitespaceOnlyNameIsNeedsName() async throws {
        let root = try scratchDirectory()
        // Same negative-space technique as `emptyNameIsNeedsName`: a project
        // root that does not exist, so a failure to treat "   " as blank
        // would surface as `.blocked` (from the thrown
        // `.projectRootDoesNotExist`), not `.needsName`.
        let missingRoot = root.appendingPathComponent("does-not-exist", isDirectory: true)
        let keyStore = try makeKeyStore()
        let model = NewSecretFileModel(projectRoot: missingRoot, keyStore: keyStore)
        model.relativeName = "   "

        await model.resolvePlan()

        #expect(model.readiness == .needsName)
        #expect(model.plan == nil)
    }

    // MARK: - create() refuses a plan resolved for a different name

    @Test("create() refuses when relativeName has changed since plan was resolved for it")
    func createRefusesAStalePlan() async throws {
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

        // `relativeName` changes, but `resolvePlan()` is never called again
        // — simulating the debounce window `NewSecretFileSheet` (Task 4)
        // owns, where `readiness` can still say `.ready` for a name `plan`
        // was not actually resolved for.
        model.relativeName = "other.yaml"

        let created = await model.create()

        #expect(created == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other.yaml").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.yaml").path))
    }

    // MARK: - .needsRecipients: no .sops.yaml (Task 5's manual picker)

    /// Superseded by Task 5: `.noConfig` used to be `.blocked` with a fixed
    /// "this app cannot do this yet" sentence — see `NewSecretFileModel
    /// .noPickerYetMessage`'s own doc comment before it was removed. Now
    /// that `RecipientPicker` exists, it is `.needsRecipients`, not a
    /// failure — `RecipientPickerTests.swift` (Task 5's own test file)
    /// covers the manually-chosen path this state opens onto in full;
    /// this test only pins that `.noConfig` itself no longer reads as
    /// `.blocked`.
    @Test("no .sops.yaml is .needsRecipients, not .blocked — Task 5's manual recipient picker")
    func noConfigIsNeedsRecipients() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        #expect(model.plan == .noConfig)
        #expect(model.readiness == .needsRecipients)
        #expect(model.planError == nil)
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

    // MARK: - .blocked: a matched rule naming no recipients at all

    /// Review finding on Task 6, closed generally rather than only for the
    /// source that surfaced it: `CreationPlanResolverTests
    /// .ruleWithNoKeyGroupIsGovernedByRuleWithNoRecipients` measured, against
    /// the real bridge, that sops's own config loader admits a creation rule
    /// whose `path_regex` matches but names no key group at all —
    /// `.governedByRule(recipients: [], encryptedRegex: "")`, not a refusal.
    /// An earlier version of `currentGovernedPlan()` passed that empty list
    /// through as a real target, so `readiness` reported `.ready(recipients:
    /// [])` here — Create *enabled*, for a project whose own config names
    /// nobody to encrypt for. This is the general form of the finding;
    /// `EncryptedImportModelTests.ruleWithNoRecipientsReportsAwaitingPlanNotADiff`
    /// is the sharper instance the review actually traced (the same empty
    /// target reaching `EncryptedImportPreview`'s diff and naming every
    /// source recipient as losing access to a destination that, in truth,
    /// names nobody at all).
    @Test("a matched rule naming no recipients at all is blocked, not ready with an empty recipient list")
    func ruleWithNoRecipientsAtAllIsBlockedNotReady() async throws {
        // A configured session key, deliberately — this must fail on the
        // rule's own empty recipient list, not on the unrelated empty-key-store
        // check `readiness` already runs first for every source.
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"

        await model.resolvePlan()

        #expect(model.plan == .governedByRule(recipients: [], encryptedRegex: ""))
        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(message.detail.localizedCaseInsensitiveContains("no recipients"))

        // And create() must agree: nothing gets written for a plan this
        // model refuses to call a real target.
        let created = await model.create()
        #expect(created == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.yaml").path))
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
        let rows = try SopsBridge.decryptToRows(encrypted, format: .yaml, agePrivateKey: owner.private)
        #expect(rows.isEmpty)
        #expect(model.planError == nil)
    }

    // MARK: - .dotEnv source into a .json/.ini-named destination (SOPS-38 phase F2 task 5)
    //
    // Reachable through the real UI: `sourceChoice` and `relativeName` are
    // independent fields (`NewSecretFileSheet` lets a user set either in any
    // order), so picking a `.env` source and typing a `.json`/`.ini`-named
    // destination is an ordinary sequence, not a theoretical one. This is the
    // model-level proof that `SecretFileCreator.Failure
    // .dotEnvSourceIncompatibleWithFormat` — already proven directly against
    // `SecretFileCreator.create` in `SecretFileCreatorTests` — surfaces as an
    // ordinary `.blocked` readiness through this model's existing, generic
    // `SecretFileCreator.Failure` handling in `create()`: no model code
    // needed to change for this refusal to reach the wizard.

    @Test("a .env source into a .json-named destination is blocked, and nothing is written")
    func dotEnvSourceIntoJSONTargetIsBlocked() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        // A broad rule (matches any relative path) so the plan resolves
        // .governedByRule for a `.json` name too — `ageOnlyConfig`'s own
        // `.*\.yaml$` rule would not match here, and this test needs to
        // reach `create()`'s guard, not `.needsRecipients`.
        try """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)
            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.json"
        await model.resolvePlan()

        model.sourceChoice = .dotEnv
        let source = root.appendingPathComponent("source.env")
        try "API_KEY=hunter2\n".write(to: source, atomically: true, encoding: .utf8)
        model.loadDotEnv(from: source)

        let created = await model.create()

        #expect(created == nil)
        guard case .blocked(let message) = model.readiness else {
            Issue.record("expected .blocked, got \(model.readiness)")
            return
        }
        #expect(message.detail.localizedCaseInsensitiveContains("json"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("secret.json").path))
    }

    // MARK: - forgetLastCreateFailure() actually drops retained content, Mirror-proven
    //
    // Task 6's review checked, rather than assumed, that `loadPlainYAML(
    // from:)`/`loadDotEnv(from:)` calling `forgetLastCreateFailure()` was
    // real coverage for the identical call `chooseEncryptedFile(at:)` gained
    // — and found the opposite: `grep` over this whole test target returns
    // zero references to `lastCreateFailure`, so nothing here had ever
    // actually exercised what these two calls guard against. These two
    // tests are that missing coverage, mirroring
    // `EncryptedImportPreviewTests
    // .pickingADifferentFileAfterARefusedCreateDropsThePreviousPlaintext`'s
    // own technique and reasoning — see that test's own doc comment for why
    // a `Mirror` sweep, not a behavioural assertion, is the only proof that
    // means anything here.

    @Test("picking a different Plain YAML source after a refused create() does not retain the previous file's content")
    func pickingADifferentPlainYAMLSourceAfterARefusedCreateDropsThePreviousContent() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        // Destination already exists — `create()` refuses at step 2,
        // deterministically, regardless of what A's content is.
        let destination = root.appendingPathComponent("secret.yaml")
        try "already here\n".write(to: destination, atomically: true, encoding: .utf8)

        let sentinel = "correct-horse-battery-staple"
        model.sourceChoice = .plainYAML
        let fileA = root.appendingPathComponent("a.yaml")
        try "password: \(sentinel)\n".write(to: fileA, atomically: true, encoding: .utf8)
        model.loadPlainYAML(from: fileA)

        let created = await model.create()
        #expect(created == nil)
        guard case .blocked = model.readiness else {
            Issue.record("expected .blocked (destinationExists) — this test would be vacuous")
            return
        }

        let fileB = root.appendingPathComponent("b.yaml")
        try "other: value\n".write(to: fileB, atomically: true, encoding: .utf8)
        model.loadPlainYAML(from: fileB)

        // Positive control: proves the sweep actually sees the model's live
        // storage (`plainYAMLText`, now B's) before trusting it to prove
        // anything about A's *absence* — a sweep that saw nothing would pass
        // the leak assertion below for the wrong reason.
        #expect(modelRetains("other: value", model),
                "positive control failed — Mirror did not see B's own current content, so this test proves nothing")
        #expect(!modelRetains(sentinel, model),
                "the model still retains A's content, reachable via Mirror, after B was loaded")
    }

    @Test("picking a different .env source after a refused create() does not retain the previous file's content")
    func pickingADifferentDotEnvSourceAfterARefusedCreateDropsThePreviousContent() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        let destination = root.appendingPathComponent("secret.yaml")
        try "already here\n".write(to: destination, atomically: true, encoding: .utf8)

        let sentinel = "correct-horse-battery-staple"
        model.sourceChoice = .dotEnv
        let fileA = root.appendingPathComponent("a.env")
        try "PASSWORD=\(sentinel)\n".write(to: fileA, atomically: true, encoding: .utf8)
        model.loadDotEnv(from: fileA)

        let created = await model.create()
        #expect(created == nil)
        guard case .blocked = model.readiness else {
            Issue.record("expected .blocked (destinationExists) — this test would be vacuous")
            return
        }

        // A distinct-enough value that it cannot coincidentally already be
        // present elsewhere in the model — `DotEnvParser` splits `KEY=value`
        // into separate `key`/`value` strings, so "OTHER=…" itself would
        // never appear as one contiguous string; the positive control below
        // has to search for the *value* alone.
        let fileB = root.appendingPathComponent("b.env")
        try "OTHER=OTHERVALUE123\n".write(to: fileB, atomically: true, encoding: .utf8)
        model.loadDotEnv(from: fileB)

        // Positive control — see the Plain YAML sibling test's own comment.
        #expect(modelRetains("OTHERVALUE123", model),
                "positive control failed — Mirror did not see B's own current content, so this test proves nothing")
        #expect(!modelRetains(sentinel, model),
                "the model still retains A's content, reachable via Mirror, after B was loaded")
    }

    // MARK: - SOPS-30: loadPlainYAML/loadDotEnv crossed the C boundary unguarded
    //
    // Ticket #30. Same `withGoString` truncation mechanism
    // `unlockChosenEncryptedFile()` was fixed for in merge `88e187c`: a raw
    // NUL is valid UTF-8, so it survives `Data(contentsOf:)` and a
    // `String(data:encoding:.utf8)` decode intact, then silently ends the
    // argument at the Go bridge's C boundary. Here that means a *new* file
    // is missing everything the user thought they imported after the NUL,
    // rather than an existing document's second half being destroyed.

    /// A raw NUL midway through a Plain YAML source. Before the fix,
    /// `loadPlainYAML(from:)` stored the whole string (NUL and all) as
    /// `plainYAMLText`, `create()` handed it straight to
    /// `SopsBridge.encryptYAML`, which truncated at the NUL, and
    /// `SecretFileCreator.verifyRoundTrip`'s `.verbatimYAML` branch does not
    /// count rows — it only refuses a *non-empty* source coming back with
    /// *zero* rows (see that method's own doc comment, "not a row count
    /// comparison"). One surviving row is enough to pass, so `create()`
    /// silently succeeded, and the written file was missing `beta` with no
    /// error anywhere.
    @Test("a Plain YAML source carrying a NUL byte is refused, not silently truncated on create")
    func nulBearingPlainYAMLSourceIsRefused() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        model.sourceChoice = .plainYAML
        let source = root.appendingPathComponent("source.yaml")
        try "alpha: one\n\u{0}beta: two\n".write(to: source, atomically: true, encoding: .utf8)
        model.loadPlainYAML(from: source)

        guard let error = model.plainYAMLLoadError else {
            let retained = String(describing: model.plainYAMLText)
            let message: String = "expected a NUL byte in the Plain YAML source to be refused at "
                + "load time, but plainYAMLLoadError is nil — plainYAMLText was set to \(retained)"
            Issue.record("\(message)")
            return
        }
        #expect(error.detail.contains("NUL"), "the refusal does not say what is wrong: \(error.detail)")
        #expect(model.plainYAMLText == nil, "a refused load must not retain a truncated document")

        // The consequence the guard exists to prevent, proven end to end:
        // without the guard above, `create()` would report success and the
        // written file would silently be missing `beta`.
        let created = await model.create()
        #expect(created == nil, "create() must not proceed from a refused Plain YAML load")
    }

    /// The `.dotEnv` sibling of the test above — same ticket, same claimed
    /// mechanism, but investigating it turned up a different reality than
    /// `.plainYAML`'s: `loadDotEnv(from:)` never hands raw file text to the
    /// bridge at all, only `DotEnvParser.parse`'s structured `entries`, and
    /// `create()` re-serialises those through `FlatYAMLEmitter.emit`, whose
    /// `quotedValue` escapes every C0 control character — including NUL —
    /// as a literal `\x00` before anything reaches `SopsBridge.encryptYAML`
    /// (see that method's own doc comment table). Measured directly, before
    /// `loadDotEnv(from:)` had any guard at all: a `.env` value containing a
    /// raw NUL parsed into two entries and round-tripped through `create()`
    /// with both rows intact — the silent-truncation failure this ticket
    /// describes for `.plainYAML` does not reach `.dotEnv` through this
    /// path. That is the "reproduction failed to reproduce" outcome the
    /// house rule anticipates as a legitimate result in its own right, not
    /// a reason to skip the guard here — `loadDotEnv(from:)` now refuses a
    /// NUL byte on the same raw bytes `.plainYAML` does, purely so this
    /// boundary is checked consistently everywhere a source file is read,
    /// not because this test found a live defect.
    @Test("a .env source carrying a NUL byte is refused at load time, as defense-in-depth — FlatYAMLEmitter already escapes it before the C boundary")
    func nulBearingDotEnvSourceIsRefused() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try scratchDirectory()
        try ageOnlyConfig(owner.public)
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let keyStore = try makeKeyStore(importing: owner.private)
        let model = NewSecretFileModel(projectRoot: root, keyStore: keyStore)
        model.relativeName = "secret.yaml"
        await model.resolvePlan()

        model.sourceChoice = .dotEnv
        let source = root.appendingPathComponent("source.env")
        try "ALPHA=one\u{0}two\nBETA=three\n".write(to: source, atomically: true, encoding: .utf8)
        model.loadDotEnv(from: source)

        guard let error = model.dotEnvLoadError else {
            let retained = String(describing: model.dotEnvParsed)
            let message: String = "expected a NUL byte in the .env source to be refused at load "
                + "time, but dotEnvLoadError is nil — dotEnvParsed was set to \(retained)"
            Issue.record("\(message)")
            return
        }
        #expect(error.detail.contains("NUL"), "the refusal does not say what is wrong: \(error.detail)")
        #expect(model.dotEnvParsed == nil, "a refused load must not retain a partially-parsed document")

        let created = await model.create()
        #expect(created == nil, "create() must not proceed from a refused .env load")
    }
}
