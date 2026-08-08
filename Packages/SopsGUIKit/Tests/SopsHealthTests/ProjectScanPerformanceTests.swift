import Foundation
import Testing
@testable import SopsHealth

/// Task 1b: parallelising the tail read must not change *what* `scan(root:)`
/// finds. This file is the safety net (Step 1 of the brief) plus the
/// throughput proof that follows it — pinned against the synchronous
/// implementation first, then re-run unchanged (only `await` added at the
/// call site) after `scan` is parallelised.
@Suite("project scan pinning and throughput", .serialized)
struct ProjectScanPerformanceTests {

    /// A fixed sops-metadata block. Deliberately hand-written rather than run
    /// through `SopsBridge` — `ProjectScanner` only pattern-matches on the
    /// text shape, it never verifies the crypto, so a literal string pins the
    /// exact bytes `SniffedFile.tail` must come back with.
    ///
    /// It must nonetheless carry the *shape* sops writes, not just the
    /// `"\nsops:"` substring. Task 14 tightened classification from "contains
    /// the marker" to "has the structure sops's own serializer emits" —
    /// because on this app's own repository the substring version offered two
    /// Markdown reports quoting a sops block as openable encrypted files. The
    /// `mac:` line below is part of that: sops writes `mac` and `version` for
    /// every file it encrypts, in every store, so a fixture without one was
    /// never a faithful stand-in for real output. See `SopsMetadataShape`.
    private static let encryptedContent =
        "message: ENC[AES256_GCM,data:xyz,iv:abc,tag:def,type:str]\nsops:\n    age:\n        - recipient: age1exampleexamplerecipientexampleexampleexampleexamplex\n    lastmodified: \"2026-08-08T00:00:00Z\"\n    mac: ENC[AES256_GCM,data:mno,iv:pqr,tag:stu,type:str]\n    version: 3.13.3\n"

