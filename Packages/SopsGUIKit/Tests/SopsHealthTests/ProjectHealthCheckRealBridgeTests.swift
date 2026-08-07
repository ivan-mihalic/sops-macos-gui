import Foundation
import Testing
import SopsEngine
@testable import SopsHealth

/// A hand-written fake of a format you do not control is how a parser passes
/// its tests and fails on real files. `ProjectHealthCheckTests.swift`'s
/// `encryptedFile(recipients:)` helper is exactly that kind of fake — useful
/// for fast, deterministic tests of the surrounding logic, but not proof the
/// parser understands what sops actually writes.
///
/// This file closes that gap: it encrypts with the real, in-process
/// `SopsBridge` (the same bridge the shipping app calls) and feeds the
/// genuine output straight to
/// `EncryptedFileMetadata.recipients(inEncryptedFile:)`. This is a separate
/// concern from `.sops.yaml` parsing (which is now delegated to
/// `SopsBridge.lookupCreationRule` — see `ProjectHealthCheck`'s doc comment)
/// — this reads an *encrypted file's own* metadata, a format sops itself
/// generates, not one a user hand-writes.
///
/// What this caught: the real output orders each age entry's fields as
/// `enc:` then `recipient:`; the hand-written fixture had them the other way
/// around. The parser tolerated it either way (it scans for any line whose
/// trimmed text starts with `recipient:`, independent of field order or
/// position within the entry), but the fixture was still wrong about what a
/// real file looks like, so it was corrected to match. Keep this test — it
/// is the one that would catch a real upstream metadata format change that a
/// hand-written fixture could never notice.
@Suite("ProjectHealthCheck against genuine sops output")
struct ProjectHealthCheckRealBridgeTests {

    @Test("EncryptedFileMetadata.recipients(inEncryptedFile:) reads the real recipients back out of a genuinely encrypted file")
    func recipientsRoundTripThroughTheRealBridge() throws {
        let key1 = try realAgePublicKey()
        let key2 = try realAgePublicKey()

        let encrypted = try SopsBridge.encryptYAML(
            "password: hunter2\napi_key: sk-live-abc123\n",
            recipients: [key1, key2])

        let recipients = EncryptedFileMetadata.recipients(inEncryptedFile: encrypted)

        #expect(Set(recipients) == Set([key1, key2]))
        // The parser must never surface the plaintext it was never given
        // reason to touch.
        #expect(!encrypted.contains("hunter2"))
    }
}

/// A real, freshly generated age public key — not a fixture. Every recipient
/// value in this file comes from `age-keygen`, never a hand-typed string.
private func realAgePublicKey() throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    for line in output.split(separator: "\n") where line.hasPrefix("# public key: ") {
        return String(line.dropFirst("# public key: ".count))
    }
    throw NSError(domain: "ProjectHealthCheckRealBridgeTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "age-keygen produced no public key line"])
}
