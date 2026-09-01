import Foundation
import ScratchCleanup
import SopsEngine
import Testing

@testable import SopsProjects

// MARK: - Fixture plumbing
//
// Encrypted fixtures go through the real in-process bridge
// (`SopsBridge.encryptYAML`), never a hand-written string — the discipline
// Task 1's `RecipientManagementTests` and Task 3's `RecipientAccessTests`
// established for this surface. Only key generation shells out, because there
// is no in-process keygen.

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
            "\(executable) exited \(process.terminationStatus): " + String(decoding: errData, as: UTF8.self))
    }
    return String(decoding: outData, as: UTF8.self)
}

struct AgeKeyPair {
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

func applierScratchDirectory(_ label: String = "project-applier") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString, isDirectory: true)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// sops's own YAML emitter normalizes indentation to four spaces, so a fixture
// meant to survive a decrypt round-trip byte-for-byte must already be in that
// shape — same reason `CompatibilityTests` and `RecipientAccessTests` use it.
let applierPlainYAML = "database:\n    password: correct-horse-battery-staple\n"

// `apply(files:...)` has taken `[ProjectRecipientApplier.ScopedFile]` rather
// than bare `[URL]` since Task 7 (SOPS-38) — every fixture in this file
// before that task was YAML, and stays YAML unless a test says otherwise, so
// this is the one-line wrap most call sites below need.
func yamlScoped(_ urls: [URL]) -> [ProjectRecipientApplier.ScopedFile] {
    urls.map { ProjectRecipientApplier.ScopedFile(url: $0, format: .yaml) }
}

@Suite("ProjectRecipientApplier — one bad file does not stop the run")
struct ProjectRecipientApplierFailureIsolationTests {

    /// The behaviour the task brief names first: a file this app cannot read
    /// or cannot parse is recorded as `failed` and the run *continues*, and
    /// nothing about `.sops.yaml` changes, because applying to files and
    /// rewriting the config are two separate, separately confirmed actions.
    @Test("an unreadable and a malformed file are recorded as failures without stopping the others")
    func oneBadFileDoesNotBlockTheRest() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()

        let root = try applierScratchDirectory()

        // The project config, exactly as it must still be afterwards.
        let configURL = root.appendingPathComponent(".sops.yaml")
        let configText = """
            creation_rules:
              - path_regex: \\.yaml$
                age: \(owner.public)
            """ + "\n"
        try configText.write(to: configURL, atomically: true, encoding: .utf8)

        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])

        let first = root.appendingPathComponent("a-first.yaml")
        try encrypted.write(to: first, atomically: true, encoding: .utf8)

        // Readable at scan time, unreadable when the applier gets to it.
        let unreadable = root.appendingPathComponent("b-unreadable.yaml")
        try encrypted.write(to: unreadable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
        }

        // Carries a `sops:` block, so a scan calls it encrypted, but sops
        // itself cannot load it.
        let malformed = root.appendingPathComponent("c-malformed.yaml")
        try "not-a-document: [\nsops:\n  version: 3.13.3\n".write(
            to: malformed, atomically: true, encoding: .utf8)

        let last = root.appendingPathComponent("d-last.yaml")
        try encrypted.write(to: last, atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let outcome = await applier.apply(
            files: yamlScoped([first, unreadable, malformed, last]),
            recipients: [owner.public, added.public],
            agePrivateKey: owner.private)

        // Ordered, one result per file, in the order they were handed over.
        #expect(outcome.results.map(\.url) == [first, unreadable, malformed, last])

        #expect(outcome.results[0].outcome == .updated)
        #expect(outcome.results[3].outcome == .updated)

        guard case .failed(let unreadableReason) = outcome.results[1].outcome else {
            Issue.record("expected the unreadable file to fail, got \(outcome.results[1].outcome)")
            return
        }
        #expect(!unreadableReason.isEmpty)

        guard case .failed(let malformedReason) = outcome.results[2].outcome else {
            Issue.record("expected the malformed file to fail, got \(outcome.results[2].outcome)")
            return
        }
        #expect(!malformedReason.isEmpty)

        // The two good files really were re-wrapped — checked through the
        // engine, not by trusting the outcome enum.
        for url in [first, last] {
            let bytes = try String(contentsOf: url, encoding: .utf8)
            #expect(Set(try SopsBridge.recipients(in: bytes, format: .yaml)) == Set([owner.public, added.public]))
            #expect(try SopsBridge.decrypt(bytes, format: .yaml, agePrivateKey: added.private) == applierPlainYAML)
        }

        // The two bad ones were left exactly as they were.
        #expect(try String(contentsOf: malformed, encoding: .utf8)
            == "not-a-document: [\nsops:\n  version: 3.13.3\n")

        // And the config did not change: a project apply never rewrites
        // `.sops.yaml` as a side effect of rewrapping files.
        #expect(try String(contentsOf: configURL, encoding: .utf8) == configText)
    }
}

