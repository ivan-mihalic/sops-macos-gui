import Foundation
import Testing

@testable import SopsEngine

/// A malformed file must not be able to kill the app.
///
/// A Go panic reaching a `//export`ed bridge function does not unwind into
/// Swift. There is no C-level exception to catch: the Go runtime prints a
/// trace and calls `abort()`, so the *host process* dies and every unsaved
/// document in the editor goes with it — because one file on disk was
/// malformed.
///
/// It takes a one-word edit to get there. sops 3.13.3 panics on a value
/// declared `type:bytes`, and the declared type inside `ENC[…,type:…]` is not
/// covered by the GCM additional data (the AAD is the key path), so rewriting
/// `type:str` to `type:bytes` leaves the value authenticating perfectly and
/// detonating on decryption. A corrupt file, a bad merge, or one hostile
/// commit in a shared repository all get there.
///
/// These tests drive the real C symbols through the built xcframework. If the
/// guard in `Engine/cshim/main.go` is removed, they do not fail — the test
/// process aborts, which is exactly the user-facing behaviour being fixed.
/// `Engine/gobridge/enginefault_test.go` holds the Go-side reproduction, where
/// the crash is contained in a child process and reported as a failure.
struct HostileDocumentTests {

    /// Planted as a plaintext value in the hostile document. No error message
    /// may contain it: a `recover()` that formatted the panic value into its
    /// message would create the leak it exists to prevent.
    static let canary = "canary-8f2c11d0-must-never-appear-in-an-error"

    private struct Fixture {
        let identity: AgeKeyPair
        let healthy: String
        let hostile: String
    }

    private static func makeFixture() throws -> Fixture {
        let identity = try AgeKeyPair.generate()
        let healthy = try SopsBridge.encryptYAML(
            "alpha: \(canary)\nbeta: 42\n",
            recipients: [identity.public])
        let hostile = healthy.replacingOccurrences(
            of: ",type:str]", with: ",type:bytes]",
            options: [], range: healthy.range(of: ",type:str]"))
        guard hostile != healthy else {
            throw TestError("fixture unchanged: the encrypted document had no type:str value")
        }
        return Fixture(identity: identity, healthy: healthy, hostile: hostile)
    }

    /// The claim in one line: the process is still here to run the assertion.
    @Test func openingAHostileDocumentThrowsInsteadOfCrashing() throws {
        let fixture = try Self.makeFixture()

        #expect(throws: SopsBridgeError.self) {
            _ = try SopsBridge.decryptToRows(
                fixture.hostile, agePrivateKey: fixture.identity.private)
        }
    }

    /// Every read and write path reaches the same cipher, so every one of them
    /// has to be covered. A guard on the entry point the editor happens to
    /// call first would leave the save path live.
    @Test func everyDocumentEntryPointRefusesTheHostileFile() throws {
        let fixture = try Self.makeFixture()
        let key = fixture.identity.private

        let calls: [(String, () throws -> Any)] = [
            ("decryptToRows", { try SopsBridge.decryptToRows(fixture.hostile, agePrivateKey: key) }),
            ("decryptYAML", { try SopsBridge.decryptYAML(fixture.hostile, agePrivateKey: key) }),
            ("applyEdits", { try SopsBridge.applyEdits(fixture.hostile, edits: [], agePrivateKey: key) }),
            (
                "applyChanges",
                {
                    try SopsBridge.applyChanges(
                        fixture.hostile, changes: SecretChangeSet(), agePrivateKey: key)
                }
            ),
        ]

        for (name, call) in calls {
            do {
                let value = try call()
                Issue.record("\(name) returned \(value) for a document that faults the engine")
            } catch let error as SopsBridgeError {
                #expect(
                    error.description.contains("the sops engine faulted"),
                    "\(name): the failure is not distinguishable as an engine fault: \(error.description)"
                )
            }
        }
    }

    /// The constraint that makes this fix worth having. A panic payload can be
    /// any part of the document, so none of it may be interpolated into the
    /// message the UI renders and the crash reporter collects.
    @Test func theErrorNeverCarriesDocumentContent() throws {
        let fixture = try Self.makeFixture()

        do {
            _ = try SopsBridge.decryptToRows(
                fixture.hostile, agePrivateKey: fixture.identity.private)
            Issue.record("the hostile document did not fail")
        } catch let error as SopsBridgeError {
            #expect(!error.description.contains(Self.canary))
            // Even a fragment is too much — a message quoting half the canary
            // would still be quoting the document.
            #expect(!error.description.contains("canary"))
            #expect(!error.description.contains("8f2c11d0"))
        }
    }

    /// A recovered fault must not present as a document that simply had
    /// nothing in it: the editor would render an empty form the user could
    /// then save over their real file.
    @Test func aFaultIsNeverAnEmptyDocument() throws {
        let fixture = try Self.makeFixture()

        var rows: [SecretRow]?
        do {
            rows = try SopsBridge.decryptToRows(
                fixture.hostile, agePrivateKey: fixture.identity.private)
        } catch is SopsBridgeError {
            rows = nil
        }
        #expect(rows == nil, "a faulting document decoded to \(rows?.count ?? -1) rows")
    }

    /// The other half of "recovered". A recover that leaves the runtime wedged
    /// has only moved the outage from the first bad file to every file after
    /// it — which for this app is the same thing as crashing, one step later.
    @Test func theBridgeKeepsWorkingAfterAFault() throws {
        let fixture = try Self.makeFixture()
        let key = fixture.identity.private

        for round in 1...3 {
            #expect(throws: SopsBridgeError.self) {
                _ = try SopsBridge.decryptToRows(fixture.hostile, agePrivateKey: key)
            }

            let rows = try SopsBridge.decryptToRows(fixture.healthy, agePrivateKey: key)
            #expect(
                rows.contains { $0.value == Self.canary },
                "round \(round): a healthy document did not decrypt after a fault")

            // The write path too — it is the one that touches the user's file.
            let saved = try SopsBridge.applyEdits(
                fixture.healthy,
                edits: [SecretEdit(path: ["beta"], value: "43", kind: .int)],
                agePrivateKey: key)
            #expect(!saved.isEmpty, "round \(round): saving produced nothing after a fault")

            // And the entry points that share the runtime but not the document.
            #expect(
                !EngineVersion.sops.isEmpty,
                "round \(round): the engine stopped reporting its version")
        }
    }

    /// The guard must not blur the vocabulary the app already relies on: a
    /// wrong key is still reported as a wrong key, not as an engine defect.
    @Test func ordinaryFailuresAreStillReportedAsThemselves() throws {
        let fixture = try Self.makeFixture()
        let stranger = try AgeKeyPair.generate()

        do {
            _ = try SopsBridge.decryptToRows(fixture.healthy, agePrivateKey: stranger.private)
            Issue.record("decrypting with the wrong identity succeeded")
        } catch let error as SopsBridgeError {
            #expect(!error.description.contains("the sops engine faulted"))
            #expect(error.description.contains("none of the keys available to this app"))
        }
    }
}
