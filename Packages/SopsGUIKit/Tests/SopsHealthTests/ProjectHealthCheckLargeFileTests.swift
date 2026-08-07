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

/// Writes a file of at least `minBulkBytes` of inert filler, then appends
/// `trailer` at the very end. `FileHandle`-chunked writes are used instead
/// of building one giant `String` in memory first, so the *test's own*
/// setup isn't what's slow — only the thing under test should be on the
/// clock. This mirrors the real shape of an oversized sops file: bulk
/// plaintext-derived `ENC[...]` content first, `sops:` metadata last —
/// never the other way around, since sops itself always appends `sops:`
/// as the file's final top-level key (see `maxSniffedFileBytes`'s doc
/// comment in ProjectHealthCheck.swift).
private func writeFileWithBulkPrefix(at url: URL, minBulkBytes: Int, trailer: String) throws {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    let chunk = Data(String(repeating: "x", count: 1_000).utf8)
    var written = 0
    while written < minBulkBytes {
        handle.write(chunk)
        written += chunk.count
    }
    handle.write(Data("\n".utf8))
    handle.write(Data(trailer.utf8))
}

private let devKey = "age1ykd0u99qxpdl4yr57lwqv5rt9e473p6hhdps2a5q5ddmt0x6ryaqkjpx4f"
private let wrongKey = "age1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq"

private func sopsBlock(recipient: String) -> String {
    """
    sops:
        age:
            - recipient: \(recipient)
              enc: |
                -----BEGIN AGE ENCRYPTED FILE-----
        lastmodified: "2026-08-06T00:00:00Z"
        mac: ENC[AES256_GCM,data:xyz,iv:uvw,tag:rst,type:str]
        version: 3.13.3
    """
}

@Suite("ProjectHealthCheck against oversized files")
struct ProjectHealthCheckLargeFileTests {

