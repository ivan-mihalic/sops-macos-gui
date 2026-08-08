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

    /// The performance property, measured in bytes rather than seconds.
    ///
    /// This assertion used to read `#expect(elapsed < .seconds(3))`. It failed
    /// roughly half the time under bare `swift test` — one process, all 63
    /// suites, several of them scanning tens-of-thousands-of-files fixtures —
    /// and never under `xcrun`, which gives each target its own process. The
    /// code under test was identical in both; what differed was how busy the
    /// machine was. Three of this file's assertions had already been through
    /// that cycle (500ms → 3s → replaced), and raising the number a fourth
    /// time would have kept the bad instrument and only moved where it next
    /// tripped.
    ///
    /// So it measures the property directly instead. The claim behind
    /// `ProjectScanner.maxSniffedFileBytes` is not "this finishes within three
    /// seconds" — it is "a file's *size* is not this scanner's cost, because
    /// only the last `maxSniffedFileBytes` are ever read". `TailReadLedger`
    /// reports exactly that number. A regression to whole-file reads changes
    /// it here by a factor of ~3,200, cannot be hidden by a fast disk or an
    /// idle machine, and cannot be tripped by a busy one. See
    /// `TailReadLedger`'s doc comment for why bytes beat both an absolute
    /// ceiling and a same-run ratio for *this* property specifically.
    ///
    /// The wall clock is still printed. It is genuinely useful when a human
    /// is looking at a regression; it is just not something to fail a build
    /// on.
    @Test("a very large file with no sops content anywhere is read only at its tail, never in full")
    func veryLargeIrrelevantFileIsOnlyTailRead() async throws {
        let root = try makeProjectRoot()
        try "creation_rules:\n  - age: \(devKey)\n"
            .write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        // 200 MB of content that is not sops-tagged at all — the exact shape
        // of an accidentally-committed large asset (a dump, a checkpoint, a
        // bundled binary) this check must not choke on, sized well past the
        // 300 MB the original report measured at ~7s pre-fix.
        let hugeFile = root.appendingPathComponent("huge-asset.bin")
        try writeFileWithBulkPrefix(at: hugeFile, minBulkBytes: 200_000_000, trailer: "")
        let size = try FileManager.default.attributesOfItem(atPath: hugeFile.path)[.size] as? Int ?? 0

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))

        let clock = ContinuousClock()
        let start = clock.now
        let (_, reading) = await TailReadLedger.recording { await check.run() }
        let elapsed = clock.now - start
        let bytesRead = reading.bytes(for: hugeFile)
        print("ProjectHealthCheck.run() with a \(size)-byte irrelevant file present: read \(bytesRead) bytes from it, elapsed \(elapsed)")

        #expect(size > 100_000_000,
                "test setup bug: the fixture must be far larger than the tail-read window to prove anything")
        // Without this the assertion below passes just as happily over a file
        // that was never opened at all — a scan that stopped finding things
        // would look like a scan that got faster.
        #expect(bytesRead > 0,
                "the scan never read this file at all, so the byte bound below proves nothing")
        #expect(bytesRead <= ProjectScanner.maxSniffedFileBytes,
                "read \(bytesRead) bytes from a \(size)-byte file; the tail read is bounded at \(ProjectScanner.maxSniffedFileBytes) — file size has become this scanner's cost again")
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
        let (findings, reading) = await TailReadLedger.recording { await check.run() }
        let elapsed = clock.now - start
        let bytesRead = reading.bytes(for: fileURL)
        print("ProjectHealthCheck.run() against a \(size)-byte sops file (mismatch case): read \(bytesRead) bytes from it, elapsed \(elapsed)")

        // The correctness half, unchanged: a real mismatch beyond the tail
        // window is still found. This is the assertion that fails if the
        // *window* regresses — if the read moves off the end of the file, or
        // the block stops being found where it lands.
        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!
        #expect(stale.status == .problem,
                "a real mismatch inside an oversized file went undetected — the tail read regressed")
        #expect(stale.detail.contains(wrongKey))

        // The performance half, formerly `#expect(elapsed < .seconds(3))` —
        // see `veryLargeIrrelevantFileIsOnlyTailRead` above for why a
        // wall-clock ceiling was the wrong instrument, and `TailReadLedger`
        // for what replaced it. Asserting both halves on the same fixture is
        // the strongest form available: the scan reads 64 KiB of a 20 MB file
        // *and* still catches the mismatch. Neither half alone rules out the
        // failure the other covers.
        #expect(bytesRead > 0,
                "the scan never read this file at all, so the byte bound below proves nothing")
        #expect(bytesRead <= ProjectScanner.maxSniffedFileBytes,
                "read \(bytesRead) bytes from a \(size)-byte file; the tail read is bounded at \(ProjectScanner.maxSniffedFileBytes) — file size has become this scanner's cost again")
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
    // Ceiling history — reported honestly rather than declaring a number
    // restored when it does not reliably hold:
    //
    // 1. Original: an absolute 500ms wall-clock ceiling on the full scan.
    // 2. Widened to an absolute 3s (Task 1b). The *first* recorded
    //    justification for this widening (Task 1b's original report) was
    //    wrong — it attributed the flake entirely to "legitimate parallel
    //    test contention... with no change to the production code path",
    //    i.e. blamed the test suite's shape and declared the production
    //    code innocent. A reviewer ran the experiment that report never
    //    did: the same heavy fixtures against the *pre-Task-1b* production
    //    code never troubled the original 500ms ceiling (0.089–0.139s
    //    measured), while the new code hit 1.975s under the identical
    //    contention. The real cause was a genuine production regression:
    //    `ProjectScanner.concurrentMap` was backed by `withTaskGroup`,
    //    which put every file's blocking `open`/`fstat`/`pread`/`close`
    //    directly on Swift's cooperative thread pool — a pool sized to the
    //    machine's core count on the assumption every thread always makes
    //    progress. One blocking syscall on it stalls *everything* sharing
    //    that pool, including this suite's own other tens-of-thousands-
    //    of-files fixtures' scans and this test's tiny one alike. Fixed
    //    (task-1b review round 2) by moving both the walk and the per-file
    //    tail-read-and-classify work off the cooperative pool entirely
    //    (`DispatchQueue.concurrentPerform` for the fan-out, a dedicated
    //    `Thread` for `runOffCooperativePool`, a process-wide
    //    `ProjectScanner.ioGate` bounding aggregate concurrent I/O across
    //    overlapping scans — full account in the task-1b report's Finding
    //    3). That fix cut the worst case measured under full-suite
    //    contention from ~2.0–2.9s down to a 0.60–1.97s range across ten
    //    sampled runs, but did not restore 500ms: this suite's own tens-
    //    of-thousands-of-files fixtures create genuine simultaneous
    //    disk/CPU demand no amount of correct scheduling makes disappear
    //    when they happen to overlap this test's run. Ceiling set to 3s on
    //    that basis — "comfortably covers the measured worst case (1.97s)
    //    with margin."
    // 3. 3s itself then intermittently failed (3.18–3.21s observed) — the
    //    predictable next step of the same dynamic: an absolute wall-clock
    //    ceiling on a measurement dominated by ambient contention has no
    //    value that is both tight enough to catch a real regression and
    //    loose enough to never trip on a bad-luck scheduling window,
    //    because contention is unbounded from this test's point of view —
    //    nothing stops several other suites' tens-of-thousands-of-files
    //    scans from landing in the same window at once. Raising the number
    //    a third time would only shift where the same failure resurfaces:
    //    by the reviewer's own math after step 2's fix (1.97s against a 3s
    //    ceiling is already 1.5×, leaving room for nothing short of a ~30×
    //    per-file regression to still trip it), the ceiling was already
    //    close to worthless as a regression detector before this run ever
    //    failed.
    // 4. Replaced the absolute ceiling with a same-run, contention-
    //    independent measurement (below): a one-file scan and the full
    //    `fileCount`-file scan run back-to-back in the same test, and only
    //    the *marginal* per-file cost — `(full − baseline) /
    //    (fileCount − 1)` — is asserted against a ceiling. Ambient
    //    contention inflates both measurements by roughly the same fixed
    //    per-scan overhead (locating `git`, the directory walk, spinning up
    //    `runOffCooperativePool`'s dedicated thread) regardless of how busy
    //    the machine is at that moment, and that shared overhead cancels
    //    out of the subtraction; a genuine per-file regression, by
    //    contrast, scales with file count and survives it. This is the
    //    change the reviewer who diagnosed step 2 explicitly recommended
    //    once step 3's math was made concrete: "the assertion can no
    //    longer catch anything under a ~30× per-file regression... prefer
    //    isolating the heavy fixtures or measuring something contention-
    //    independent over paying for it with the ceiling."
    @Test("a tree of 15 real-sized encrypted files does not accumulate meaningful per-file cost")
    func fifteenRealSizedFilesStayFast() async throws {
        try await assertTreeOfFilesStaysFast(fileCount: 15, perFileCeiling: .milliseconds(150))
    }

    @Test("a tree of 20 real-sized encrypted files does not accumulate meaningful per-file cost")
    func twentyRealSizedFilesStayFast() async throws {
        try await assertTreeOfFilesStaysFast(fileCount: 20, perFileCeiling: .milliseconds(150))
    }

    /// Scans a one-file tree, then the full `fileCount`-file tree, in the
    /// same test run — see the "Ceiling history" comment above item 4 for
    /// why the assertion is the *marginal* per-file cost between the two,
    /// not either measurement's absolute wall clock. `perFileCeiling` is
    /// generous relative to the actual measured cost (well under 5ms/file
    /// uncontended — see the flaky-timing report) but tight relative to the
    /// regression this test exists to catch (~500ms/file, the 8 MiB-tail
    /// regression that motivated `maxSniffedFileBytes`) — comfortably in
    /// between, and unlike an absolute ceiling, that margin does not erode
    /// as ambient contention grows, because contention is subtracted out
    /// along with the rest of the fixed per-scan overhead.
    private func assertTreeOfFilesStaysFast(fileCount: Int, perFileCeiling: Duration) async throws {
        let root = try makeProjectRoot()
        try """
        creation_rules:
          - path_regex: secrets/.*\\.yaml$
            age: \(devKey)
        """.write(to: root.appendingPathComponent(".sops.yaml"), atomically: true, encoding: .utf8)

        let secretsDir = root.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at: secretsDir, withIntermediateDirectories: true)

        let check = ProjectHealthCheck(source: FakeProjects(
            projects: [InspectedProject(name: "demo", rootPath: root.path)]))
        let clock = ContinuousClock()

        // Baseline: a single real-sized file, scanned through the identical
        // `check.run()` call the full-size measurement below uses — same
        // fixed overhead (locating git, the directory walk, the dedicated
        // off-cooperative-pool thread), same project, same moment's ambient
        // contention. This is what the full measurement's marginal cost is
        // computed against.
        try sopsBlock(recipient: devKey).write(
            to: secretsDir.appendingPathComponent("secret-0.yaml"), atomically: true, encoding: .utf8)
        let baselineStart = clock.now
        _ = await check.run()
        let baselineElapsed = clock.now - baselineStart

        for i in 1..<fileCount {
            try sopsBlock(recipient: devKey).write(
                to: secretsDir.appendingPathComponent("secret-\(i).yaml"), atomically: true, encoding: .utf8)
        }

        let fullStart = clock.now
        let findings = await check.run()
        let fullElapsed = clock.now - fullStart

        let marginalFileCount = fileCount - 1
        let marginalElapsed = fullElapsed - baselineElapsed
        let perFileCost = marginalElapsed / marginalFileCount
        print("ProjectHealthCheck.run(): baseline (1 file) \(baselineElapsed), full (\(fileCount) files) \(fullElapsed), marginal per-file cost \(perFileCost)")

        let stale = findings.first { $0.id.hasSuffix("stale-recipients") }!
        #expect(stale.status == .ok)
        #expect(perFileCost < perFileCeiling,
                "adding \(marginalFileCount) more files cost \(marginalElapsed) (\(perFileCost)/file), want under \(perFileCeiling)/file — per-file cost is accumulating again")
    }
}
