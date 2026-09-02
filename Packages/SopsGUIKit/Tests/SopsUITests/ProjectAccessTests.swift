import Foundation
import ScratchCleanup
import SopsEngine
import SopsHealth
import SopsProjects
import SwiftUI
import Testing

@testable import SopsUI

// MARK: - Fixture plumbing
//
// Encrypted fixtures go through the real in-process bridge, never a
// hand-written string — the discipline Task 1 established for this surface and
// Task 3's `RecipientAccessTests` follows. Only key generation shells out.

private struct ProjectFixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

private func projectToolPath(_ name: String) throws -> String {
    let candidates = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        .map { ($0 as NSString).appendingPathComponent(name) }
    guard let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
        throw ProjectFixtureError("\(name) not found in \(candidates)")
    }
    return found
}

private struct ProjectAgeKeyPair {
    let `private`: String
    let `public`: String

    static func generate() throws -> ProjectAgeKeyPair {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try projectToolPath("age-keygen"))
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var priv = "", pub = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("AGE-SECRET-KEY-") {
                priv = String(line)
            } else if line.hasPrefix("# public key: ") {
                pub = String(line.dropFirst("# public key: ".count))
            }
        }
        guard !priv.isEmpty, !pub.isEmpty else {
            throw ProjectFixtureError("age-keygen produced no usable key pair")
        }
        return ProjectAgeKeyPair(private: priv, public: pub)
    }
}

private func projectScratchDirectory(_ label: String = "project-access") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let projectPlainYAML = "database:\n    password: correct-horse-battery-staple\n"

/// A project root with a flat, age-only `.sops.yaml` and two encrypted files
/// under it. Returns the root and the config's exact text.
@discardableResult
private func makeProject(owner: ProjectAgeKeyPair) throws -> (root: URL, config: String) {
    let root = try projectScratchDirectory()
    let config = """
        # Team configuration
        creation_rules:
          - path_regex: .*\\.yaml$
            age:
              - \(owner.public)

        """
    try config.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
    let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
    for name in ["a.yaml", "b.yaml"] {
        try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    return (root, config)
}

@Suite("ProjectAccessModel — staged edits never touch disk")
@MainActor
struct ProjectAccessStagingTests {

    @Test("loading seeds the staged set from the creation rule and touches nothing")
    func loadSeedsFromTheConfig() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, config) = try makeProject(owner: owner)
        let before = try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.loadState == .loaded)
        #expect(model.configRecipients == [owner.public])
        #expect(model.stagedRecipients == [owner.public])
        #expect(!model.isDirty)
        #expect(model.filesToApply.count == 2)
        #expect(model.plan?.configRefusal == nil)
        #expect(model.plan?.configNeedsWriting == false)

        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)
        #expect(try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8) == before)
    }

    @Test("staging an addition and a removal writes nothing at all")
    func stagingIsInMemoryOnly() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, config) = try makeProject(owner: owner)
        let before = try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        model.stageAdd(added.public)
        model.stageRemove(owner.public)
        await model.refreshPlan()

        #expect(model.stagedRecipients == [added.public])
        #expect(model.isDirty)
        #expect(model.pendingRemovals.map(\.ageRecipient) == [owner.public])
        #expect(model.entries.first { $0.ageRecipient == added.public }?.status == .pendingAddition)

        // The plan now proposes a config change — but only proposes it.
        #expect(model.plan?.configNeedsWriting == true)
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)
        #expect(try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8) == before)
    }

    @Test("a recipient the registry has never heard of is still shown, by its public key")
    func unlabelledRecipientsAreNeverHidden() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        let entry = try #require(model.entries.first)
        #expect(entry.ageRecipient == owner.public)
        #expect(entry.label == nil)
    }

    @Test("a registry label is attached to the matching public key")
    func registryLabelsAreAttached() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Alice's laptop", kind: .device, ageRecipient: owner.public),
            in: root)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.entries.first?.label == "Alice's laptop")
    }

    /// #27 item 5: the default `loadRegistry` is now `RecipientRegistry
    /// .loadOrQuarantine(in:)`, not a bare `(try? load) ?? []` — this proves
    /// that wiring end to end, through the model's real default, not an
    /// injected seam.
    @Test("a corrupt registry surfaces a quarantine notice, and recipients still show unlabelled")
    func corruptRegistrySurfacesAQuarantineNotice() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        let registryDirectory = root.appendingPathComponent(".sops-gui", isDirectory: true)
        try FileManager.default.createDirectory(at: registryDirectory, withIntermediateDirectories: true)
        try Data(#"{"records": "not an array"}"#.utf8)
            .write(to: registryDirectory.appendingPathComponent("recipients.json"))

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.registryQuarantineNotice != nil)
        // Labels are unavailable, but the recipient itself is not hidden —
        // exactly the same degrade `unlabelledRecipientsAreNeverHidden`
        // pins for a registry that was simply never created.
        #expect(model.entries.first?.ageRecipient == owner.public)
        #expect(model.entries.first?.label == nil)
        // The corrupt file no longer sits at the path a future save would
        // have to fight the fingerprint of.
        #expect(!FileManager.default.fileExists(
            atPath: registryDirectory.appendingPathComponent("recipients.json").path))
    }

    @Test("discarding staged changes returns to what the config declares")
    func discardRestoresTheBaseline() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let stranger = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        model.stageAdd(stranger.public)
        model.stageRemove(owner.public)
        #expect(model.isDirty)

        model.discardStagedChanges()
        #expect(!model.isDirty)
        #expect(model.stagedRecipients == model.configRecipients)
    }

    @Test("adding what is already staged is refused as a duplicate")
    func duplicateStagedRecipientIsRefused() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.stageAdd(owner.public) == .duplicate)
        #expect(model.stageAdd("   ") == .empty)
    }
}