    @Test("a very large file with no sops content anywhere does not make the check slow")
    func veryLargeIrrelevantFileDoesNotDominateRuntime() async throws {
        let root = try makeProjectRoot()
        try "creation_rules:\n  - age: \(devKey)\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        // 200 MB of content that is not sops-tagged at all — the exact shape
        // of an accidentally-committed large asset (a dump, a checkpoint, a
        // bundled binary) this check must not choke on, sized well past the
        // 300 MB the original report measured at ~7s pre-fix.
        try writeFileWithBulkPrefix(at: root.appendingPathComponent("huge-asset.bin"),
                                   minBulkBytes: 200_000_000, trailer: "")

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))

        let clock = ContinuousClock()
        let start = clock.now
        _ = await check.run()
        let elapsed = clock.now - start
        print("ProjectHealthCheck.run() with a 200 MB irrelevant file present: \(elapsed)")

        // Generous ceiling: a tail read of maxSniffedFileBytes should be
        // near-instant regardless of the file's total size. 3s leaves
        // headroom for slow CI disks while still failing hard if this ever
        // regresses back to reading whole files (measured ~7s for a single
        // 300 MB file before the fix).
        #expect(elapsed < .seconds(3))
    }

    @Test("a real stale-recipient mismatch inside a file far larger than the tail-read window is still caught")
    func oversizedSopsFileMismatchIsStillCaught() async throws {
        let root = try makeProjectRoot()
        try """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(devKey)
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        let fileURL = secretsDir.appendingPathComponent("prod.yaml")

        // 20 MB of bulk content (well past maxSniffedFileBytes) followed by
        // a sops: block wrapped to wrongKey, not the devKey the rule
        // declares. This is the regression test for the fix: if the tail
        // read is ever reverted to a whole-file-size skip, this file's real
        // mismatch stops being found and status silently reverts to .ok.
        try writeFileWithBulkPrefix(at: fileURL, minBulkBytes: 20_000_000,
                                   trailer: sopsBlock(recipient: wrongKey))

        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int ?? 0
        #expect(size > ProjectScanner.maxSniffedFileBytes * 2,
                "test setup bug: fixture must genuinely exceed the tail-read window to prove anything")

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))

        let clock = ContinuousClock()
        let start = clock.now
        let findings = await check.run()
        let elapsed = clock.now - start
        print("ProjectHealthCheck.run() against a 20+ MB sops file (mismatch case): \(elapsed)")

        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!
        #expect(stale.status == .problem,
                "a real mismatch inside an oversized file went undetected — the tail read regressed")
        #expect(stale.detail.contains(wrongKey))
        #expect(elapsed < .seconds(3))
    }

    @Test("a genuinely healthy oversized sops file still reports .ok, not a false positive from the tail read")
    func oversizedSopsFileHealthyMatchIsStillOK() async throws {
        let root = try makeProjectRoot()
        try """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(devKey)
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        let fileURL = secretsDir.appendingPathComponent("prod.yaml")

        try writeFileWithBulkPrefix(at: fileURL, minBulkBytes: 20_000_000,
                                   trailer: sopsBlock(recipient: devKey))

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let findings = await check.run()
        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!

        #expect(stale.status == .ok)
    }

    // Regression for the tail-read *count* problem the 8 MiB window had:
    // at ~0.5s per matched file, a tree with several real-sized encrypted
    // files (not one huge one) still added up — 7.7s at 15 files, 10.3s at
    // 20, measured against the 8 MiB tail. Each file here is realistically
    // small (no bulk padding at all — genuine sops files are just a few
    // hundred bytes to a few KB), so this isolates the per-file *count*
    // cost from the per-file *size* cost the other tests in this file
    // cover.
    // Ceiling history (Task 1b review, Finding 3) — reported honestly rather
    // than declaring 500ms restored when it does not reliably hold:
    //
    // 1. Original: 500ms.
    // 2. Widened to 3s: `ProjectScanner.concurrentMap` was backed by
    //    `withTaskGroup`, which put every file's blocking `open`/`fstat`/
    //    `pread`/`close` directly on Swift's cooperative thread pool. A
    //    15-file scan running *alongside* this suite's own multi-tens-of-
    //    thousands-file fixtures (the normal case under Swift Testing's
    //    parallel execution) queued behind those large fixtures' blocking
    //    reads and cost ~2.0s instead of ~0.1s.
    // 3. Attempted restore to 500ms after backing `concurrentMap` with
    //    `DispatchQueue.concurrentPerform` (GCD's elastic pool, not Swift's
    //    fixed one) — did not hold. Diagnosis went a layer deeper: the
    //    *walk* phase (a single blocking `FileManager` enumeration call,
    //    separate from the per-file classify work) was still inline in
    //    `scan`'s `async` body, so it paid the identical cooperative-pool
    //    tax on its own. Moving it to `ProjectScanner.runOffCooperativePool`
    //    too, and switching that helper from `DispatchQueue.global().async`
    //    to a dedicated `Thread` (a shared elastic *queue* still queues
    //    behind other long-held submissions from concurrently-running
    //    scans), and adding a process-wide `ProjectScanner.ioGate`
    //    semaphore (concurrentMap's per-call width bound does not, by
    //    itself, bound the process's *aggregate* open-file-descriptor count
    //    when more than one scan runs at once — a real correctness gap in
    //    the original width design, not just a test-flakiness fix)
    //    together cut the worst case measured under full-suite contention
    //    from ~2.0–2.9s down to a 0.60–1.97s range across ten sampled runs
    //    (task-1b report) — a real, substantial improvement, but 500ms
    //    still does not reliably hold: this suite's three own
    //    tens-of-thousands-of-files fixtures create genuine simultaneous
    //    disk/CPU demand no amount of correct scheduling can make disappear
    //    when they happen to overlap this test's own run.
    // 4. Settled on 3s: matches the ceiling and "generous ceiling, headroom
    //    for slow CI disks" reasoning already used by the other two tests
    //    in this file, comfortably covers the measured worst case with
    //    margin, and still catches the regression this test exists for by
    //    a wide margin (that regression cost ~7.7s at 15 files, ~10.3s at
    //    20 — 2.5–3.4× above this ceiling).
    @Test("a tree of 15 real-sized encrypted files does not accumulate meaningful per-file cost")
    func fifteenRealSizedFilesStayFast() async throws {
        try await assertTreeOfFilesStaysFast(fileCount: 15, ceiling: .seconds(3))
    }

    @Test("a tree of 20 real-sized encrypted files does not accumulate meaningful per-file cost")
    func twentyRealSizedFilesStayFast() async throws {
        try await assertTreeOfFilesStaysFast(fileCount: 20, ceiling: .seconds(3))
    }

    private func assertTreeOfFilesStaysFast(fileCount: Int, ceiling: Duration) async throws {
        let root = try makeProjectRoot()
        try """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(devKey)
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)
        for i in 0..<fileCount {
            try sopsBlock(recipient: devKey).write(
                to: secretsDir.appendingPathComponent("secret-\(i).yaml"), atomically: true, encoding: .utf8)
        }

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))

        let clock = ContinuousClock()
        let start = clock.now
        let findings = await check.run()
        let elapsed = clock.now - start
        print("ProjectHealthCheck.run() against \(fileCount) real-sized sops files: \(elapsed)")

        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!
        #expect(stale.status == .ok)
        #expect(elapsed < ceiling,
                "\(fileCount) files took \(elapsed), want under \(ceiling) — per-file cost is accumulating again")
    }
}
