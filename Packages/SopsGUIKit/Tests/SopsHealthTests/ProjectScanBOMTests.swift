import Foundation
import ScratchCleanup
import Testing
import SopsEngine
@testable import SopsHealth

/// Task 1b review, Finding 1: a UTF-8 BOM at the very start of a file broke
/// `ProjectScanner.classify`'s byte-level `sops:` prefix probe.
///
/// The pre-parallelisation implementation decoded the tail to a `String`
/// first (`String(data:encoding:.utf8)`), which silently strips a leading
/// BOM as part of decoding — so `tail.hasPrefix("sops:")` was always
/// matching an already-debommed string without anyone writing BOM-handling
/// code on purpose. The byte-level replacement, `tail.starts(with:
/// sopsBlockPrefix)`, does no such thing: it compares raw bytes, so a
/// `EF BB BF` prefix silently defeats it.
///
/// This is reachable, not theoretical: `sops -e` on an empty YAML document
/// (`{}`) produces a file whose *entire* content is the `sops:` metadata
/// block, starting at byte 0 — there is no `\nsops:` substring anywhere in
/// it, which is exactly why `classify` has a `starts(with:)` branch at all,
/// separate from the substring one. An editor round-trip is enough to add a
/// BOM to such a file, and the real `sops` CLI decrypts the BOM-prefixed
/// version identically to the original — proven below by actually running
/// it, not assumed.
///
/// Built entirely against the real `sops`/`age-keygen` binaries
/// (`/opt/homebrew/bin`), the same convention `ProjectHealthCheckRealBridgeTests`
/// and the `SopsEngineTests` compatibility suite use — a hand-typed fixture
/// string would not have caught this, since the bug is specifically about
/// what the real serializer emits at byte 0.
@Suite("BOM-prefixed sops files")
struct ProjectScanBOMTests {

    @Test("a BOM-prefixed sops file whose content starts with sops: at byte 0 is still found by the scanner, and still decrypts with the real CLI")
    func bomPrefixedEmptyDocumentIsFoundAndStillDecrypts() throws {
        let key = try realAgeKeyPair()

        let plainPath = try writeTempFile(name: "empty.yaml", contents: "{}\n")
        let encrypted = try runSopsCLI(
            ["--encrypt", "--age", key.public, plainPath], identity: key)

        // Sanity: this is genuinely the shape the review describes, not an
        // assumption. If a future sops version changes this, this test
        // should fail loudly here rather than silently stop testing what it
        // claims to.
        #expect(encrypted.hasPrefix("sops:"), "test setup bug: expected sops: at byte 0 of an empty-document encryption")
        // Over *bytes*, exactly as `ProjectScanner.sopsBlockMarker` searches.
        // The Swift `String.contains("\nsops:")` this used to be is the Task 1b
        // idiom itself: `"\r\n"` is one `Character`, so on a CRLF document the
        // substring is not present and the precondition passed without
        // establishing anything. Production would have found it; this would
        // not have noticed.
        #expect(Data(encrypted.utf8).range(of: Data("\nsops:".utf8)) == nil,
                "test setup bug: expected no \\nsops: byte sequence anywhere in an empty-document encryption")

        var bomPrefixed = Data([0xEF, 0xBB, 0xBF])
        bomPrefixed.append(Data(encrypted.utf8))

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // `.yaml` on purpose: this test isolates the BOM question from
        // extension-based format detection, which `sops --decrypt` needs
        // (via the extension or an explicit `--input-type`/`--output-type`)
        // and which is a separate concern covered by
        // `ProjectScanExtensionBlindnessTests.extensionlessSopsFileIsFound`.
        let fileURL = root.appendingPathComponent("weird-name.yaml")
        try bomPrefixed.write(to: fileURL)

        // Still genuinely decryptable — the file is valid sops output with
        // or without the BOM, so this app's scanner must find it either way.
        let decrypted = try runSopsCLI(["--decrypt", fileURL.path], identity: key)
        #expect(decrypted.trimmingCharacters(in: .whitespacesAndNewlines) == "{}")
    }

    /// Same file as above, run through `ProjectScanner.scan(root:)` directly
    /// — the regression this finding is actually about. Split from the CLI
    /// round-trip test above so a scanner regression and a real-CLI
    /// incompatibility fail with two distinct, unambiguous messages instead
    /// of one test that could fail for either reason.
    @Test("ProjectScanner finds a BOM-prefixed sops file with sops: at byte 0")
    func scannerFindsBOMPrefixedFile() async throws {
        let key = try realAgeKeyPair()

        let plainPath = try writeTempFile(name: "empty.yaml", contents: "{}\n")
        let encrypted = try runSopsCLI(
            ["--encrypt", "--age", key.public, plainPath], identity: key)

        var bomPrefixed = Data([0xEF, 0xBB, 0xBF])
        bomPrefixed.append(Data(encrypted.utf8))

        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("weird-name.yaml")
        try bomPrefixed.write(to: fileURL)

        let tree = await ProjectScanner.scan(root: root)

        #expect(tree.encrypted.count == 1, "the BOM-prefixed sops file was not found")
        #expect(tree.plaintextCandidates.isEmpty, "a genuinely encrypted file must never be misreported as a plaintext leak")
        // Compared by resolved path, not raw `URL` equality: `FileManager`'s
        // enumerator can return a symlink-resolved path (e.g. macOS's
        // /var -> /private/var temp-directory symlink) that is not
        // string-identical to the URL this test built, even though both name
        // the same file on disk.
        #expect(tree.encrypted.first?.url.resolvingSymlinksInPath().path == fileURL.resolvingSymlinksInPath().path)
    }
}

// MARK: - Real-binary helpers, self-contained to this file.

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
        throw NSError(domain: "ProjectScanBOMTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "age-keygen produced no usable key pair"])
    }
    return RealAgeKey(public: pub, private: priv)
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bom-" + UUID().uuidString)
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
        throw NSError(domain: "ProjectScanBOMTests", code: Int(process.terminationStatus), userInfo: [
            NSLocalizedDescriptionKey:
                "sops \(args.joined(separator: " ")) exited \(process.terminationStatus): "
                + String(decoding: errData, as: UTF8.self),
        ])
    }
    return String(decoding: outData, as: UTF8.self)
}