@Suite("ProjectAccessModel — the config and the files are two separate applies")
@MainActor
struct ProjectAccessApplySeparationTests {

    @Test("updating .sops.yaml never re-wraps a single file")
    func configApplyLeavesFilesAlone() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        let fileBytes = try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        #expect(await model.applyConfig() == .written)

        // The config changed...
        let config = try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(config.contains(added.public))
        #expect(config.contains("# Team configuration"))
        // ...and not one file did.
        for name in ["a.yaml", "b.yaml"] {
            let bytes = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(bytes == fileBytes)
            #expect(try SopsBridge.recipients(in: bytes, format: .yaml) == [owner.public])
        }
    }

    @Test("re-wrapping the files never rewrites .sops.yaml")
    func fileApplyLeavesTheConfigAlone() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, config) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        #expect(await model.applyToFiles() == nil)

        #expect(model.fileResults.count == 2)
        #expect(model.fileResults.allSatisfy { $0.outcome == .updated })
        for name in ["a.yaml", "b.yaml"] {
            let bytes = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(Set(try SopsBridge.recipients(in: bytes, format: .yaml)) == Set([owner.public, added.public]))
            #expect(try SopsBridge.decrypt(bytes, format: .yaml, agePrivateKey: added.private) == projectPlainYAML)
        }
        // The config is byte-identical: it was never part of this action.
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)
    }

    @Test("re-wrapping files after staging a removal records rotation debt for the files actually rewrapped")
    func fileApplyRecordsRotationDebtForRemovedRecipient() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let removed = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        let config = """
            creation_rules:
              - path_regex: .*\\.yaml$
                age:
                  - \(owner.public)
                  - \(removed.public)
            """
        try config.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(
            projectPlainYAML, format: .yaml, recipients: [owner.public, removed.public])
        for name in ["a.yaml", "b.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageRemove(removed.public)
        await model.refreshPlan()

        #expect(await model.applyToFiles() == nil)
        #expect(model.fileResults.allSatisfy { $0.outcome == .updated })

        let debt = try RotationDebtLedger.load(in: root)
        #expect(Set(debt.map(\.path)) == ["a.yaml", "b.yaml"])
        #expect(debt.allSatisfy { $0.reason == .recipientRemoved })
    }

    @Test("re-wrapping files without staging any removal records no rotation debt")
    func fileApplyWithoutRemovalRecordsNoRotationDebt() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        #expect(await model.applyToFiles() == nil)

        #expect(try RotationDebtLedger.load(in: root).isEmpty)
    }

    /// SOPS-38 phase F2 task 5: `ProjectAccessModel`/`RecipientAccessModel`
    /// and `ProjectRecipientApplier` beneath it have been format-generic
    /// since F1 — they iterate `plan.filesInScope` by each file's own
    /// `ScopedFile.format`, never assuming YAML — so this is a regression
    /// test, not new plumbing: nothing in either type changed for this test
    /// to pass. It proves the claim at the layer a user actually drives
    /// (stage a recipient, `applyToFiles()`), covering all four sops
    /// formats this app supports in one project, mirroring
    /// `ProjectRecipientApplierTests.mixedProjectRewrapsAllFourFormats`
    /// (`SopsProjectsTests`) one layer up, through the real UI model instead
    /// of the applier directly.
    @Test("re-wrapping a project with all four sops formats re-wraps every file, decryptable by the newly added recipient")
    func fileApplyRewrapsAllFourFormats() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()

        try """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let yamlEncrypted = try SopsBridge.encrypt(
            projectPlainYAML, format: .yaml, recipients: [owner.public])
        try yamlEncrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let dotenvEncrypted = try SopsBridge.encrypt(
            "DB_PASSWORD=hunter2\n", format: .dotenv, recipients: [owner.public])
        try dotenvEncrypted.write(
            to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        // Genuine JSON/INI syntax — each format's own store parser reads
        // this on encrypt, not a YAML parser (see
        // `ProjectRecipientApplierTests.mixedProjectRewrapsAllFourFormats`'s
        // own comment for the measured reason this matters).
        let jsonEncrypted = try SopsBridge.encrypt(
            "{\"api_key\": \"json-secret-value\"}\n", format: .json, recipients: [owner.public])
        try jsonEncrypted.write(
            to: root.appendingPathComponent("secret.json"), atomically: true, encoding: .utf8)

        let iniEncrypted = try SopsBridge.encrypt(
            "[db]\npassword = ini-secret-value\n", format: .ini, recipients: [owner.public])
        try iniEncrypted.write(
            to: root.appendingPathComponent("secret.ini"), atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        #expect(model.plan?.filesInScope.count == 4)
        #expect(Set(model.plan?.filesInScope.map(\.format) ?? []) == Set([.yaml, .dotenv, .json, .ini]))

        #expect(await model.applyToFiles() == nil)

        #expect(model.fileResults.count == 4)
        #expect(model.fileResults.allSatisfy { $0.outcome == .updated })

        let yamlBytes = try String(contentsOf: root.appendingPathComponent("secret.yaml"), encoding: .utf8)
        #expect(Set(try SopsBridge.recipients(in: yamlBytes, format: .yaml)) == Set([owner.public, added.public]))
        #expect(try SopsBridge.decrypt(yamlBytes, format: .yaml, agePrivateKey: added.private) == projectPlainYAML)

        let dotenvBytes = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
        #expect(Set(try SopsBridge.recipients(in: dotenvBytes, format: .dotenv)) == Set([owner.public, added.public]))
        #expect(
            try SopsBridge.decrypt(dotenvBytes, format: .dotenv, agePrivateKey: added.private)
                == "DB_PASSWORD=hunter2\n")

        let jsonBytes = try String(contentsOf: root.appendingPathComponent("secret.json"), encoding: .utf8)
        #expect(Set(try SopsBridge.recipients(in: jsonBytes, format: .json)) == Set([owner.public, added.public]))
        let jsonRows = try SopsBridge.decryptToRows(jsonBytes, format: .json, agePrivateKey: added.private)
        #expect(jsonRows.first { $0.path == ["api_key"] }?.value == "json-secret-value")

        let iniBytes = try String(contentsOf: root.appendingPathComponent("secret.ini"), encoding: .utf8)
        #expect(Set(try SopsBridge.recipients(in: iniBytes, format: .ini)) == Set([owner.public, added.public]))
        let iniRows = try SopsBridge.decryptToRows(iniBytes, format: .ini, agePrivateKey: added.private)
        #expect(iniRows.first { $0.path == ["db", "password"] }?.value == "ini-secret-value")
    }

    @Test("applying to files without a session key is refused before anything is read")
    func fileApplyWithoutAKeyIsRefused() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        let before = try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()
        model.stageAdd(added.public)

        #expect(await model.applyToFiles() == .noKey)
        #expect(model.fileResults.isEmpty)
        #expect(try String(contentsOf: root.appendingPathComponent("a.yaml"), encoding: .utf8) == before)
    }

    @Test("staging away every recipient is refused by both applies")
    func emptyRecipientSetIsRefused() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, config) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageRemove(owner.public)
        #expect(model.stagedRecipients.isEmpty)

        #expect(await model.applyConfig() == .refusedEmptyRecipients)
        #expect(await model.applyToFiles() == .emptyRecipients)
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)
    }

    @Test("a config shape this app will not rewrite is explained, and both applies leave it alone")
    func unsupportedConfigShapeIsExplained() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        let config = """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)
                pgp: 0000000000000000000000000000000000AAAA

            """
        try config.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("a.yaml"), atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        let refusal = try #require(model.plan?.configRefusal)
        #expect(refusal.contains("pgp"))
        #expect(model.plan?.configNeedsWriting == false)
        #expect(await model.applyConfig() == .nothingToWrite)
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)

        // The files can still be re-wrapped: that is an explicit act on the
        // files themselves and has nothing to do with the config's shape.
        #expect(await model.applyToFiles() == nil)
        #expect(model.fileResults.map(\.outcome) == [.updated])
    }

    @Test("one unreadable file is reported and the rest of the project still gets applied")
    func oneBadFileDoesNotStopTheProjectRun() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, config) = try makeProject(owner: owner)

        // Enough of a `sops:` block for the scanner's tail sniff to call it
        // encrypted (`SopsMetadataShape.isYAMLMetadata` wants both `mac:` and
        // `version:`), and nothing sops itself can actually load — the exact
        // file a project run has to survive rather than stop at.
        let broken = root.appendingPathComponent("c-broken.yaml")
        try """
            still-encrypted: no
            sops:
                mac: ENC[AES256_GCM,data:bm90aGluZw==,type:str]
                version: 3.13.3

            """.write(to: broken, atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)

        #expect(await model.applyToFiles() == nil)
        #expect(model.fileResults.count == 3)
        #expect(model.fileResults.filter { $0.outcome == .updated }.count == 2)
        #expect(model.fileResults.filter {
            if case .failed = $0.outcome { true } else { false }
        }.count == 1)
        // And the config never moved.
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)
    }
}

// MARK: - F1: a run requested while one is still finishing is queued, not dropped

/// Blocks the first call it receives until `open()` is called; every later
/// call passes straight through. Backed by a lock and a `DispatchSemaphore`
/// rather than an actor because it is called from `ProjectRecipientApplier`'s
/// synchronous `rewrapRecipients` seam, which cannot `await` — the same
/// reasoning `ProjectRecipientApplierCancellationTests`' semaphore gate uses.
private final class FirstCallGate: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var arrivedFlag = false
    private let release = DispatchSemaphore(value: 0)

    func waitIfFirst() {
        lock.lock()
        callCount += 1
        let isFirst = callCount == 1
        if isFirst { arrivedFlag = true }
        lock.unlock()
        if isFirst { release.wait() }
    }

    func hasArrived() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return arrivedFlag
    }

    func open() { release.signal() }
}

@Suite("ProjectAccessModel — a run requested while one is still finishing is queued, not dropped")
@MainActor
struct ProjectAccessQueuedRunTests {

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("condition was never met within 10s")
    }

    /// F1. The pre-fix `startApplyingToFiles` cancelled the previous `Task`
    /// without awaiting it, so a second call landing while the first was
    /// still finishing its in-flight file reached `applyToFiles()`'s
    /// `isApplyingFiles` guard while it was still `true` and was refused on
    /// the spot — silently, since that refusal was folded into the same
    /// `nil` a real start returns, so `onRefusal` never fired for it either.
    ///
    /// This proves the fix rather than merely the symptom: the two calls are
    /// staged for *different* recipient sets, so only if the second call
    /// truly runs — after the first `Task` has actually finished — do the
    /// files end up re-wrapped for the second set. A silently dropped second
    /// call would leave the files at the first set instead, which is exactly
    /// what this failed to catch before the fix.
    @Test("a second call queued behind an in-flight run still re-wraps for what was staged by the time it starts")
    func aQueuedRunStillHappens() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let addedFirst = try ProjectAgeKeyPair.generate()
        let addedSecond = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)

        let gate = FirstCallGate()
        let applier = ProjectRecipientApplier(rewrapRecipients: { contents, format, recipients, key in
            gate.waitIfFirst()
            return try SopsBridge.updateRecipients(contents, format: format, to: recipients, agePrivateKey: key)
        })
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore, applier: applier)
        await model.load()

        model.stageAdd(addedFirst.public)
        await model.refreshPlan()

        var refusals: [ProjectAccessModel.FileApplyRefusal] = []
        model.startApplyingToFiles { refusals.append($0) }

        await waitUntil { gate.hasArrived() }
        try #require(gate.hasArrived(), "the first run never reached the blocked file")
        #expect(model.isApplyingFiles, "precondition: the first run is genuinely still going")

        // Restage while the first run is stuck mid-file, and ask for another
        // run — the exact shape the finding describes: a second request
        // landing while the first is still finishing.
        model.stageRemove(addedFirst.public)
        model.stageAdd(addedSecond.public)
        await model.refreshPlan()
        model.startApplyingToFiles { refusals.append($0) }

        // Let the first run's blocked file proceed; both its files finish
        // with the first set.
        gate.open()
        await waitUntil { !model.isApplyingFiles }

        // The queued second call must now run to completion on its own,
        // re-wrapping both files for the second set — proof it was not
        // dropped. Waited on both names, not just one: the first run's own
        // cancellation (requested while it was stuck on the gate) can leave
        // it having reached only the first file before the second run picks
        // up the rest, so the two files do not necessarily converge at the
        // same instant.
        await waitUntil {
            ["a.yaml", "b.yaml"].allSatisfy { name in
                (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8))
                    .flatMap { try? SopsBridge.recipients(in: $0, format: .yaml) }
                    .map { Set($0) == Set([owner.public, addedSecond.public]) } ?? false
            }
        }

        for name in ["a.yaml", "b.yaml"] {
            let bytes = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            #expect(Set(try SopsBridge.recipients(in: bytes, format: .yaml)) == Set([owner.public, addedSecond.public]),
                    "\(name) must end up re-wrapped for the set staged by the time the queued run actually started")
        }
        #expect(refusals.isEmpty,
                "neither call should have been refused — the second must run, not vanish as a dropped \"already running\"")
    }

    /// The half of F1 that is a pure function: `applyToFiles()` itself now
    /// tells "already running" apart from "just started", for a caller that
    /// bypasses `startApplyingToFiles` and calls it directly while a run it
    /// started earlier is still going.
    @Test("calling applyToFiles() directly while one is already running is refused, not silently nil")
    func directReentrantCallIsRefused() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)

        let gate = FirstCallGate()
        let applier = ProjectRecipientApplier(rewrapRecipients: { contents, format, recipients, key in
            gate.waitIfFirst()
            return try SopsBridge.updateRecipients(contents, format: format, to: recipients, agePrivateKey: key)
        })
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore, applier: applier)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        let firstRun = Task { await model.applyToFiles() }
        await waitUntil { gate.hasArrived() }
        try #require(model.isApplyingFiles)

        #expect(await model.applyToFiles() == .alreadyRunning)

        gate.open()
        #expect(await firstRun.value == nil)
    }
}

// MARK: - Ticket #24 claims 2 and 3: a durable trace of what a project-wide run did

@Suite("ProjectAccessModel — every apply run leaves a durable trace")
@MainActor
struct ProjectAccessRunRecordTests {

    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("condition was never met within 10s")
    }

    @Test("a completed run is persisted and carries no cancellation")
    func completedRunIsPersisted() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        #expect(await model.applyToFiles() == nil)

        let record = try #require(try RunRecordStore.load(in: root))
        #expect(!record.wasCancelled)
        #expect(Set(record.results.map(\.path)) == Set(["a.yaml", "b.yaml"]))
        #expect(record.results.allSatisfy { $0.outcome == .updated })
        #expect(Set(record.recipients) == Set([owner.public, added.public]))
        #expect(model.previousIncompleteRun == nil,
                "a run that finished must not be reported as an incomplete previous run")
    }

    @Test("a cancelled run's not-attempted files survive the panel closing")
    func cancelledRunIsPersistedWithNotAttempted() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory("project-access-run-record-cancel")
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age:
                  - \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
        for name in ["a.yaml", "b.yaml", "c.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let gate = FirstCallGate()
        let applier = ProjectRecipientApplier(rewrapRecipients: { contents, format, recipients, key in
            gate.waitIfFirst()
            return try SopsBridge.updateRecipients(contents, format: format, to: recipients, agePrivateKey: key)
        })
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore, applier: applier)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        model.startApplyingToFiles { _ in }
        await waitUntil { gate.hasArrived() }
        try #require(model.isApplyingFiles)

        model.cancelRun()
        gate.open()
        await waitUntil { !model.isApplyingFiles }

        let record = try #require(try RunRecordStore.load(in: root))
        #expect(record.wasCancelled)
        #expect(!record.notAttempted.isEmpty)
        #expect(model.previousIncompleteRun == record,
                "the model's own live state must agree with what was just persisted")
    }

    @Test("a fresh load surfaces a previous session's cancelled run")
    func loadSurfacesAPriorIncompleteRun() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        let stale = RunRecord(
            startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
            recipients: [owner.public],
            results: [RunRecord.FileEntry(path: "a.yaml", outcome: .updated)],
            notAttempted: ["b.yaml"])
        try RunRecordStore.save(stale, in: root)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.previousIncompleteRun == stale)
    }

    @Test("a fresh load says nothing about a previous run that completed")
    func loadIgnoresACompletedPriorRun() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        let completed = RunRecord(
            startedAt: Date(timeIntervalSince1970: 1), finishedAt: Date(timeIntervalSince1970: 2),
            recipients: [owner.public],
            results: [RunRecord.FileEntry(path: "a.yaml", outcome: .updated)],
            notAttempted: [])
        try RunRecordStore.save(completed, in: root)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.previousIncompleteRun == nil)
    }

    // The incomplete-run banner had a render test through
    // `ProjectAccessView`. SOPS-39 task 10 retired that panel, and the Access
    // page that replaced it does not draw `previousIncompleteRun` at all: a
    // project-wide run now goes through `RewrapCoordinator`/`RewrapSheet`,
    // which reports its own results and never resumes a previous session's.
    // The model half above still pins that the record survives and is read
    // back; nothing renders it today. Recorded rather than quietly dropped.

    /// SOPS-33. `RegistryQuarantineWiringTests` already pins that this
    /// model's `load()` routes through `loadOrQuarantine(in:)` and stores
    /// whatever it returns; this is the other half — that a notice actually
    /// reaches the screen, through the real `RegistryQuarantineBanner`
    /// wired into `ProjectAccessPage`, not just the model. Ported from
    /// `ProjectAccessView` in SOPS-39 task 10 — and the page had to grow the
    /// banner to receive it, because the panel it replaced was the only
    /// project-wide surface that ever showed one.
    @Test("the page actually shows the registry-quarantine banner when the registry was moved aside")
    func thePageRendersTheRegistryQuarantineBanner() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        let notice = "Your recipient names at /fixture/.sops-gui/recipients.json could not be read, " +
            "so the file has been moved aside to /fixture/.sops-gui/recipients-corrupt-x.json."

        let model = ProjectAccessModel(
            projectRoot: root, keyStore: SessionKeyStore(),
            loadRegistry: { _ in ([], notice) })
        await model.load()

        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: nil, onFilesApplied: {})
        }
        let seen = nodes.flatMap { [$0.label, $0.value] }
        #expect(seen.contains(LocalizedKey.accessRegistryQuarantineTitle.text),
                "the page must show the registry-quarantine banner's title")
        #expect(seen.contains(notice),
                "the page must show the notice text itself, not just the title")
    }

    /// The negative case: an ordinary load (`quarantineNotice == nil`, the
    /// default seam) must render nothing extra. Without this, a banner that
    /// renders unconditionally would still pass the positive test above.
    @Test("an ordinary load shows no registry-quarantine banner")
    func ordinaryLoadShowsNoRegistryQuarantineBanner() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        try #require(model.registryQuarantineNotice == nil, "precondition: nothing was quarantined")
        let nodes = AXProbe.tree(size: CGSize(width: 1000, height: 900)) {
            ProjectAccessPage(model: model, selectedFile: nil, onFilesApplied: {})
        }
        #expect(
            !nodes.flatMap { [$0.label, $0.value] }
                .contains(LocalizedKey.accessRegistryQuarantineTitle.text),
            "an ordinary load must not show the registry-quarantine banner")
    }
}

/// SOPS-39 task 10 retired `ProjectAccessView` and with it three gates:
/// `ProjectAccessGate.canOpen` (there is no "Project Access" button any more
/// — Access is a sidebar destination, and the unsaved-work question it asked
/// is now `WorkspaceSwitchGate.decision`'s), and the two static button gates
/// `canUpdateConfig`/`canApplyToFiles`. The page's own header button is gated
/// on `model.isDirty`, and a project-wide re-wrap runs through
/// `RewrapCoordinator`, which asks the model directly.
///
/// What survives the move is the one thing a caller cannot re-derive: every
/// refusal `applyToFiles()` can return has a sentence to show for it. That
/// moved onto the refusal itself, because `RewrapCoordinator` — not a view —
/// is what names a skipped rule now.
@Suite("Every file-apply refusal can say what it is")
struct FileApplyRefusalExplanationTests {

    @Test("every file-apply refusal has an explanation to show")
    func everyRefusalIsExplained() {
        for refusal: ProjectAccessModel.FileApplyRefusal in [
            .notLoaded, .emptyRecipients, .noFiles, .noKey, .alreadyRunning,
            .widenedScopeNotAcknowledged,
        ] {
            #expect(!refusal.explanation.isEmpty)
        }
    }
}

@Suite("ProjectAccessModel — a project it could not look inside is never reported as empty")
@MainActor
struct ProjectAccessUnreadableRootTests {

    @Test("a project folder that is gone is said to be gone, not said to hold no files")
    func missingRootIsStated() async throws {
        let root = try projectScratchDirectory()
        try FileManager.default.removeItem(at: root)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("expected a missing project root to fail the load, got \(model.loadState)")
            return
        }
        #expect(message == LocalizedKey.projectAccessRootMissing.text)
        #expect(model.plan == nil)
        #expect(model.filesToApply.isEmpty)
    }

    @Test("a project folder this process cannot read is said to be unreadable")
    func unreadableRootIsStated() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        }

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        guard case .failed(let message) = model.loadState else {
            Issue.record("expected an unreadable project root to fail the load, got \(model.loadState)")
            return
        }
        #expect(message == LocalizedKey.projectAccessRootUnreadable.text)
        #expect(model.plan == nil)
    }
}

@Suite("ProjectAccessModel — a config that governs nothing still leaves files applicable")
@MainActor
struct ProjectAccessScopeFallbackTests {

    @Test("a creation rule that matches none of the files still leaves every file in scope")
    func rulelessProjectStillHasFilesInScope() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        try """
            creation_rules:
              - path_regex: nothing-here/.*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()

        #expect(model.plan?.governingRuleIdentified == false)
        #expect(model.plan?.configRefusal?.contains("creation rule") == true)
        // The point: nothing was worked out about the rule, which must not be
        // read as "the rule covers no files" and quietly apply to nothing.
        #expect(model.filesToApply.map { $0.url.lastPathComponent } == ["secret.yaml"])

        model.stageAdd(added.public)
        #expect(await model.applyToFiles() == nil)
        #expect(model.fileResults.map(\.outcome) == [.updated])
    }

    @Test("a project with no config at all still has every encrypted file in scope")
    func configlessProjectStillHasFilesInScope() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
        for name in ["a.yaml", "b.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.plan?.configExists == false)
        #expect(model.filesToApply.count == 2)
    }
}

