import Foundation
import ScratchCleanup
import Testing
import SopsEngine
import SopsHealth
import SopsProjects
@testable import SopsUI

// MARK: - Fixture plumbing
//
// Only the "no message ever names the sentinel value" test needs a real
// failure produced by the real creation pipeline — every other test in this
// file constructs the four consumed enums directly, because none of their
// cases carry anything but a path, an errno-derived reason, or the bridge's
// own diagnostic text (see each type's own doc comment). Mirrors the
// per-file `AgeKeyPair`/`scratchDirectory` pattern `RecipientAccessTests.swift`
// and `SecretFileCreatorTests.swift` both already use — shelling out to
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

private func scratchDirectory(_ label: String = "creation-failure-presenter") throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(label)-" + UUID().uuidString)
    ScratchDirectoryRegistry.shared.register(dir)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func makeProject() throws -> URL {
    let root = try scratchDirectory()
    let project = root.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    return project
}

/// Recognisable value planted wherever a fixture in this file builds a
/// document — the same technique, and the same string,
/// `SecretFileCreatorTests.sentinelValue` uses for the identical purpose.
private let sentinelValue = "correct-horse-battery-staple"

@Suite("CreationFailurePresenter")
struct CreationFailurePresenterTests {

    // MARK: - Exhaustiveness: every case of every consumed type
    //
    // ⚠️ Every array below is a manual, hand-maintained list — it goes stale
    // silently the moment a case is added to any of the four enums this
    // presenter consumes. The list is not what catches that: adding a case
    // to `SecretFileCreator.Failure` (or any of the other three) breaks the
    // `switch` with no `default` in `CreationFailurePresenter.swift`, which
    // fails the *build*, not this test. Verified directly: temporarily
    // adding `case bogus` to `SecretFileCreator.Failure` makes
    // `CreationFailurePresenter.swift`'s `switch` over it stop compiling,
    // with a "switch must be exhaustive" diagnostic pointing at the new
    // case. These lists exist only to pin the *text* for cases that do
    // exist; completeness is the compiler's job.

    @Test("every SecretFileCreator failure has a message that names something actionable")
    func everyCreatorFailureIsPresented() {
        let all: [SecretFileCreator.Failure] = [
            .destinationExists(path: "/p/a.yaml"),
            .destinationOutsideProject(path: "/p/../x.yaml"),
            .roundTripMismatch,
            .wouldBeUnreadable,
            .engine("bridge text"),
            .couldNotCreateDirectory(path: "/p/secrets", reason: "Permission denied"),
            .write(.destinationExists(path: "/p/a.yaml")),
        ]
        for failure in all {
            let message = CreationFailurePresenter.message(for: failure)
            #expect(!message.detail.isEmpty, "\(failure) produced an empty detail")
        }
    }

    @Test("every CreationPlanResolver error has a message that names something actionable")
    func everyPlanResolverErrorIsPresented() {
        let all: [CreationPlanResolver.Error] = [
            .targetNotAbsolute("relative/path.yaml"),
            .projectRootNotAbsolute("relative/root"),
            .projectRootDoesNotExist("/gone"),
            .targetOutsideProjectRoot("/elsewhere/secret.yaml"),
        ]
        for error in all {
            let message = CreationFailurePresenter.message(for: error)
            #expect(!message.detail.isEmpty, "\(error) produced an empty detail")
        }
    }

    @Test("every SopsConfigGenerator error has a message that names something actionable")
    func everyConfigGeneratorErrorIsPresented() {
        let all: [SopsConfigGenerator.Error] = [
            .targetNotAbsolute("relative/path.yaml"),
            .projectRootNotAbsolute("relative/root"),
            .projectRootDoesNotExist("/gone"),
            .targetOutsideProjectRoot("/elsewhere/secret.yaml"),
        ]
        for error in all {
            let message = CreationFailurePresenter.message(for: error)
            #expect(!message.detail.isEmpty, "\(error) produced an empty detail")
        }
    }

    @Test("every DotEnvParseFailure has a message that names something actionable")
    func everyDotEnvFailureIsPresented() {
        let all: [DotEnvParseFailure] = [.notUTF8]
        for failure in all {
            let message = CreationFailurePresenter.message(for: failure)
            #expect(!message.detail.isEmpty, "\(failure) produced an empty detail")
        }
    }

    // MARK: - Phase 1 findings, pinned

    @Test("a round-trip refusal does not tell the user their document is corrupted")
    func roundTripMismatchDoesNotClaimCorruption() {
        let message = CreationFailurePresenter.message(for: .roundTripMismatch)
        let text = message.detail.lowercased()
        #expect(!text.contains("corrupt"))
        #expect(!text.contains("damaged"))
    }

    @Test("a missing project root is not reported as a missing .sops.yaml")
    func missingRootIsNotMissingConfig() {
        let message = CreationFailurePresenter.message(
            for: CreationPlanResolver.Error.projectRootDoesNotExist("/gone"))
        #expect(!message.detail.contains(".sops.yaml"))
    }

