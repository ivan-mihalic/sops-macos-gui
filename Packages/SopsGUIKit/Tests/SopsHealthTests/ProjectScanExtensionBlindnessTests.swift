import Foundation
import ScratchCleanup
import Testing
import SopsEngine
@testable import SopsHealth

/// Task 1b review, Finding 2: the pinning test added for Step 1 of the
/// brief only ever named its encrypted fixtures `secret*.yaml` — so an
/// extension allowlist quietly grafted onto `classify` (the exact change
/// PROPOSAL §3 and the task brief forbid, because it reopens the blind spot
/// that once made a stale-key `.hidden-secrets.yaml` invisible) would pass
/// every test in the suite. A safety net nobody has ever seen catch
/// anything is not a safety net.
///
/// This file is that missing net: a sops-encrypted file whose name carries
/// no signal at all — no `.yaml`, no `.json`, nothing an allowlist would
/// recognise — genuinely encrypted with the real `sops` binary (not the
/// in-process bridge, and not a hand-typed fixture), asserted found. See
/// this file's own test for the transcript proving the net actually catches
/// a reintroduced allowlist, and reverting it.
@Suite("extension-blind coverage")
struct ProjectScanExtensionBlindnessTests {

    @Test("a genuinely sops-encrypted file with a name that carries no extension signal at all is still found")
    func extensionlessSopsFileIsFound() async throws {
        let key = try realAgeKeyPair()

        let plainPath = try writeTempFile(name: "plain.yaml", contents: "db_password: hunter2\n")
        let encrypted = try runSopsCLI(
            ["--encrypt", "--input-type", "yaml", "--output-type", "yaml", "--age", key.public, plainPath],
            identity: key)

        // Sanity: this really is a genuine sops file, not an empty string
        // from a silently-failing CLI call.
        #expect(encrypted.contains("sops:"))
        #expect(!encrypted.contains("hunter2"))

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // No extension, no recognisable pattern — the exact shape an
        // extension allowlist would miss and PROPOSAL §3's "by sops
        // metadata sniffing" exists to still catch.
        let fileURL = root.appendingPathComponent("weird-name-no-extension")
        try encrypted.write(to: fileURL, atomically: true, encoding: .utf8)

        let tree = await ProjectScanner.scan(root: root)

        #expect(tree.encrypted.count == 1, "an extensionless sops-encrypted file was not found")
        #expect(tree.plaintextCandidates.isEmpty)
        #expect(tree.encrypted.first?.tail.contains("hunter2") == false,
                "the plaintext value must never reach SniffedFile.tail even incidentally")
    }
}

// MARK: - Real-binary helpers, self-contained to this file (mirrors ProjectScanBOMTests).

private struct RealAgeKey {
    let `public`: String
    let `private`: String
}

private func realAgeKeyPair() throws -> RealAgeKey {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/age-keygen")
    let stdout = Pipe()
    process.standardOutput = stdout
    try process.run()
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)

    var pub = "", priv = ""
    for line in output.split(separator: "\n") {
        if line.hasPrefix("# public key: ") {
            pub = String(line.dropFirst("# public key: ".count))
        } else if line.hasPrefix("AGE-SECRET-KEY-") {
            priv = String(line)
        }
    }
    guard !pub.isEmpty, !priv.isEmpty else {
        throw NSError(domain: "ProjectScanExtensionBlindnessTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "age-keygen produced no usable key pair"])
    }
    return RealAgeKey(public: pub, private: priv)
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ext-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(dir)
    return dir
}

private func writeTempFile(name: String, contents: String) throws -> String {
    let dir = try makeTempDir()
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

/// Drives the real `sops` binary — the compatibility oracle, not the
/// in-process bridge. `SOPS_AGE_KEY_FILE` keeps the developer's own
/// `~/.config/sops` keys out of the test.
private func runSopsCLI(_ args: [String], identity: RealAgeKey) throws -> String {
    let keyPath = try writeTempFile(name: "keys.txt", contents: identity.private + "\n")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/sops")
    process.arguments = args
    process.environment = ProcessInfo.processInfo.environment.merging(
        ["SOPS_AGE_KEY_FILE": keyPath]) { _, new in new }

    let stdout = Pipe(), stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        throw NSError(domain: "ProjectScanExtensionBlindnessTests", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey:
                "sops \(args.joined(separator: " ")) exited \(process.terminationStatus): "
                + String(decoding: errData, as: UTF8.self),
        ])
    }
    return String(decoding: outData, as: UTF8.self)
}