// SOPS-39 task 10. Two suites lived here and are gone with the panel they
// rendered:
//
//   * `ProjectAccessScopeDisclosureTests` — "N of M files", the all-files
//     fallback count and the unmatched note. The Access page is organised by
//     creation rule and states scope per rule (`accessRulesEncryptedForOf`,
//     `AccessRuleCard`'s governed-file list), so there is no single
//     panel-wide scope sentence left to assert.
//   * `ProjectAccessCollapsedDuplicateFilesTests` — the symlink-collapse
//     disclosure. `Plan.duplicateFileNameCount` still computes it and
//     `ProjectRecipientApplierTests` still pins the collapse itself; nothing
//     renders the count now.
//
// Both were render tests through `ProjectAccessView`, and neither behaviour
// has a home on the page. Deleted rather than re-pointed at a view that
// cannot show them — a test rewritten until it passes proves nothing.

// MARK: - I1: a plan computed for an older staged set must never be written

/// Holds the *next* scan that starts after `arm()` until the test releases it,
/// so two `refreshPlan()` calls can be made to complete in a chosen order
/// rather than a hoped-for one. A sleep would make the same point on a good day
/// and a flake on a bad one; this makes the interleave exact.
private actor ScanGate {
    private var armed = false
    private var arrived = false
    private var released = false
    private var release: CheckedContinuation<Void, Never>?

    func arm() {
        armed = true
        arrived = false
        released = false
    }

    /// Called from inside the injected scan seam.
    func enter() async {
        guard armed else { return }
        armed = false
        arrived = true
        if released { return }
        await withCheckedContinuation { release = $0 }
    }

    func hasArrived() -> Bool { arrived }

    func releaseNow() {
        released = true
        release?.resume()
        release = nil
    }
}

