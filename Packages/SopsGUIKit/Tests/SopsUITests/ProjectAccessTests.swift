import Foundation
import ScratchCleanup
import SopsEngine
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
    let encrypted = try SopsBridge.encryptYAML(projectPlainYAML, recipients: [owner.public])
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
            #expect(try SopsBridge.recipients(in: bytes) == [owner.public])
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
            #expect(Set(try SopsBridge.recipients(in: bytes)) == Set([owner.public, added.public]))
            #expect(try SopsBridge.decryptYAML(bytes, agePrivateKey: added.private) == projectPlainYAML)
        }
        // The config is byte-identical: it was never part of this action.
        #expect(try String(contentsOf: root.appendingPathComponent(".sops.yaml"), encoding: .utf8) == config)
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
        let encrypted = try SopsBridge.encryptYAML(projectPlainYAML, recipients: [owner.public])
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

@Suite("Project access gates")
struct ProjectAccessGateTests {

    @Test("the Project Access button is unreachable while the open document is dirty")
    func gateClosesOnADirtyDocument() {
        #expect(ProjectAccessGate.canOpen(hasProject: true, documentIsDirty: false, documentIsSaving: false))
        #expect(!ProjectAccessGate.canOpen(hasProject: true, documentIsDirty: true, documentIsSaving: false))
        #expect(!ProjectAccessGate.canOpen(hasProject: true, documentIsDirty: false, documentIsSaving: true))
        #expect(!ProjectAccessGate.canOpen(hasProject: false, documentIsDirty: false, documentIsSaving: false))
    }

    @Test("Update .sops.yaml is offered only when there is something to write")
    func configButtonGate() {
        #expect(ProjectAccessView.canUpdateConfig(
            loadState: .loaded, configNeedsWriting: true, stagedIsEmpty: false, isApplyingFiles: false))
        #expect(!ProjectAccessView.canUpdateConfig(
            loadState: .loaded, configNeedsWriting: false, stagedIsEmpty: false, isApplyingFiles: false))
        #expect(!ProjectAccessView.canUpdateConfig(
            loadState: .loaded, configNeedsWriting: true, stagedIsEmpty: true, isApplyingFiles: false))
        #expect(!ProjectAccessView.canUpdateConfig(
            loadState: .loaded, configNeedsWriting: true, stagedIsEmpty: false, isApplyingFiles: true))
        #expect(!ProjectAccessView.canUpdateConfig(
            loadState: .loading, configNeedsWriting: true, stagedIsEmpty: false, isApplyingFiles: false))
    }

    @Test("Apply to Files needs files, recipients and a key")
    func fileButtonGate() {
        #expect(ProjectAccessView.canApplyToFiles(
            loadState: .loaded, fileCount: 3, stagedIsEmpty: false, keyConfigured: true,
            isApplyingFiles: false))
        #expect(!ProjectAccessView.canApplyToFiles(
            loadState: .loaded, fileCount: 0, stagedIsEmpty: false, keyConfigured: true,
            isApplyingFiles: false))
        #expect(!ProjectAccessView.canApplyToFiles(
            loadState: .loaded, fileCount: 3, stagedIsEmpty: true, keyConfigured: true,
            isApplyingFiles: false))
        #expect(!ProjectAccessView.canApplyToFiles(
            loadState: .loaded, fileCount: 3, stagedIsEmpty: false, keyConfigured: false,
            isApplyingFiles: false))
        #expect(!ProjectAccessView.canApplyToFiles(
            loadState: .loaded, fileCount: 3, stagedIsEmpty: false, keyConfigured: true,
            isApplyingFiles: true))
        #expect(!ProjectAccessView.canApplyToFiles(
            loadState: .failed("nope"), fileCount: 3, stagedIsEmpty: false, keyConfigured: true,
            isApplyingFiles: false))
    }

    @Test("every file-apply refusal has an explanation to show")
    func everyRefusalIsExplained() {
        for refusal: ProjectAccessModel.FileApplyRefusal in [.notLoaded, .emptyRecipients, .noFiles, .noKey] {
            #expect(!ProjectAccessView.explanation(for: refusal).isEmpty)
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
        let encrypted = try SopsBridge.encryptYAML(projectPlainYAML, recipients: [owner.public])
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
        #expect(model.filesToApply.map(\.lastPathComponent) == ["secret.yaml"])

        model.stageAdd(added.public)
        #expect(await model.applyToFiles() == nil)
        #expect(model.fileResults.map(\.outcome) == [.updated])
    }

    @Test("a project with no config at all still has every encrypted file in scope")
    func configlessProjectStillHasFilesInScope() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        let encrypted = try SopsBridge.encryptYAML(projectPlainYAML, recipients: [owner.public])
        for name in ["a.yaml", "b.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        await model.load()

        #expect(model.plan?.configExists == false)
        #expect(model.filesToApply.count == 2)
    }
}

