import Foundation
import Testing
@testable import SopsHealth

private struct FakeProjects: ProjectSourceProviding {
    let projects: [InspectedProject]
}

private func makeProjectRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("large-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Writes a file of at least `minBytes`, padded with inert repeated content.
/// `FileManager.createFile` + `FileHandle` is used instead of building one
/// giant `String` in memory first, so the *test's own* setup isn't what's
/// slow here — only the thing under test should be on the clock.
private func writeLargeFile(at url: URL, minBytes: Int, chunk: String) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let chunkData = Data(chunk.utf8)
    var written = 0
    while written < minBytes {
        handle.write(chunkData)
        written += chunkData.count
    }
}

private let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
private let wrongKey = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

@Suite("ProjectHealthCheck against oversized files")
struct ProjectHealthCheckLargeFileTests {

    @Test("a large file with no sops content does not make the check slow")
    func largeIrrelevantFileDoesNotDominateRuntime() async throws {
        let root = try makeProjectRoot()
        try "creation_rules:\n  - age: \(devKey)\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        // ~60 MB of content that is not sops-tagged at all — the exact shape
        // of an accidentally-committed large asset (a dump, a checkpoint, a
        // bundled binary) this check must not choke on.
        try writeLargeFile(at: root.appendingPathComponent("huge-asset.bin"),
                          minBytes: 60_000_000, chunk: String(repeating: "x", count: 1_000))

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))

        let clock = ContinuousClock()
        let start = clock.now
        _ = await check.run()
        let elapsed = clock.now - start
        print("ProjectHealthCheck.run() with a 60 MB irrelevant file present: \(elapsed)")

        // Generous ceiling: this should be near-instant (a stat, not a read)
        // once the size cap is in place. 3s leaves headroom for slow CI
        // disks while still failing hard if the cap regresses to "read
        // everything" (which measured ~6.6s for a single 300 MB file, and
        // scales with size and file count).
        #expect(elapsed < .seconds(3))
    }

    @Test("a real stale-recipient mismatch inside an oversized sops file is not caught — proving the cap actually excludes it, not just coincidentally skips non-sops content")
    func oversizedSopsLookingFileIsExcludedFromTheRecipientScan() async throws {
        let root = try makeProjectRoot()
        try """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(devKey)
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        // A file that, if read, unambiguously LOOKS like a sops file and
        // WOULD be flagged: it's encrypted to wrongKey, not the devKey the
        // rule declares. It's padded well past maxSniffedFileBytes with an
        // inert trailing comment so its size alone excludes it.
        let padding = String(repeating: "#", count: ProjectHealthCheck.maxSniffedFileBytes + 1_000_000)
        let sopsLookingButOversized = """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            age:
                - recipient: \(wrongKey)
                  enc: |
                    -----BEGIN AGE ENCRYPTED FILE-----
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        # \(padding)
        """
        try sopsLookingButOversized.write(
            to: secretsDir.appendingPathComponent("prod.yaml"), atomically: true, encoding: .utf8)

        let size = try FileManager.default.attributesOfItem(
            atPath: secretsDir.appendingPathComponent("prod.yaml").path)[.size] as? Int ?? 0
        #expect(size > ProjectHealthCheck.maxSniffedFileBytes,
                "test setup bug: fixture must actually exceed the cap to prove anything")

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let findings = await check.run()
        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!

        // If the size cap is ever removed or loosened past this fixture's
        // size, this file would be read, its wrongKey mismatch would be
        // found, and status would become .problem — turning this assertion
        // red is exactly the point.
        #expect(stale.status == .ok, "an oversized file's real mismatch was found — the size cap regressed")
    }

    @Test("a file just under the cap that is genuinely sops-encrypted is still checked normally")
    func fileJustUnderTheCapIsStillRead() async throws {
        let root = try makeProjectRoot()
        try """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(devKey)
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        // Padded with a trailing comment to just under the cap (not merely
        // "small") — a genuine boundary check, not just a happy-path small
        // file that would pass even with a much smaller cap. Still wrapped
        // in wrongKey, so this one MUST be caught.
        let header = """
        password: ENC[AES256_GCM,data:abc,iv:def,tag:ghi,type:str]
        sops:
            age:
                - recipient: \(wrongKey)
                  enc: |
                    -----BEGIN AGE ENCRYPTED FILE-----
            lastmodified: "2026-08-06T00:00:00Z"
            mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
            version: 3.13.3
        #
        """
        let padding = String(repeating: "#",
                             count: max(0, ProjectHealthCheck.maxSniffedFileBytes - header.utf8.count - 4_096))
        try (header + padding).write(
            to: secretsDir.appendingPathComponent("prod.yaml"), atomically: true, encoding: .utf8)

        let size = try FileManager.default.attributesOfItem(
            atPath: secretsDir.appendingPathComponent("prod.yaml").path)[.size] as? Int ?? 0
        #expect(size <= ProjectHealthCheck.maxSniffedFileBytes)
        #expect(size > ProjectHealthCheck.maxSniffedFileBytes / 2, "test setup bug: fixture should actually approach the cap")

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let findings = await check.run()
        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!

        #expect(stale.status == .problem, "a file under the cap must still be fully checked")
    }
}