@Suite("ProjectAccessModel — .sops.yaml is never written from a stale plan")
@MainActor
struct ProjectAccessPlanGenerationTests {

    /// Polls rather than suspending on a continuation, and gives up.
    ///
    /// The pre-fix `applyConfig()` never re-plans at all, so a continuation
    /// waiting for its scan to start waits forever: the test would hang instead
    /// of failing, which is the worst way for a guard to report a regression.
    private func waitForArrival(_ gate: ScanGate) async {
        for _ in 0..<200 {
            if await gate.hasArrived() { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("no scan started within 10s — nothing re-planned")
    }

    private func gatedApplier(_ gate: ScanGate) -> ProjectRecipientApplier {
        ProjectRecipientApplier(scanProject: { root in
            await gate.enter()
            return await ProjectScanner.scan(root: root)
        })
    }

    /// The exact failure the final review named. Config declares [A]. The user
    /// adds B, which starts a refresh planning for [A, B]; while that whole-tree
    /// walk is in flight they add C, and a second refresh plans for [A, B, C].
    /// The first one finishes *last*.
    ///
    /// Before the generation stamp, last-to-finish won: `plan.configUpdateText`
    /// was the text for [A, B], the panel showed all three (rows come from
    /// `stagedRecipients`), and a confirmed "Update .sops.yaml" wrote a rule
    /// that had never heard of C — with `configRecipients` then claiming it had.
    @Test("a refresh that finishes last cannot overwrite a newer one")
    func aStalePlanIsNeverTheOneThatGetsWritten() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let second = try ProjectAgeKeyPair.generate()
        let third = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let gate = ScanGate()
        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(
            projectRoot: root, keyStore: keyStore, applier: gatedApplier(gate))
        await model.load()

        model.stageAdd(second.public)
        await gate.arm()
        let overtaken = Task { await model.refreshPlan() }
        await waitForArrival(gate)

        // Staged while the first refresh is still walking the tree.
        model.stageAdd(third.public)
        await model.refreshPlan()

        // ...and only now does the first one land.
        await gate.releaseNow()
        await overtaken.value

        #expect(model.plan?.requestedRecipients == model.stagedRecipients,
                "the overtaken refresh published its older plan on top of the newer one")
        #expect(await model.applyConfig() == .written)

        let config = try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(config.contains(third.public),
                "the recipient staged during the refresh was silently dropped from .sops.yaml")
        #expect(config.contains(second.public))
        #expect(config.contains(owner.public))
        #expect(Set(model.configRecipients) == Set(model.stagedRecipients))
    }

