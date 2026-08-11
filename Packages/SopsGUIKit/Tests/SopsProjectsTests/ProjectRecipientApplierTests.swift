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

        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])

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
            files: [first, unreadable, malformed, last],
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
            #expect(Set(try SopsBridge.recipients(in: bytes)) == Set([owner.public, added.public]))
            #expect(try SopsBridge.decryptYAML(bytes, agePrivateKey: added.private) == applierPlainYAML)
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

        let encrypted = try SopsBridge.encryptYAML(
            applierPlainYAML, recipients: [owner.public, other.public])
        let url = root.appendingPathComponent("secret.yaml")
        try encrypted.write(to: url, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: url, encoding: .utf8)

        let tally = CallTally()
        let applier = ProjectRecipientApplier(
            writeFile: { _, _, _ in tally.record("write") },
            rewrapRecipients: { _, _, _ in
                tally.record("rewrap")
                return ""
            })

        // Same members, opposite order: still nothing to do.
        let outcome = await applier.apply(
            files: [url], recipients: [other.public, owner.public], agePrivateKey: owner.private)

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

        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
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
            readRecipients: { contents in
                tally.record("read")
                if tally.count("read") == 1 {
                    mayFinish.wait()
                }
                return try SopsBridge.recipients(in: contents)
            })

        let files_ = files
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

        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
        let contended = root.appendingPathComponent("a-contended.yaml")
        let quiet = root.appendingPathComponent("b-quiet.yaml")
        try encrypted.write(to: contended, atomically: true, encoding: .utf8)
        try encrypted.write(to: quiet, atomically: true, encoding: .utf8)

        // A real second writer, landing between this applier's read and its
        // write: the rewrap seam does the real work and then somebody else
        // replaces the file underneath it.
        let applier = ProjectRecipientApplier(
            rewrapRecipients: { contents, recipients, key in
                let out = try SopsBridge.updateRecipients(contents, to: recipients, agePrivateKey: key)
                if contents == encrypted, FileManager.default.fileExists(atPath: contended.path) {
                    // Only interfere with the first file.
                    let marker = try SopsBridge.encryptYAML(
                        "database:\n    password: somebody-elses-write\n", recipients: [owner.public])
                    try? marker.write(to: contended, atomically: true, encoding: .utf8)
                }
                return out
            })

        let outcome = await applier.apply(
            files: [contended, quiet], recipients: [owner.public, added.public],
            agePrivateKey: owner.private)

        guard case .failed(let reason) = outcome.results[0].outcome else {
            Issue.record("expected the contended file to be refused, got \(outcome.results[0].outcome)")
            return
        }
        #expect(reason.contains("changed on disk"))
        // The second writer's version survived — it was not clobbered.
        #expect(try SopsBridge.decryptYAML(
            String(contentsOf: contended, encoding: .utf8), agePrivateKey: owner.private)
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
        let foreign = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [stranger.public])
        let url = root.appendingPathComponent("foreign.yaml")
        try foreign.write(to: url, atomically: true, encoding: .utf8)

        let applier = ProjectRecipientApplier()
        let outcome = await applier.apply(
            files: [url], recipients: [owner.public], agePrivateKey: owner.private)

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
        let forOwner = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
        let forOther = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [other.public])
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

    @Test("a project with no .sops.yaml plans without a config and without failing")
    func planWithoutAConfig() async throws {
        let owner = try AgeKeyPair.generate()
        let root = try applierScratchDirectory()
        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
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
        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
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
        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
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
        let encrypted = try SopsBridge.encryptYAML(applierPlainYAML, recipients: [owner.public])
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