/// A thread-safe tally, for proving a path did *not* reach the bridge or the
/// disk. `@unchecked Sendable` with a lock rather than an actor because the
/// seams it counts are synchronous and run on `ProjectRecipientApplier`'s own
/// dedicated worker thread — the same shape `ProjectScanner`'s
/// `EnumerationErrorLog` uses, and for the same reason.
final class CallTally: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        counts[name, default: 0] += 1
    }

    func count(_ name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return counts[name] ?? 0
    }
}

@Suite("ProjectRecipientApplier — a file that already agrees is left alone")
struct ProjectRecipientApplierUnchangedTests {

    @Test("a file already listing exactly the requested set is never decrypted or written")
    func alreadyCorrectFileIsUnchanged() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()

        let encrypted = try SopsBridge.encrypt(
            applierPlainYAML, format: .yaml, recipients: [owner.public, other.public])
        let url = root.appendingPathComponent("secret.yaml")
        try encrypted.write(to: url, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: url, encoding: .utf8)

        let tally = CallTally()
        let applier = ProjectRecipientApplier(
            writeFile: { _, _, _ in tally.record("write") },
            rewrapRecipients: { _, _, _, _ in
                tally.record("rewrap")
                return ""
            })

        // Same members, opposite order: still nothing to do.
        let outcome = await applier.apply(
            files: yamlScoped([url]), recipients: [other.public, owner.public],
            agePrivateKey: owner.private)

        #expect(outcome.results.map(\.outcome) == [.unchanged])
        #expect(outcome.unchangedCount == 1)
        #expect(tally.count("rewrap") == 0)
        #expect(tally.count("write") == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == before)
    }
}

@Suite("ProjectRecipientApplier — cancellation happens between files, never inside one")
struct ProjectRecipientApplierCancellationTests {

    @Test("a run cancelled after the first file leaves the rest untouched and says so")
    func cancellationStopsBetweenFiles() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()

        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        var files: [URL] = []
        for name in ["a.yaml", "b.yaml", "c.yaml"] {
            let url = root.appendingPathComponent(name)
            try encrypted.write(to: url, atomically: true, encoding: .utf8)
            files.append(url)
        }
        let untouchedBytes = try String(contentsOf: files[1], encoding: .utf8)

        // The first file is held inside its own read — on the applier's own
        // worker thread, so a `DispatchSemaphore.wait` there is legitimate —
        // long enough for this test to cancel the run around it. The test side
        // only ever polls and signals, never waits, because
        // `DispatchSemaphore.wait` is unavailable from an async context.
        let mayFinish = DispatchSemaphore(value: 0)
        let tally = CallTally()

        let applier = ProjectRecipientApplier(
            readRecipients: { contents, format in
                tally.record("read")
                if tally.count("read") == 1 {
                    mayFinish.wait()
                }
                return try SopsBridge.recipients(in: contents, format: format)
            })

        let files_ = yamlScoped(files)
        let task = Task {
            await applier.apply(
                files: files_, recipients: [owner.public, added.public], agePrivateKey: owner.private)
        }

        while tally.count("read") == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        mayFinish.signal()
        let outcome = await task.value

        // The file already in flight was finished, not abandoned mid-write.
        #expect(outcome.results.count == 1)
        #expect(outcome.results[0].outcome == .updated)
        #expect(outcome.notAttempted == [files[1], files[2]])
        #expect(outcome.wasCancelled)

        // And the two never attempted are byte-identical to what they were.
        #expect(try String(contentsOf: files[1], encoding: .utf8) == untouchedBytes)
        #expect(try String(contentsOf: files[2], encoding: .utf8) == untouchedBytes)
        #expect(tally.count("read") == 1)
    }
}

@Suite("ProjectRecipientApplier — a second writer is refused, not clobbered")
struct ProjectRecipientApplierSecondWriterTests {