    /// The other half of the guard: a plan that is merely *out of date* (no
    /// refresh was ever started for the current staged set) is re-planned rather
    /// than written or silently treated as "nothing to write".
    @Test("applying with a plan nobody refreshed re-plans first")
    func applyConfigReplansAStalePlan() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()

        // Deliberately no refreshPlan() — the plan in hand is the load's own
        // inspection, computed for a set that is not what would be written.
        model.stageAdd(added.public)

        #expect(await model.applyConfig() == .written)
        let config = try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8)
        #expect(config.contains(added.public))
        #expect(config.contains(owner.public))
    }

    /// And when the staged set moves again *during* that re-plan, nothing is
    /// written at all: there is no text on hand for what the user is looking at,
    /// and the older text is the one thing that must not be used.
    @Test("a staged change during the re-plan refuses the write outright")
    func applyConfigRefusesWhenTheStagedSetMovesAgain() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let second = try ProjectAgeKeyPair.generate()
        let third = try ProjectAgeKeyPair.generate()
        let (root, config) = try makeProject(owner: owner)

        let gate = ScanGate()
        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(
            projectRoot: root, keyStore: keyStore, applier: gatedApplier(gate))
        await model.load()

        model.stageAdd(second.public)
        await gate.arm()
        let applying = Task { await model.applyConfig() }
        await waitForArrival(gate)

        model.stageAdd(third.public)
        await gate.releaseNow()

        #expect(await applying.value == .refusedStalePlan)
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config,
                "a refusal must leave .sops.yaml byte-identical")
    }
}