    /// Builds a tree with, in one `src/` directory:
    /// - `matchingCount` copies of a genuinely sops-tagged file
    /// - `matchingCount` copies of a plaintext-candidate-named file (`*.env`)
    /// - enough filler `.txt` files that the *total* regular-file count in
    ///   `src/` is `ProjectScanner.maxScannedFiles + margin`, guaranteeing
    ///   `wasTruncated`
    ///
    /// plus a sibling `node_modules/` directory (on the skip list) holding a
    /// file that would otherwise match the plaintext-candidate pattern.
    ///
    /// `FileManager`'s enumerator order is not documented and was verified
    /// (Task 1's report) to track neither filename nor creation order, so a
    /// single specially-placed "the" encrypted/plaintext file gives no real
    /// guarantee it survives truncation. This fixture instead uses the same
    /// combinatorial-floor technique as `ProjectScanBoundsTests.truncationBlocksOK`:
    /// `matchingCount` copies of each kind, with `margin` the fixed number of
    /// files truncation ever drops (`total - maxScannedFiles`), so at least
    /// `matchingCount - margin` of *each* kind survive regardless of which
    /// specific files the enumerator visits last.
    private func makePinnedTree(matchingCount: Int, margin: Int) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("pin-" + UUID().uuidString)
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)

        for i in 0..<matchingCount {
            try Self.encryptedContent.write(
                to: src.appendingPathComponent("secret\(i).yaml"), atomically: true, encoding: .utf8)
        }
        for i in 0..<matchingCount {
            try "SERVICE_KEY=live-\(i)".write(
                to: src.appendingPathComponent("svc\(i).env"), atomically: true, encoding: .utf8)
        }
        let total = ProjectScanner.maxScannedFiles + margin
        let fillerCount = total - (matchingCount * 2)
        for i in 0..<fillerCount {
            try "x".write(to: src.appendingPathComponent("junk\(i).txt"), atomically: true, encoding: .utf8)
        }

        let excludedDir = root.appendingPathComponent("node_modules")
        try FileManager.default.createDirectory(at: excludedDir, withIntermediateDirectories: true)
        try "LEAKED=1".write(to: excludedDir.appendingPathComponent("leak.env"), atomically: true, encoding: .utf8)

        return root
    }

    /// Step 1: pin the current behaviour before changing how the tail is
    /// read. Run against the synchronous `ProjectScanner.scan(root:)` first
    /// (must pass unmodified) — the `await` below is a no-op today and
    /// becomes load-bearing once `scan` is made `async` for parallel reads.
    @Test("scan finds the encrypted file, the plaintext candidate, skips the excluded directory, and discloses truncation")
    func pinnedScanFindsExpectedFiles() async throws {
        let matchingCount = 300
        let margin = 50
        let root = try makePinnedTree(matchingCount: matchingCount, margin: margin)
        defer { try? FileManager.default.removeItem(at: root) }

        let tree = await ProjectScanner.scan(root: root)

        // Truncation is deterministic regardless of enumeration order: every
        // regular file in `src/` counts toward the budget, and `src/` alone
        // holds `maxScannedFiles + margin` of them.
        #expect(tree.wasTruncated)
        #expect(tree.skippedDirectoryNames == ["node_modules"])

        // Nothing sops-tagged in another format exists in this fixture.
        #expect(tree.encryptedInOtherFormats.isEmpty)

        // Combinatorial floor: at most `margin` files are ever dropped in
        // total, so at least `matchingCount - margin` of *each* kind survive
        // no matter which specific files the enumerator visits last.
        let floor = matchingCount - margin
        #expect(tree.encrypted.count >= floor, "expected at least \(floor) encrypted files, got \(tree.encrypted.count)")
        #expect(tree.encrypted.count <= matchingCount)
        #expect(tree.plaintextCandidates.count >= floor, "expected at least \(floor) plaintext candidates, got \(tree.plaintextCandidates.count)")
        #expect(tree.plaintextCandidates.count <= matchingCount)

        // Exact content pin: every survivor is the real thing, not a
        // filler file or the excluded directory's file leaking through.
        for sniffed in tree.encrypted {
            #expect(sniffed.tail == Self.encryptedContent)
            #expect(sniffed.url.lastPathComponent.hasPrefix("secret"))
            #expect(sniffed.url.lastPathComponent.hasSuffix(".yaml"))
            #expect(!sniffed.url.path.contains("node_modules"))
        }
        for url in tree.plaintextCandidates {
            #expect(url.lastPathComponent.hasPrefix("svc"))
            #expect(url.lastPathComponent.hasSuffix(".env"))
            #expect(!url.path.contains("node_modules"))
        }

        // The excluded directory's own plaintext-shaped file must never
        // appear anywhere in the result — this is the coverage guarantee
        // under test, not just an absence-of-crash check.
        #expect(!tree.plaintextCandidates.contains { $0.lastPathComponent == "leak.env" })
    }

    /// Step 6 / determinism requirement: the returned arrays must not depend
    /// on tail-read completion order. Scans the same modest (well under
    /// budget) tree several times and asserts byte-for-byte identical
    /// results every time — a regression here would mean downstream
    /// consumers (and every test that reads `ScannedTree` fields) become
    /// flaky.
    @Test("repeated scans of the same tree yield identical results")
    func repeatedScansAreDeterministic() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("determinism-" + UUID().uuidString)
        let src = root.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for i in 0..<40 {
            try Self.encryptedContent.write(
                to: src.appendingPathComponent("secret\(i).yaml"), atomically: true, encoding: .utf8)
        }
        for i in 0..<40 {
            try "SERVICE_KEY=live-\(i)".write(
                to: src.appendingPathComponent("svc\(i).env"), atomically: true, encoding: .utf8)
        }
        for i in 0..<200 {
            try "x".write(to: src.appendingPathComponent("junk\(i).txt"), atomically: true, encoding: .utf8)
        }

        func fingerprint(_ tree: ScannedTree) -> String {
            let encrypted = tree.encrypted.map { "\($0.url.path)|\($0.tail)" }.joined(separator: "\n")
            let others = tree.encryptedInOtherFormats.map(\.path).joined(separator: "\n")
            let plaintext = tree.plaintextCandidates.map(\.path).joined(separator: "\n")
            let skipped = tree.skippedDirectoryNames.joined(separator: ",")
            return "\(encrypted)\n---\n\(others)\n---\n\(plaintext)\n---\n\(skipped)\n---\n\(tree.wasTruncated)"
        }

        var trees: [ScannedTree] = []
        for _ in 0..<5 {
            trees.append(await ProjectScanner.scan(root: root))
        }

        #expect(!trees[0].encrypted.isEmpty, "sanity: fixture must actually contain matches")
        #expect(trees[0].encrypted.count == 40)
        #expect(trees[0].plaintextCandidates.count == 40)

        let fingerprints = trees.map(fingerprint)
        for f in fingerprints.dropFirst() {
            #expect(f == fingerprints[0], "scan results differ between repeated runs against the same unchanged tree")
        }
    }

    /// Wall-clock measurement against a real, large checkout — set
    /// `SCAN_TIMING_ROOT` to a directory to run it; skipped otherwise so CI
    /// and other machines without that checkout aren't affected. This is the
    /// number quoted in the task-1b report, both before and after
    /// parallelising the tail read.
    ///
    /// `~/Development/invoi/invoi-app` (~272,802 files) was the repository
    /// used for Task 1's measurement and is used again here for continuity.
    @Test("real repository scan wall clock", .enabled(if: ProcessInfo.processInfo.environment["SCAN_TIMING_ROOT"] != nil))
    func realRepositoryScanWallClock() async throws {
        let path = ProcessInfo.processInfo.environment["SCAN_TIMING_ROOT"]!
        let root = URL(fileURLWithPath: path)

        let clock = ContinuousClock()
        let start = clock.now
        let tree = await ProjectScanner.scan(root: root)
        let elapsed = clock.now - start

        let visited = tree.encrypted.count + tree.encryptedInOtherFormats.count + tree.plaintextCandidates.count
        print("SCAN_TIMING_ROOT=\(path): elapsed=\(elapsed) wasTruncated=\(tree.wasTruncated) classifiedFiles=\(visited) skipped=\(tree.skippedDirectoryNames.sorted())")
    }

    /// A lock-protected watermark: tracks how many units of work are
    /// concurrently "in flight" between `enter()` and `leave()`, and the
    /// peak ever observed. Used below to *prove* `concurrentMap`'s width
    /// bound holds, rather than trust the seed/replenish construction by
    /// reading the code.
    ///
    /// A plain `NSLock`-guarded class, not an actor: `concurrentMap`'s
    /// `transform` is a synchronous `@Sendable (Item) -> Output` closure —
    /// deliberately not `async`, per Finding 3 of the Task 1b review — so
    /// this has to be something callable without `await` from inside it.
    /// `@unchecked Sendable` is the same "the lock, not the type system,
    /// is what makes this safe" pattern `ProjectScanner.ResultsBox` uses.
    private final class Watermark: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var peak = 0
        func enter() {
            lock.lock(); current += 1; peak = max(peak, current); lock.unlock()
        }
        func leave() {
            lock.lock(); current -= 1; lock.unlock()
        }
        func peakObserved() -> Int {
            lock.lock(); defer { lock.unlock() }; return peak
        }
    }

    /// Step 3's "prove the bound holds, don't assume it": instruments
    /// `ProjectScanner.concurrentMap` — the exact function `scan` fans the
    /// tail-read-and-classify work out over — with a `Watermark` and a
    /// transform whose delay is *inversely* keyed to item index within each
    /// width-sized batch, so work started later in a batch finishes before
    /// work started earlier. If the implementation were, say, secretly
    /// unbounded (all iterations fired at once) the watermark would exceed
    /// `width`; if it were accidentally serial (one at a time) the
    /// watermark would never exceed 1 and the result order would still look
    /// right by coincidence — this also checks the peak is reached, not
    /// just bounded, so a serial implementation fails this test too.
    ///
    /// Synchronous `Thread.sleep`, not `Task.sleep`: the transform under
    /// test runs on a GCD worker thread via `DispatchQueue.concurrentPerform`,
    /// not inside a `Task`, so there is no cooperative-pool suspension point
    /// for `Task.sleep` to yield at — blocking the thread with `Thread.sleep`
    /// is the correct simulation of what a real blocking read looks like
    /// here, and is exactly the shape of work `concurrentMap` exists to run.
    @Test("concurrentMap never runs more than `width` transforms at once, and preserves input order under scrambled completion order")
    func tailReadConcurrencyIsBounded() async throws {
        let width = 8
        let itemCount = width * 4
        let watermark = Watermark()

        let results = await ProjectScanner.concurrentMap(Array(0..<itemCount), width: width) { item -> Int in
            watermark.enter()
            // Every batch of `width` items sleeps longer for a *lower* index
            // than a higher one, so within a batch the later item finishes
            // first — deliberately scrambling completion order relative to
            // input order.
            let positionInBatch = item % width
            let millis = UInt32(width - positionInBatch) * 5
            usleep(millis * 1000)
            watermark.leave()
            return item * 2
        }

        // Determinism: output order matches input order, not completion
        // order, despite completion order being deliberately scrambled above.
        #expect(results == (0..<itemCount).map { $0 * 2 })

        let peak = watermark.peakObserved()
        // Hard bound: never more than `width` concurrently in flight.
        #expect(peak <= width, "concurrentMap ran \(peak) transforms at once, exceeding width \(width)")
        // Not just bounded but actually concurrent: with `width` items
        // batched together and a sleep long enough to guarantee overlap, the
        // watermark must reach `width` exactly, or this "bound" would be
        // satisfied just as well by an accidentally-serial implementation.
        #expect(peak == width, "expected concurrentMap to reach full width \(width) of overlap, only reached \(peak)")
    }
}