    @Test("a file changed between the read and the write is refused and the run continues")
    func secondWriterIsRefused() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()

        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        let contended = root.appendingPathComponent("a-contended.yaml")
        let quiet = root.appendingPathComponent("b-quiet.yaml")
        try encrypted.write(to: contended, atomically: true, encoding: .utf8)
        try encrypted.write(to: quiet, atomically: true, encoding: .utf8)

        // A real second writer, landing between this applier's read and its
        // write: the rewrap seam does the real work and then somebody else
        // replaces the file underneath it.
        let applier = ProjectRecipientApplier(
            rewrapRecipients: { contents, format, recipients, key in
                let out = try SopsBridge.updateRecipients(contents, format: format, to: recipients, agePrivateKey: key)
                if contents == encrypted, FileManager.default.fileExists(atPath: contended.path) {
                    // Only interfere with the first file.
                    let marker = try SopsBridge.encrypt(
                        "database:\n    password: somebody-elses-write\n", format: .yaml, recipients: [owner.public])
                    try? marker.write(to: contended, atomically: true, encoding: .utf8)
                }
                return out
            })

        let outcome = await applier.apply(
            files: yamlScoped([contended, quiet]), recipients: [owner.public, added.public],
            agePrivateKey: owner.private)

        guard case .failed(let reason) = outcome.results[0].outcome else {
            Issue.record("expected the contended file to be refused, got \(outcome.results[0].outcome)")
            return
        }
        #expect(reason.contains("changed on disk"))
        // The second writer's version survived — it was not clobbered.
        #expect(try SopsBridge.decrypt(
            String(contentsOf: contended, encoding: .utf8), format: .yaml, agePrivateKey: owner.private)
            == "database:\n    password: somebody-elses-write\n")

        // ...and the run carried on to the next file.
        #expect(outcome.results[1].outcome == .updated)
    }
}

@Suite("ProjectRecipientApplier — failure reasons never carry key material")
struct ProjectRecipientApplierSecrecyTests {

    @Test("no result mentions the private identity or a plaintext value")
    func reasonsAreFreeOfSecrets() async throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()

        // Encrypted for somebody else entirely: the session key cannot open it.
        let foreign = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [stranger.public])
        let url = root.appendingPathComponent("foreign.yaml")
        try foreign.write(to: url, atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let outcome = await applier.apply(
            files: yamlScoped([url]), recipients: [owner.public], agePrivateKey: owner.private)

        guard case .failed(let reason) = outcome.results[0].outcome else {
            Issue.record("expected a failure, got \(outcome.results[0].outcome)")
            return
        }
        #expect(!reason.contains(owner.private))
        #expect(!reason.contains(stranger.private))
        #expect(!reason.contains("correct-horse-battery-staple"))
        #expect(!reason.isEmpty)
    }
}

@Suite("ProjectRecipientApplier — planning reads, and only reads")
struct ProjectRecipientApplierPlanTests {

    /// Builds a project with two encrypted files under one rule and one under
    /// another, so "matched" has to mean *this rule*, not "an encrypted file
    /// somewhere in the project".
    private func makeProject(owner: AgeKeyPair, other: AgeKeyPair) throws -> (URL, String) {
        let root = try applierScratchDirectory()
        let configText = """
            # Team configuration
            creation_rules:
              - path_regex: prod/.*\\.yaml$
                age:
                  - \(owner.public)
              - path_regex: staging/.*\\.yaml$
                age:
                  - \(other.public)

            """
        try configText.write(
            to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let prod = root.appendingPathComponent("prod", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for dir in [prod, staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let forOwner = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        let forOther = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [other.public])
        try forOwner.write(to: prod.appendingPathComponent("db.yaml"), atomically: true, encoding: .utf8)
        try forOwner.write(to: prod.appendingPathComponent("api.yaml"), atomically: true, encoding: .utf8)
        try forOther.write(
            to: staging.appendingPathComponent("db.yaml"), atomically: true, encoding: .utf8)
        return (root, configText)
    }

    @Test("a plan names the files the governing rule covers, and the ones it does not")
    func planSeparatesMatchedFromUnmatched() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let (root, configText) = try makeProject(owner: owner, other: other)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public, added.public])