// MARK: - I2: the fallback scope crosses creation-rule boundaries, and says so

/// One rule, `^prod/`, and a file outside it that sorts first. The panel targets
/// `dev/local.yaml`, no rule governs it, and `filesInScope` widens to all three
/// — including the two `prod/` files a different rule's key set decides.
private func makeCrossRuleProject(owner: ProjectAgeKeyPair) throws -> URL {
    let root = try projectScratchDirectory("project-access-cross-rule")
    try """
        creation_rules:
          - path_regex: ^prod/.*\\.yaml$
            age: \(owner.public)

        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
    let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
    for directory in ["dev", "prod"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    for path in ["dev/local.yaml", "prod/api.yaml", "prod/db.yaml"] {
        try encrypted.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    return root
}

@Suite("ProjectAccessModel — a fallback scope that crosses rules is counted")
@MainActor
struct ProjectAccessCrossRuleDisclosureTests {

    @Test("files another creation rule governs are counted, not just swept in")
    func theFallbackScopeNamesTheOtherRulesFiles() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let root = try makeCrossRuleProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        try #require(model.plan?.governingRuleIdentified == false,
                     "precondition: the alphabetically first file matches no rule")
        #expect(model.filesToApply.count == 3)
        #expect(model.plan?.filesGovernedByOtherRules.map(\.lastPathComponent).sorted()
                == ["api.yaml", "db.yaml"])
    }

    // The panel sentence and the confirmation dialog that repeated it went
    // with `ProjectAccessView` (SOPS-39 task 10). `filesGovernedByOtherRules`
    // is still computed and still pinned above; the Access page never widens
    // a scope across rules in the first place — a rewrap runs per rule, for
    // that rule's own declared recipients (`RewrapCoordinator`).
}

// MARK: - Ticket #24 claim 1: widening onto another rule's files needs explicit consent

/// Before this, a widened scope that reaches across creation-rule boundaries
/// was stated in prose — on the panel and again in the confirmation dialog —
/// but reading the sentence was the only thing standing between a user and
/// re-wrapping files a different rule's key set governs. This suite pins
/// that `applyToFiles()` itself refuses until the user has explicitly
/// acknowledged it, not just been told.
///
/// Deliberately narrow: the gate is `!governingRuleIdentified &&
/// !filesGovernedByOtherRules.isEmpty`, not merely
/// `!governingRuleIdentified`. `ProjectAccessScopeFallbackTests` already
/// covers the ordinary widened-scope case (no rule matched *anything*, so
/// there is no other rule's key set at risk) and continues to apply without
/// any acknowledgement — see `rulelessProjectStillHasFilesInScope`,
/// unchanged by this ticket. The acknowledgement exists for the one case the
/// ticket is actually about: files a *different*, identifiable rule governs.
@Suite("ProjectAccessModel — widening onto another rule's files needs explicit consent")
@MainActor
struct ProjectAccessWidenedScopeAcknowledgementTests {

    @Test("applying to files is refused until the widened scope is acknowledged")
    func applyIsRefusedWithoutAcknowledgement() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try makeCrossRuleProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()
        try #require(model.plan?.governingRuleIdentified == false)
        try #require(model.plan?.filesGovernedByOtherRules.isEmpty == false)

        #expect(model.requiresWidenedScopeAcknowledgement)
        #expect(!model.widenedScopeAcknowledged, "a fresh plan must not start pre-acknowledged")
        #expect(await model.applyToFiles() == .widenedScopeNotAcknowledged)
        #expect(model.fileResults.isEmpty, "nothing may be touched before the user consents")
    }

    @Test("acknowledging the widened scope lets the run proceed")
    func applyProceedsOnceAcknowledged() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try makeCrossRuleProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()

        model.acknowledgeWidenedScope(true)
        #expect(await model.applyToFiles() == nil)
        #expect(model.fileResults.count == model.filesToApply.count)
    }

    @Test("a fresh plan clears a stale acknowledgement")
    func newPlanClearsAcknowledgement() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try makeCrossRuleProject(owner: owner)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)
        await model.refreshPlan()
        model.acknowledgeWidenedScope(true)
        #expect(model.widenedScopeAcknowledged)

        // Any later plan — even one recomputed for the same staged set —
        // must not let an old acknowledgement carry forward silently onto
        // whatever the new plan's scope turns out to be.
        await model.refreshPlan()
        #expect(!model.widenedScopeAcknowledged,
                "a stale acknowledgement survived a re-plan — a scope the user never saw could be applied")
    }

    @Test("a project with no other rule in play never requires acknowledgement")
    func ordinaryWidenedScopeNeedsNoAcknowledgement() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let added = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        try """
            creation_rules:
              - path_regex: nothing-here/.*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(projectPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let keyStore = SessionKeyStore()
        try keyStore.importKey(owner.private)
        let model = ProjectAccessModel(projectRoot: root, keyStore: keyStore)
        await model.load()
        model.stageAdd(added.public)

        try #require(model.plan?.governingRuleIdentified == false)
        try #require(model.plan?.filesGovernedByOtherRules.isEmpty == true)
        #expect(!model.requiresWidenedScopeAcknowledgement)
        #expect(await model.applyToFiles() == nil, "no other rule's files are at stake here")
    }

    // The Apply-Files button gate that repeated this refusal
    // (`ProjectAccessView.canApplyToFiles`) went with the panel in SOPS-39
    // task 10. The refusal above is the model's own and is where it always
    // mattered — a gate can only stop a press, not a call.
}