    // MARK: - Bridge text passes through unchanged

    @Test("the bridge's own encryption diagnostic survives into the message verbatim")
    func engineTextPassesThroughUnchanged() {
        let message = CreationFailurePresenter.message(
            for: SecretFileCreator.Failure.engine("recipient 2: not a valid age recipient"))
        #expect(message.detail.contains("recipient 2: not a valid age recipient"))
    }

    // MARK: - Paths are actually surfaced, not swallowed

    @Test("path-bearing failures name the path in the message")
    func pathBearingFailuresNameThePath() {
        let destinationExists = CreationFailurePresenter.message(
            for: SecretFileCreator.Failure.destinationExists(path: "/p/a.yaml"))
        #expect(destinationExists.detail.contains("/p/a.yaml"))

        let outsideProject = CreationFailurePresenter.message(
            for: SecretFileCreator.Failure.destinationOutsideProject(path: "/p/../x.yaml"))
        #expect(outsideProject.detail.contains("/p/../x.yaml"))

        let missingRoot = CreationFailurePresenter.message(
            for: CreationPlanResolver.Error.projectRootDoesNotExist("/gone"))
        #expect(missingRoot.detail.contains("/gone"))

        let configMissingRoot = CreationFailurePresenter.message(
            for: SopsConfigGenerator.Error.projectRootDoesNotExist("/gone"))
        #expect(configMissingRoot.detail.contains("/gone"))
    }

    // MARK: - Recovery guidance