        #expect(plan.configExists)
        #expect(plan.configError == nil)
        #expect(plan.configRefusal == nil)
        #expect(plan.encryptedFiles.count == 3)
        #expect(Set(plan.matchedFiles.map(\.lastPathComponent)) == Set(["db.yaml", "api.yaml"]))
        #expect(plan.matchedFiles.allSatisfy { $0.path.contains("/prod/") })
        #expect(plan.unmatchedFiles.map { $0.path.contains("/staging/") } == [true])
        #expect(plan.configRecipients == [owner.public])
        #expect(plan.configNeedsWriting)

        // Planning is a read. Nothing on disk moved — least of all the config.
        #expect(try String(contentsOf: plan.configURL, encoding: .utf8) == configText)
    }

    // Task 7 (SOPS-38): the TEMPORARY YAML-only filter Task 5 put in front of
    // `tree.encrypted` is gone — a dotenv sops file the governing rule would
    // otherwise match now reaches `plan.encryptedFiles`/`matchedFiles`
    // exactly like a YAML one, tagged with its own format.
    //
    // Deliberately not built on `makeProject`: its two rules are YAML-only
    // (`path_regex: prod/.*\.yaml$`), so a `.env` file under `prod/` would
    // never match either — that would be testing the rule's regex, not this
    // task. The rule here is extension-agnostic, matching every file under
    // `prod/` regardless of format, which is the shape a project actually
    // covering both would have.
    @Test("a dotenv sops file in the project is included in the plan, tagged with its own format")
    func dotenvFileIsIncludedInThePlan() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        try """
            creation_rules:
              - path_regex: prod/.*
                age: \(owner.public)
              - path_regex: staging/.*
                age: \(other.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let prod = root.appendingPathComponent("prod", isDirectory: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        for dir in [prod, staging] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let forOwner = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        let forOther = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [other.public])
        try forOwner.write(to: prod.appendingPathComponent("db.yaml"), atomically: true, encoding: .utf8)
        try forOwner.write(to: prod.appendingPathComponent("api.yaml"), atomically: true, encoding: .utf8)
        try forOther.write(
            to: staging.appendingPathComponent("db.yaml"), atomically: true, encoding: .utf8)

        // A dotenv sops file the same rule would otherwise match, dropped
        // into the "prod" directory next to the two real YAML files that
        // rule already governs.
        let dotenvEncrypted = try SopsBridge.encrypt(
            "DB_PASSWORD=hunter2\n", format: .dotenv, recipients: [owner.public])
        try dotenvEncrypted.write(
            to: prod.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public, added.public])

        #expect(plan.configError == nil)
        #expect(plan.configRefusal == nil)
        // The two YAML files under prod/, the dotenv one under prod/, and the
        // one under staging/ — four files now, not three.
        #expect(plan.encryptedFiles.count == 4)
        #expect(plan.encryptedFiles.contains { $0.lastPathComponent == ".env" })
        #expect(plan.matchedFiles.contains { $0.lastPathComponent == ".env" })
        #expect(!plan.unmatchedFiles.contains { $0.lastPathComponent == ".env" })
        // A same-directory file with a different name is not a duplicate name.
        #expect(plan.duplicateFileNameCount == 0)

        // Format-tagged, not assumed: the dotenv file is the one entry in
        // scope whose format is `.dotenv`, everything else stays `.yaml`.
        let scoped = plan.filesInScope
        let dotenvEntry = try #require(scoped.first { $0.url.lastPathComponent == ".env" })
        #expect(dotenvEntry.format == .dotenv)
        #expect(scoped.filter { $0.url.lastPathComponent != ".env" }.allSatisfy { $0.format == .yaml })
    }

    @Test("a plan for the set the config already declares has nothing to write")
    func planForAnUnchangedSetWritesNothing() async throws {
        let owner = try AgeKeyPair.generate()
        let other = try AgeKeyPair.generate()
        let (root, _) = try makeProject(owner: owner, other: other)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public])

        #expect(plan.configRefusal == nil)
        #expect(!plan.configNeedsWriting)
        #expect(applier.writeConfig(plan) == .nothingToWrite)
    }

    /// A project with no `.sops.yaml` at all still has files in scope
    /// (`Plan.filesInScope`'s fallback), and since Task 7 that is true for a
    /// project holding *only* dotenv sops files, not just YAML ones — the
    /// SOPS-37-shaped scenario the task brief names: a governing rule cannot
    /// be identified because there is no config, so the fallback must widen
    /// to every encrypted file found, dotenv included, rather than come back
    /// empty because nothing here is YAML.
    @Test("a project with only dotenv sops files still has a non-empty scope")
    func dotenvOnlyProjectStillHasFilesInScope() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("dotenv-only-scope")

        let dotenvEncrypted = try SopsBridge.encrypt(
            "DB_PASSWORD=hunter2\n", format: .dotenv, recipients: [owner.public])
        try dotenvEncrypted.write(
            to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public])

        #expect(!plan.configExists)
        #expect(plan.encryptedFiles.count == 1)
        #expect(!plan.filesInScope.isEmpty)
        #expect(plan.filesInScope.first?.format == .dotenv)
    }

    @Test("a project with no .sops.yaml plans without a config and without failing")
    func planWithoutAConfig() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let plan = await ProjectRecipientApplier().plan(
            projectRoot: root, recipients: [owner.public])

        #expect(!plan.configExists)
        #expect(plan.configError == nil)
        #expect(plan.configRefusal == nil)
        #expect(!plan.configNeedsWriting)
        #expect(plan.encryptedFiles.count == 1)
        #expect(plan.matchedFiles.isEmpty)
    }

    @Test("a config shape this app will not rewrite comes back explained, with no text to write")
    func planExplainsAnUnsupportedConfigShape() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                key_groups:
                  - age:
                      - \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public])

        #expect(plan.configRefusal?.contains("key_groups") == true)
        #expect(!plan.configNeedsWriting)
        #expect(applier.writeConfig(plan) == .nothingToWrite)
        // The rule was still identified, so the file list is still useful.
        #expect(plan.matchedFiles.map(\.lastPathComponent) == ["secret.yaml"])
    }
}

@Suite("ProjectRecipientApplier — a project-wide run covers every format, not just YAML")
struct ProjectRecipientApplierMixedFormatTests {

    /// Task 7 (SOPS-38): the TEMPORARY YAML-only filter in front of
    /// `plan.encryptedFiles` is gone, so `plan.filesInScope` now carries a
    /// dotenv file alongside a YAML one, each tagged with its own format —
    /// and `apply(files:...)` must re-wrap *both*, each through the bridge
    /// call for its own format.
    ///
    /// Deliberately checks the dotenv file's recipients specifically, not
    /// merely "some file changed": with the dotenv branch missing (i.e. the
    /// pre-Task-7 YAML-only scope), `plan.filesInScope` would carry only the
    /// YAML file, `apply` would never touch `.env`, and this assertion is the
    /// one that would catch it — `dotenvRecipients` would still be
    /// `[owner.public]`, never gaining `added.public`. This is the ablation
    /// the task brief names.
    @Test("a mixed YAML + dotenv project re-wraps both files for a staged recipient")
    func mixedProjectRewrapsBothFormats() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("mixed-format-apply")

        try """
            creation_rules:
              - path_regex: .*
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let yamlEncrypted = try SopsBridge.encrypt(
            applierPlainYAML, format: .yaml, recipients: [owner.public])
        let yamlURL = root.appendingPathComponent("secret.yaml")
        try yamlEncrypted.write(to: yamlURL, atomically: true, encoding: .utf8)

        let dotenvEncrypted = try SopsBridge.encrypt(
            "DB_PASSWORD=hunter2\n", format: .dotenv, recipients: [owner.public])
        let dotenvURL = root.appendingPathComponent(".env")
        try dotenvEncrypted.write(to: dotenvURL, atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public, added.public])

        #expect(plan.configError == nil)
        #expect(plan.configRefusal == nil)
        #expect(plan.filesInScope.count == 2)
        let scopedFormats = Set(plan.filesInScope.map(\.format))
        #expect(scopedFormats == Set([.yaml, .dotenv]))

        let run = await applier.apply(
            files: plan.filesInScope, recipients: [owner.public, added.public],
            agePrivateKey: owner.private)

        #expect(run.results.count == 2)
        #expect(run.results.allSatisfy { $0.outcome == .updated })
        #expect(run.results.filter { if case .failed = $0.outcome { true } else { false } }.isEmpty)

        // The YAML file really was re-wrapped for the new set — checked
        // through the engine, not by trusting the outcome enum.
        let yamlBytes = try String(contentsOf: yamlURL, encoding: .utf8)
        #expect(
            Set(try SopsBridge.recipients(in: yamlBytes, format: .yaml))
                == Set([owner.public, added.public]))
        #expect(
            try SopsBridge.decrypt(yamlBytes, format: .yaml, agePrivateKey: added.private)
                == applierPlainYAML)

        // The dotenv file, specifically — read and decrypted with its own
        // format, exactly what would fail to change if the dotenv branch
        // were missing from `filesInScope`.
        let dotenvBytes = try String(contentsOf: dotenvURL, encoding: .utf8)
        let dotenvRecipients = try SopsBridge.recipients(in: dotenvBytes, format: .dotenv)
        #expect(Set(dotenvRecipients) == Set([owner.public, added.public]))
        #expect(
            try SopsBridge.decrypt(dotenvBytes, format: .dotenv, agePrivateKey: added.private)
                == "DB_PASSWORD=hunter2\n")
    }
}