// MARK: - I3 / M3: what a row shows, and what the Add button agrees to

@Suite("Recipient rows — the registry's kind is shown on the per-file panel")
@MainActor
struct RecipientKindDisplayTests {

    private func labels(in nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    // The project-wide panel drew `RecipientKindBadge` too, and had a test
    // for it here. The Access page names keys by their `.sops.yaml` anchor
    // and has no kind column, so that assertion went with `ProjectAccessView`
    // (SOPS-39 task 10). The badge itself is still drawn by the per-file
    // panel below and by `CiphertextReadOnlyView`.

    @Test("the per-file panel draws the same kind the same way")
    func filePanelShowsTheKind() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)
        try RecipientRegistry.upsert(
            RecipientRecord(label: "Alice's laptop", kind: .device, ageRecipient: owner.public),
            in: root)

        let model = RecipientAccessModel(
            fileURL: root.appendingPathComponent("a.yaml"), projectURL: root,
            keyStore: SessionKeyStore(), format: .yaml)
        let host = GatingHost(size: CGSize(width: 460, height: 520)) {
            AnyView(RecipientAccessView(model: model, onClose: {}, onApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        #expect(labels(in: host.nodes()).contains(LocalizedKey.recipientKindDevice.text))
    }

    /// M3. The per-file panel enabled Add on `.whitespaces` while both models
    /// trim `.whitespacesAndNewlines`, so a pasted lone newline lit the button
    /// up and pressing it returned `.empty` — whose `explanation(for:)` is
    /// `nil`. A live button, a press, and no feedback of any kind.
    @Test("the Add button agrees with what the models will accept")
    func addButtonTrimsWhatTheModelsTrim() {
        #expect(!RecipientRowContent.canAdd("\n"))
        #expect(!RecipientRowContent.canAdd(" \n\t "))
        #expect(!RecipientRowContent.canAdd(""))
        #expect(RecipientRowContent.canAdd("age1abc"))
        #expect(RecipientRowContent.canAdd("  age1abc\n"))
    }

    /// A correct helper nothing calls is not a fix, and the two panels drifting
    /// apart is the defect rather than either spelling on its own — so what is
    /// pinned is that neither view trims for itself. `AppShellProjectRootSourceTests`
    /// reads source for the same reason: a `View` struct's `.disabled(…)`
    /// modifier is not reachable from a unit test.
    @Test("neither Access surface decides for itself what an empty recipient is")
    func neitherPanelTrimsOnItsOwn() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/SopsUI")
        for relative in ["Editor/RecipientAccessView.swift", "Projects/AccessRuleCard.swift"] {
            let text = try String(
                contentsOf: sources.appendingPathComponent(relative), encoding: .utf8)
            // The narrower set, spelled exactly: `.whitespacesAndNewlines)`
            // does not match this, so the shared helper's own definition (which
            // lives in one of these two files) is not a false positive.
            #expect(!text.contains("trimmingCharacters(in: .whitespaces)"),
                    "\(relative) trims the new-recipient field with the narrower set the models do not use — route it through RecipientRowContent.canAdd")
            #expect(text.contains("RecipientRowContent.canAdd"),
                    "\(relative) no longer asks RecipientRowContent whether Add may be pressed")
        }
    }
}
