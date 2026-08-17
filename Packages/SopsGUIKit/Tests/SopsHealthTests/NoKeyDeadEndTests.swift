import Foundation
import Testing
@testable import SopsHealth

private struct EmptyKeyStore: KeyStoreStatusProviding { let state = KeyStoreState.empty }
private struct AvailableBiometry: BiometryStatusProviding { let state = BiometryState.available }
private struct CurrentUpdates: AppUpdateStatusProviding { let state = AppUpdateState.upToDate(version: "1.0.0") }
private struct EnforcedTTL: SessionTTLStatusProviding { let state = SessionTTLState.enforced(minutes: 15) }

/// A user with no age key at all has to be told how to get one.
///
/// This is the first thing a new install shows — `security.keystore` is
/// `.problem` until a key is imported, which for someone who has just
/// downloaded the app is every single time. The remediation said "Import an
/// existing age key in Settings › Key", which answers *where to put one* and
/// not *how to have one*. Someone who has never run `age-keygen` is finished
/// at that point, and this app cannot generate a key for them.
///
/// The inconsistency is the argument. Every other finding in this report that
/// says "you need X" hands over a command: `brew install sops`,
/// `brew upgrade yq`, `chmod 600 …`. The app's own stated remediation shape is
/// "an explanation plus a string the user can copy" (`CLAUDE.md`). The one
/// finding standing between a new user and using the app at all was the one
/// that offered nothing to copy.
@Suite("A user with no key is told how to get one")
struct NoKeyDeadEndTests {

    private func emptyKeyStoreFinding() async throws -> HealthFinding {
        let findings = await SecurityPostureCheck(
            osVersion: SemanticVersion(26, 5, 2),
            minimumOSVersion: SemanticVersion(14, 0, 0),
            keyStore: EmptyKeyStore(),
            biometry: AvailableBiometry(),
            appUpdates: CurrentUpdates(),
            legacyKeyFilePaths: ["/nonexistent/keys.txt"],
            sessionTTL: EnforcedTTL()
        ).run()
        return try #require(findings.first { $0.id == "security.keystore" })
    }

    @Test("the finding offers a command that creates a key")
    func offersAKeygenCommand() async throws {
        let remediation = try #require(try await emptyKeyStoreFinding().remediation)
        let command = try #require(remediation.command, Comment(rawValue: """
            The no-key finding offers no command. It is the first red item a new install \
            shows and the app cannot generate a key itself, so a user who has never run \
            age-keygen has nowhere to go — while every other "you need X" finding in this \
            same report hands over something to copy.
            """))
        #expect(command.contains("age-keygen"))
    }

    /// The command alone would be a puzzle: it prints two lines and only one
    /// of them is the thing to paste. The explanation has to say which.
    @Test("the explanation says what to do with what the command prints")
    func explanationNamesWhatToPaste() async throws {
        let explanation = try await emptyKeyStoreFinding().remediation?.explanation ?? ""
        #expect(explanation.contains("AGE-SECRET-KEY-1"), Comment(rawValue: """
            The explanation does not say which of age-keygen's two output lines is the one \
            to paste. Explanation was: \(explanation)
            """))
    }

    /// Still true, and still the first thing offered — someone who already has
    /// a key should not have to read past a generation recipe to find that
    /// out.
    @Test("importing an existing key is still what it leads with")
    func importStaysFirst() async throws {
        let explanation = try await emptyKeyStoreFinding().remediation?.explanation ?? ""
        let importAt = try #require(explanation.range(of: "Import")?.lowerBound)
        let keygenAt = try #require(explanation.range(of: "age-keygen")?.lowerBound)
        #expect(importAt < keygenAt)
    }
}