@Suite("ProjectRecipientApplier — writing the config is its own step")
struct ProjectRecipientApplierConfigWriteTests {

    @Test("writing a planned config update lands atomically and keeps the file's comments")
    func writesTheProposedConfig() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        let configURL = root.appendingPathComponent(".sops.yaml")
        try """
            # Team configuration
            creation_rules:
              - path_regex: .*\\.yaml$
                age:
                  - \(owner.public)

            """.write(to: configURL, atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public, added.public])
        #expect(plan.configNeedsWriting)

        #expect(applier.writeConfig(plan) == .written)

        let written = try String(contentsOf: configURL, encoding: .utf8)
        #expect(written.contains("# Team configuration"))
        #expect(written.contains(added.public))

        // And the config now really does resolve, through the engine, to the
        // new set for that file.
        let lookup = try SopsBridge.lookupCreationRule(
            configPath: configURL.path,
            targetFilePath: root.appendingPathComponent("secret.yaml").path)
        #expect(Set(lookup.ageRecipients) == Set([owner.public, added.public]))
    }

    @Test("a config changed since the plan read it is refused, not clobbered")
    func refusesAConfigChangedSinceThePlan() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        let configURL = root.appendingPathComponent(".sops.yaml")
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age:
                  - \(owner.public)

            """.write(to: configURL, atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(
            to: root.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public, added.public])
        #expect(plan.configNeedsWriting)

        // Somebody else edits .sops.yaml — a `git pull`, another window, a
        // colleague's `sops` run — after the plan was made.
        let theirVersion = "# somebody else got here first\ncreation_rules: []\n"
        try theirVersion.write(to: configURL, atomically: true, encoding: .utf8)

        guard case .failed(let reason) = applier.writeConfig(plan) else {
            Issue.record("expected the stale write to be refused")
            return
        }
        #expect(reason.contains("changed on disk"))
        #expect(try String(contentsOf: configURL, encoding: .utf8) == theirVersion)
    }
}

@Suite("ProjectRecipientApplier — which rule gets targeted is not up to the filesystem")
struct ProjectRecipientApplierOrderingTests {

    /// I1. `ProjectScanner` yields files in `FileManager.enumerator` order,
    /// which on APFS is directory-hash order — not alphabetical, and not
    /// stable across adding or deleting an unrelated file. The plan picks the
    /// *first* encrypted file to resolve which creation rule it is about, so
    /// an unsorted list meant a multi-rule project targeted whichever file the
    /// filesystem happened to hand back first. For an action that rewrites who
    /// a project encrypts for, that has to be predictable, and it has to be
    /// the same order the user already sees in the file list
    /// (`FileListModel.refresh` sorts by project-relative path).
    @Test("the plan targets the rule of the first file in the order the user sees, whatever the filesystem says")
    func targetFileFollowsTheDisplayedOrder() async throws {
        let alpha = try AgeKeyPair.generate()
        let zulu = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()

        // Two rules. Whichever file is picked as the target decides which of
        // them the panel is about, and the two declare different keys, so the
        // choice is directly observable.
        try """
            creation_rules:
              - path_regex: zulu/.*\\.yaml$
                age: \(zulu.public)
              - path_regex: alpha/.*\\.yaml$
                age: \(alpha.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        // Created zulu-first, so a scan that simply reports creation or
        // enumeration order has every chance of yielding zulu first.
        for (directory, key) in [("zulu", zulu), ("alpha", alpha)] {
            let dir = root.appendingPathComponent(directory, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [key.public])
            try encrypted.write(
                to: dir.appendingPathComponent("secret.yaml"), atomically: true, encoding: .utf8)
        }

        let plan = await ProjectRecipientApplier().plan(projectRoot: root, recipients: [])

        // "alpha/secret.yaml" sorts before "zulu/secret.yaml", so that is the
        // file the user sees first and the rule the panel must be about.
        #expect(plan.encryptedFiles.map { $0.lastPathComponent } == ["secret.yaml", "secret.yaml"])
        #expect(plan.encryptedFiles.first?.path.contains("/alpha/") == true)
        #expect(plan.targetFile?.path.contains("/alpha/") == true)
        #expect(plan.configRecipients == [alpha.public])
        #expect(plan.matchedFiles.count == 1)
        #expect(plan.matchedFiles.first?.path.contains("/alpha/") == true)
        #expect(plan.unmatchedFiles.first?.path.contains("/zulu/") == true)
    }

    @Test("every file list a plan reports is in project-relative path order")
    func everyReportedListIsSorted() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        for name in ["zzz.yaml", "mmm.yaml", "aaa.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // ...and one in a subdirectory, so the comparison is on the whole
        // relative path rather than the file name.
        let nested = root.appendingPathComponent("bbb", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try encrypted.write(
            to: nested.appendingPathComponent("aaa.yaml"), atomically: true, encoding: .utf8)

        let plan = await ProjectRecipientApplier().plan(projectRoot: root, recipients: [owner.public])

        // `$TMPDIR` is reached through the `/var` → `/private/var` symlink, so
        // the scan's URLs are standardized and the fixture root's is not —
        // strip against the standardized form, or every path keeps a
        // `/private` stub and the comparison is about the wrong thing.
        let base = root.standardizedFileURL.path + "/"
        let relative = plan.encryptedFiles.map {
            $0.standardizedFileURL.path.replacingOccurrences(of: base, with: "")
        }
        #expect(relative == ["aaa.yaml", "bbb/aaa.yaml", "mmm.yaml", "zzz.yaml"])
        #expect(plan.matchedFiles == plan.encryptedFiles)
        #expect(plan.filesInScope.map(\.url) == plan.encryptedFiles)
        #expect(plan.filesInScope.allSatisfy { $0.format == .yaml })
    }
}