@Suite("ProjectAccessView — what an apply will touch is always stated on the panel")
@MainActor
struct ProjectAccessScopeDisclosureTests {

    /// I5. `Plan.filesInScope` deliberately falls back to *every* encrypted
    /// file when no governing creation rule could be identified — otherwise a
    /// project with no `.sops.yaml`, an unreadable one, or one whose rules
    /// match nothing would apply to nothing and report success. But the panel
    /// rendered its scope sentence only in the rule-identified branch, so in
    /// exactly the case where the scope was *widest* the user was told
    /// nothing about it until the confirmation dialog. The count belongs on
    /// the panel, before the button is pressed.
    /// Every label the rendered panel exposes.
    ///
    /// Deliberately unfiltered, and both sides of every assertion below go
    /// through `LocalizedKey.text`. Under plain `swift test` the string catalog
    /// is copied uncompiled (CLAUDE.md), so `LocalizedKey.text` resolves to the
    /// raw key and `String(format:)` substitutes nothing — an assertion written
    /// against literal English ("…will re-wrap all 2 encrypted files…") passes
    /// only under a catalog-compiling build and fails here for a reason that
    /// has nothing to do with the view. Comparing key-derived text to
    /// key-derived text is stable under both build systems and still proves the
    /// thing this test is about: *which* sentence the panel renders in *which*
    /// branch. That the counts inside it are right is pinned by the model-level
    /// tests above, and that the plural forms resolve by `LocalizationTests`.
    private func labels(in nodes: [GatingAXProbe.Node]) -> [String] {
        nodes.flatMap { [$0.label, $0.value] }
    }

    @Test("a project with no .sops.yaml still says how many files an apply would touch")
    func scopeIsStatedWithoutAConfig() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        let encrypted = try SopsBridge.encryptYAML(projectPlainYAML, recipients: [owner.public])
        for name in ["a.yaml", "b.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 560, height: 620)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        try #require(model.loadState == .loaded, "precondition: the view's own task loaded the model")
        try #require(model.plan?.governingRuleIdentified == false, "precondition: the fallback branch")
        #expect(model.filesToApply.count == 2)

        let expected = String(format: LocalizedKey.projectAccessAllFilesInScope.text, 2)
        #expect(
            labels(in: host.nodes()).contains(expected),
            "the panel must state what an apply would touch even when no rule was identified")
    }

    @Test("a project whose creation rule matches nothing still says how many files an apply would touch")
    func scopeIsStatedWhenNoRuleMatches() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let root = try projectScratchDirectory()
        try """
            creation_rules:
              - path_regex: nothing-here/.*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encryptYAML(projectPlainYAML, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 560, height: 620)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.loadState == .loaded })

        try #require(model.loadState == .loaded)
        try #require(model.plan?.governingRuleIdentified == false)

        let expected = String(format: LocalizedKey.projectAccessAllFilesInScope.text, 1)
        #expect(labels(in: host.nodes()).contains(expected))
    }

    /// The branch that already worked, kept alongside so a future change
    /// cannot fix the fallback by deleting the case it was modelled on.
    @Test("a project whose rule was identified states the matched-of-found count")
    func scopeIsStatedWhenARuleIsIdentified() async throws {
        let owner = try ProjectAgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner)

        let model = ProjectAccessModel(projectRoot: root, keyStore: SessionKeyStore())
        let host = GatingHost(size: CGSize(width: 560, height: 620)) {
            AnyView(ProjectAccessView(model: model, onClose: {}, onFilesApplied: {}))
        }
        defer { host.finish() }
        await host.settle(until: { model.plan?.governingRuleIdentified == true })

        try #require(model.plan?.governingRuleIdentified == true)
        let expected = String(format: LocalizedKey.projectAccessFilesSummary.text, "2", "2")
        #expect(labels(in: host.nodes()).contains(expected))
    }
}