    @Test("every case offers recovery guidance except where nothing but a different attempt helps")
    func recoveryIsPresentExceptWhereDocumented() {
        // `.write` wraps `AtomicFileWriter.Error`, whose own `description` is
        // already a complete, situation-specific sentence — for several of
        // its cases it already states what to do (see that type's own
        // doc comment). A second, generic recovery key here would either
        // repeat it or contradict it depending on which case fired, so this
        // is the one documented `nil`.
        let write = CreationFailurePresenter.message(
            for: SecretFileCreator.Failure.write(.destinationExists(path: "/p/a.yaml")))
        #expect(write.recovery == nil)

        let others: [SecretFileCreator.Failure] = [
            .destinationExists(path: "/p/a.yaml"),
            .destinationOutsideProject(path: "/p/x.yaml"),
            .roundTripMismatch,
            .wouldBeUnreadable,
            .engine("bridge text"),
            .couldNotCreateDirectory(path: "/p/secrets", reason: "Permission denied"),
        ]
        for failure in others {
            #expect(
                CreationFailurePresenter.message(for: failure).recovery != nil,
                "\(failure) has no recovery")
        }
    }

    // MARK: - CreationPlan's two blocking outcomes
    //
    // Amendment to the plan (2026-08-13): the original brief's interface
    // list named four thrown `Error`/`Failure` types, but omitted
    // `CreationPlan` itself — even though `.unsupportedRule` and
    // `.configUnreadable` are exactly the same shape of "the wizard cannot
    // proceed" this presenter exists to voice, and both already carry
    // reason text this presenter must not re-derive (see
    // `CreationFailurePresenter.message(forBlocking:)`'s own doc comment).
    // `.noConfig`, `.noRuleMatched` and `.governedByRule` are not blocking —
    // see that method's own doc comment for why inventing a sentence for
    // either of the first two would be actively wrong, not just unhelpful.

    @Test("every CreationPlan case is covered, and only the two blocking ones produce a message")
    func everyCreationPlanCaseIsHandled() {
        let nonBlocking: [CreationPlan] = [
            .noConfig,
            .noRuleMatched,
            .governedByRule(recipients: ["age1exampleexampleexampleexampleexampleexampleexampleexample"], encryptedRegex: ""),
        ]
        for plan in nonBlocking {
            #expect(CreationFailurePresenter.message(forBlocking: plan) == nil, "\(plan) should not block")
        }

        let blocking: [CreationPlan] = [
            .unsupportedRule(reason: "some sentence naming pgp and what to do instead"),
            .configUnreadable(reason: "yaml: line 3: did not find expected key"),
        ]
        for plan in blocking {
            #expect(CreationFailurePresenter.message(forBlocking: plan) != nil, "\(plan) should block")
        }
    }

    /// Drives a real `.sops.yaml` with a `pgp:` rule through the real
    /// `CreationPlanResolver.plan(forTarget:in:)` — the same technique
    /// `CreationPlanResolverTests.unsupportedBackendNamesIt` uses — rather
    /// than constructing `.unsupportedRule` by hand, so this pins the same
    /// thing phase 1's own tests assert: the reason names the offending
    /// backend. This presenter must carry that name through, not paraphrase
    /// it away.
    @Test("an unsupported-rule message still names the backend phase 1 put in the reason")
    func unsupportedRuleNamesTheBackend() throws {
        let project = try makeProject()
        try """
            creation_rules:
              - path_regex: secrets/.*\\.yaml$
                pgp: 0000000000000000000000000000000000AAAA
            """.write(to: project.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let target = project.appendingPathComponent("secrets/prod.yaml")

        let plan = try CreationPlanResolver.plan(forTarget: target, in: project)
        guard case .unsupportedRule = plan else {
            Issue.record("expected .unsupportedRule, got \(plan)")
            return
        }
        let message = try #require(CreationFailurePresenter.message(forBlocking: plan), "expected a message")
        #expect(message.detail.contains("pgp"))
    }

    // MARK: - SessionKeyStore.state — a permanent refusal, not a thrown error

    @Test("every KeyStoreState is covered, and only .configured produces no message")
    func everyKeyStoreStateIsHandled() {
        #expect(CreationFailurePresenter.message(forEmptyKeyStore: .configured) == nil)

        let blocking: [KeyStoreState] = [.empty, .unavailable(reason: "Keychain key storage arrives in M3.")]
        for state in blocking {
            let message = CreationFailurePresenter.message(forEmptyKeyStore: state)
            #expect(message != nil, "\(state) should block")
        }
    }

    @Test(".unavailable's reason survives into the message, the same discipline .engine/.configUnreadable keep")
    func unavailableReasonIsCarriedThrough() throws {
        let message = try #require(
            CreationFailurePresenter.message(forEmptyKeyStore: .unavailable(reason: "Keychain key storage arrives in M3.")))
        #expect(message.detail.contains("Keychain key storage arrives in M3."))
    }

    // MARK: - Task 5 additions: config write failures, the unreachable
    // fallback, and a stale proposal — each asserted by name, not merely
    // exercised indirectly. `message(forUnreadableSourceFile:)` and
    // `message(forDotEnvWithNoUsableEntries:)` (Tasks 1/3) already get this
    // treatment one file over, in `NewSecretFileSheetTests.swift`, by
    // comparing a model's own stored error against the exact presenter
    // call — these three had no such comparison anywhere, which review
    // round 3 caught for two of them and asked to close for all three so
    // the next one doesn't reopen it.

    @Test("a .sops.yaml write failure carries AtomicFileWriter's own description into the message")
    func configWriteFailureCarriesTheWritersDescription() {
        let message = CreationFailurePresenter.message(
            forConfigWriteFailure: .destinationExists(path: "/p/.sops.yaml"))
        #expect(message.detail.contains("/p/.sops.yaml"))
        #expect(message.title == .creationFailureConfigTitle)
    }

    @Test("the unexpectedly-unblocked-plan fallback has non-empty text and no recovery to fabricate")
    func unexpectedlyUnblockedPlanFallbackHasText() {
        let message = CreationFailurePresenter.messageForUnexpectedlyUnblockedPlan()
        #expect(!message.detail.isEmpty)
        #expect(message.title == .creationFailureTitle)
    }

    @Test("a stale proposal's message tells the user to propose again, under the config title")
    func staleProposalMessageNamesTheRecovery() {
        let message = CreationFailurePresenter.messageForStaleProposal()
        #expect(message.detail.localizedCaseInsensitiveContains("propose again"))
        #expect(message.title == .creationFailureConfigTitle)
    }

    // MARK: - No secret value ever reaches a message
    //
    // Phase 1's own security test (`SecretFileCreatorTests
    // .noThrownErrorEverNamesTheSentinelValue`) proves the *enum cases*
    // never carry a document value. This test proves the same thing one
    // layer further out: it drives a real, failing `SecretFileCreator
    // .create` call whose document actually contains the sentinel, and
    // checks that the *message this presenter builds* — title, detail, and
    // recovery — still names none of it. `owner`'s key is deliberately not
    // among `plan.recipients`, so the round trip in step 3/6 fails and
    // `.wouldBeUnreadable` is thrown — the one failure shape that is only
    // reachable after the document (sentinel included) was actually built
    // and encrypted.
    @Test("no message from a real failed creation ever names the sentinel value")
    func noRealFailureMessageNamesTheSentinelValue() throws {
        let owner = try AgeKeyPair.generate()
        let stranger = try AgeKeyPair.generate()
        let project = try makeProject()
        let destination = project.appendingPathComponent("secret.yaml")

        let entries = [DotEnvEntry(key: "SECRET", value: sentinelValue, line: 1)]
        let plan = ResolvedEncryption(
            recipients: [stranger.public], encryptedRegex: "", acknowledgedUnreadable: false)

        do {
            _ = try SecretFileCreator.create(
                .dotEnv(entries), plan: plan, at: destination, in: project, sessionKey: owner.private)
            Issue.record("expected creation to fail: owner's key is not among the recipients")
        } catch let failure as SecretFileCreator.Failure {
            #expect(failure == .wouldBeUnreadable, "expected .wouldBeUnreadable, got \(failure)")
            let message = CreationFailurePresenter.message(for: failure)
            #expect(!message.detail.contains(sentinelValue))
            #expect(!message.title.text.contains(sentinelValue))
            #expect(!(message.recovery?.text.contains(sentinelValue) ?? false))
        }
    }
}