@Suite("ProjectRecipientApplier — a fingerprint it could not take is never treated as consent")
struct ProjectRecipientApplierMissingFingerprintTests {

    /// M6. `applyToOne` takes the fingerprint *before* the read and hands it to
    /// `AtomicFileWriter.write(expecting:)`. A `nil` there does not mean "check
    /// anyway with no expectation" — it **disables** the changed-since-read
    /// check outright (`AtomicFileWriter.swift`), so the one file whose
    /// fingerprint could not be taken is the one file this app would clobber
    /// unconditionally. `RecipientAccessModel.load()` refuses the analogous
    /// state; this had no guard at all.
    ///
    /// The seam stands in for the real window — the file appearing between the
    /// fingerprint call and the read — which cannot be produced on demand.
    @Test("a file that reads fine but yields no fingerprint is refused, not written")
    func aMissingFingerprintRefusesTheWrite() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("applier-no-fingerprint")
        let file = root.appendingPathComponent("a.yaml")
        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        try encrypted.write(to: file, atomically: true, encoding: .utf8)

        nonisolated(unsafe) var writes = 0
        let applier = ProjectRecipientApplier(
            fingerprintFile: { _ in nil },
            writeFile: { contents, url, expecting in
                writes += 1
                try AtomicFileWriter.write(contents, to: url, expecting: expecting)
            })

