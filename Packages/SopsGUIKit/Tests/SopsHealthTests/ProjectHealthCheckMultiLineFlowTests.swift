import Foundation
import ScratchCleanup
import Testing
import SopsEngine
@testable import SopsHealth

private struct FakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

/// A real, freshly generated age public key — not a fixture.
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
    throw NSError(domain: "ProjectHealthCheckMultiLineFlowTests", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "age-keygen produced no public key line"])
}

/// End-to-end regression for the multi-line `age: [...]` bug: a project
/// whose `.sops.yaml` writes its recipient list as a flow sequence split
/// across lines — exactly the shape a real user reaches for once the list
/// gets long enough to wrap — genuinely and correctly encrypted to both of
/// those same real recipients via the real bridge.
///
/// This bug shipped twice against two different `.sops.yaml` parsers. A
/// hand-rolled Swift line scanner: the first physical line alone parsed as
/// a single recipient carrying a stray `[`, the second key was silently
/// dropped from the rule's expected set entirely, and the comparison
/// against the file's real (correct) recipient list produced three false
/// claims — the file "is encrypted to" both real keys (neither of which
/// was in the corrupted one-entry expected set) and a nonsensical "does
/// not list [k1 among its recipients". `.sops.yaml` parsing has since been
/// replaced with `SopsBridge.lookupCreationRule`, which delegates entirely
/// to sops's own config parser (see `ProjectHealthCheck`'s doc comment for
/// why) — this test now exercises that real parser and is kept as the
/// permanent regression guard for this exact shape, since it is the one
/// the old parser broke on twice.
@Suite("ProjectHealthCheck against a multi-line age flow sequence")
struct ProjectHealthCheckMultiLineFlowTests {

    @Test("a healthy project whose .sops.yaml wraps age: [...] across lines reports .ok, not a false stale-recipient problem")
    func multiLineFlowSequenceAgainstAGenuinelyHealthyProject() async throws {
        let key1 = try realAgePublicKey()
        let key2 = try realAgePublicKey()

        // Genuinely, correctly encrypted to both real recipients — the real
        // bridge, not a fixture.
        let encrypted = try SopsBridge.encrypt(
            "password: hunter2\napi_key: sk-live-abc123\n", format: .yaml, recipients: [key1, key2])

        // The recipient list is written as a flow sequence split across two
        // lines, matching the reviewer's exact repro shape.
        let sopsYAML = """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: [\(key1),
                  \(key2)]
        """

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("multiline-flow-" + UUID().uuidString)

        ScratchDirectoryRegistry.shared.register(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(root)
        try sopsYAML.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)
        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
ScratchDirectoryRegistry.shared.register(secretsDir)
        try encrypted.write(to: secretsDir.appendingPathComponent("prod.yaml"), atomically: true, encoding: .utf8)

        // Sanity: the .sops.yaml itself parses via the bridge, and both real
        // keys survive the multi-line flow sequence with no stray bracket —
        // the unit-level half of this regression, verified again here so a
        // failure at this check points straight at the bridge/config parser
        // rather than the full pipeline.
        let lookup = try SopsBridge.lookupCreationRule(
            configPath: root.appendingPathComponent(".sops.yaml").path,
            targetFilePath: secretsDir.appendingPathComponent("prod.yaml").path)
        #expect(lookup.matched)
        #expect(Set(lookup.ageRecipients) == Set([key1, key2]))

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let findings = await check.run()
        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!

        #expect(stale.status == .ok,
                "expected .ok for a genuinely healthy project, got \(stale.status) — detail: \(stale.detail)")
        // The specific false claims the reviewer's repro produced before the
        // fix: neither phrase should appear anywhere in a clean finding.
        #expect(!stale.detail.contains("is encrypted to"))
        #expect(!stale.detail.contains("does not list"))
        #expect(!stale.detail.contains("updatekeys"))
    }
}