        let outcome = await applier.apply(
            files: yamlScoped([file]), recipients: [owner.public, added.public],
            agePrivateKey: owner.private)

        guard case .failed(let reason) = outcome.results[0].outcome else {
            Issue.record("expected a refusal, got \(outcome.results[0].outcome)")
            return
        }
        #expect(reason.contains("changed while it was being read"))
        #expect(writes == 0, "the write must not be reached at all, let alone reached unguarded")
        #expect(try String(contentsOf: file, encoding: .utf8) == encrypted)
    }

    /// The complement, so the guard cannot be satisfied by refusing everything:
    /// a file with no fingerprint *and* no file on disk is the ordinary
    /// missing-file path, and still reports the read failure it always did.
    @Test("a file that is genuinely absent still reports the read failure")
    func anAbsentFileStillReportsTheReadFailure() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("applier-absent")
        let missing = root.appendingPathComponent("gone.yaml")

        let applier = ProjectRecipientApplier()
        let outcome = await applier.apply(
            files: yamlScoped([missing]), recipients: [owner.public], agePrivateKey: owner.private)

        guard case .failed(let reason) = outcome.results[0].outcome else {
            Issue.record("expected a failure, got \(outcome.results[0].outcome)")
            return
        }
        #expect(reason.contains("could not be read"))
    }
}

@Suite("ProjectRecipientApplier — one file reached by two names is still one file")
struct ProjectRecipientApplierAliasTests {

    /// F2. `ProjectScanner` reports a symlink to a regular file as a file in
    /// its own right — deliberately, because from the project's point of view
    /// it is one — so a project holding both a symlink and its target hands
    /// the plan two URLs for one inode. Both resolve to the same
    /// `ruleMatchingPath`, and everything downstream counts them twice: the
    /// number of files on the panel, the number in the destructive
    /// confirmation, and the per-file result table, which shows the same file
    /// twice with two different outcomes.
    @Test("a symlink and its target are planned as one file, under the name that is the file")
    func anAliasedFileIsPlannedOnce() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("alias-plan")
        defer { try? FileManager.default.removeItem(at: root) }

        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("db.yaml")
        try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
            .write(to: target, atomically: true, encoding: .utf8)
        // Sorts *before* "db.yaml", so a plan that simply keeps the first of
        // the two keeps the alias — which is the wrong one of the two names to
        // keep, and the assertion below is what pins that.
        let alias = root.appendingPathComponent("alias.yaml")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let plan = await ProjectRecipientApplier().plan(projectRoot: root, recipients: [owner.public])

        #expect(plan.encryptedFiles.count == 1)
        #expect(plan.encryptedFiles.first?.lastPathComponent == "db.yaml")
        #expect(plan.matchedFiles.count == 1)
        #expect(plan.filesInScope.count == 1)
        #expect(plan.targetFile?.lastPathComponent == "db.yaml")
        // F3. The scan found two names for one file; the count a caller sees
        // in `encryptedFiles.count` is already collapsed, and this is the one
        // field that says by how much — what lets a caller disclose the
        // collapse instead of leaving it invisible.
        #expect(plan.duplicateFileNameCount == 1)
    }

    /// The other half of F3's field: a project with no aliasing reports zero,
    /// so a panel reading this field never discloses a collapse that never
    /// happened.
    @Test("a project with no aliased files reports zero collapsed names")
    func noAliasingReportsZero() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("no-alias-plan")
        defer { try? FileManager.default.removeItem(at: root) }

        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let encrypted = try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
        for name in ["a.yaml", "b.yaml"] {
            try encrypted.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }

        let plan = await ProjectRecipientApplier().plan(projectRoot: root, recipients: [owner.public])

        #expect(plan.encryptedFiles.count == 2)
        #expect(plan.duplicateFileNameCount == 0)
    }

    /// And the consequence the plan's count exists to prevent: a run over the
    /// planned scope reports one row per file, not one per name. Before the
    /// deduplication this produced `[.updated, .unchanged]` — the second name
    /// arriving at a file the first had already re-wrapped — so a user was
    /// told a file they do not have was left alone.
    @Test("a run over the planned scope reports the aliased file once")
    func anAliasedFileIsAppliedOnce() async throws {
        let owner = try AgeKeyPair.generate()
        let added = try AgeKeyPair.generate()
        let root = try applierScratchDirectory("alias-apply")
        defer { try? FileManager.default.removeItem(at: root) }

        try """
            creation_rules:
              - path_regex: .*\\.yaml$
                age: \(owner.public)

            """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let target = root.appendingPathComponent("db.yaml")
        try SopsBridge.encrypt(applierPlainYAML, format: .yaml, recipients: [owner.public])
            .write(to: target, atomically: true, encoding: .utf8)
        let alias = root.appendingPathComponent("alias.yaml")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)

        let applier = ProjectRecipientApplier()
        let plan = await applier.plan(projectRoot: root, recipients: [owner.public, added.public])
        let run = await applier.apply(
            files: plan.filesInScope, recipients: [owner.public, added.public],
            agePrivateKey: owner.private)

        #expect(run.results.count == 1)
        #expect(run.results.first?.outcome == .updated)
        #expect(run.unchangedCount == 0)
        #expect(run.results.filter { if case .failed = $0.outcome { true } else { false } }.count == 0)

        // The alias is still an alias: nothing here replaced a symlink with a
        // copy of what it pointed at.
        let kind = try FileManager.default.attributesOfItem(atPath: alias.path)[.type] as? FileAttributeType
        #expect(kind == .typeSymbolicLink)
    }
}
