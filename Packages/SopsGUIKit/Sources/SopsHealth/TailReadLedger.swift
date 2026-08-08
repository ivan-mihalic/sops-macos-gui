import Foundation

/// How many bytes `ProjectScanner` actually pulled off disk for each file it
/// looked at — the direct measurement of the property `maxSniffedFileBytes`
/// exists to provide.
///
/// ## Why this exists rather than a stopwatch
///
/// The tail read's claim is "a file's *size* costs this scanner nothing,
/// because it only ever reads the last `maxSniffedFileBytes`". Two tests in
/// `ProjectHealthCheckLargeFileTests` used to assert that with a wall-clock
/// ceiling (`elapsed < .seconds(3)`) against a 200 MB and a 20 MB fixture.
/// That instrument failed roughly half the time under bare `swift test`,
/// which runs all of this package's suites in one process — several of them
/// building and scanning tens-of-thousands-of-files trees — and never under
/// `xcrun`, which gives each target its own process. Nothing about the code
/// under test differed between the two; the number being measured was
/// dominated by how busy the machine was.
///
/// That had been true, and known, since `b8248c1`. The cost of leaving it was
/// not the two red lines: it was that a suite with a permanently-red pair
/// teaches everyone to skim past red, so the next genuine regression in that
/// file gets waved through as "the flake". Raising the ceiling a fourth time
/// (500ms → 3s → 3s → …) was explicitly not the fix — it keeps the bad
/// instrument and only moves where it next trips. The same argument was
/// already made and acted on for this file's *other* pair of timing tests,
/// which now measure a marginal per-file cost rather than an absolute one;
/// see the "Ceiling history" comment there.
///
/// Counting bytes is a better instrument than either, for these two tests
/// specifically, because bytes-read **is** the property. A stopwatch is a
/// proxy for it: it can only detect a whole-file read by the time that read
/// takes, which is exactly the quantity ambient load perturbs. The byte count
/// is unaffected by load, by scheduling, by disk speed, and by how many other
/// suites are running — a regression from a 64 KiB tail read to a 200 MB
/// whole-file read changes it by a factor of 3,200 and cannot be masked. It
/// also states the intent more honestly than a duration ever did: this scan
/// is bounded per file, full stop, not "usually fast enough".
///
/// ## Attribution across concurrently running tests
///
/// Swift Testing runs tests in parallel, so a global counter would be
/// polluted by whatever other suites happen to be scanning at the same time —
/// the very problem the stopwatch had, re-created in a new unit. Readings are
/// therefore keyed by **file path**, and every test filters for its own
/// fixture, which lives under a `UUID()`-named temporary directory no other
/// test can touch. Overlapping recordings see each other's paths and ignore
/// them.
///
/// ## Cost when nothing is recording
///
/// One uncontended `NSLock` acquire per file, and no allocation: `record` takes
/// the lock, sees `activeRecordings == 0`, and returns. At the scanner's
/// 20,000-file budget that is a fraction of a millisecond against a scan
/// measured in seconds. Recording is never enabled by the app itself — only
/// `recording(_:)` turns it on, and nothing outside the test target calls it.
enum TailReadLedger {

    /// The mutable state, behind a lock, in a reference type reached through
    /// a `static let` — the same "the lock, not the type system, makes this
    /// safe" pattern as `ProjectScanner.ResultsBox` and
    /// `ProjectScanPerformanceTests.Watermark`. Every method here is
    /// synchronous on purpose: `NSLock.lock()` is unavailable from an
    /// asynchronous context, so the critical sections must not straddle the
    /// `await` in `recording(_:)`.
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var activeRecordings = 0
        private var bytesByPath: [String: Int] = [:]

        func record(path: String, bytes: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard activeRecordings > 0 else { return }
            bytesByPath[path, default: 0] += bytes
        }

        func beginRecording() {
            lock.lock(); activeRecordings += 1; lock.unlock()
        }

        /// Drops the accumulated map only when the *last* recording closes,
        /// so one test finishing does not blind another still running.
        func endRecording() {
            lock.lock()
            activeRecordings -= 1
            if activeRecordings == 0 { bytesByPath.removeAll() }
            lock.unlock()
        }

        func snapshot() -> [String: Int] {
            lock.lock(); defer { lock.unlock() }; return bytesByPath
        }
    }

    private static let state = State()

    /// One recording's answer: what each file cost, in bytes actually read.
    struct Reading: Sendable {
        /// Every path read while the recording was open — including files
        /// read by other tests running concurrently. Filter before believing
        /// a total; see the type-level doc comment.
        let bytesByPath: [String: Int]

        /// Bytes read from `url` across the whole recording.
        ///
        /// Both sides are canonicalized before comparison because a scan
        /// enumerates a symlinked root under its resolved spelling: a fixture
        /// created at `/var/folders/…` (what `FileManager.temporaryDirectory`
        /// hands back) is walked as `/private/var/folders/…`, so a raw string
        /// match finds nothing and the assertion would pass vacuously against
        /// zero bytes. `ProjectHealthCheck.canonicalPath` reconciles the same
        /// two spellings for the same reason.
        func bytes(for url: URL) -> Int {
            let target = Self.canonical(url.path)
            return bytesByPath
                .filter { Self.canonical($0.key) == target }
                .values.reduce(0, +)
        }

        private static func canonical(_ path: String) -> String {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return resolved.hasPrefix("/private/")
                ? String(resolved.dropFirst("/private".count)) : resolved
        }
    }

    /// Records one file's read. Called from `ProjectScanner.tailBytes`, once
    /// per file it opens, with the number of bytes `pread` actually returned.
    static func record(path: String, bytes: Int) {
        state.record(path: path, bytes: bytes)
    }

    /// Runs `body` with recording switched on, and returns its value together
    /// with everything read while it ran.
    ///
    /// Nested and overlapping recordings are counted, not toggled, so one
    /// test finishing does not switch recording off underneath another that
    /// is still running. The accumulated map is dropped only when the last
    /// recording closes, which is what keeps memory bounded in a process that
    /// is otherwise never recording.
    static func recording<T>(_ body: () async throws -> T) async rethrows -> (value: T, reading: Reading) {
        state.beginRecording()
        defer { state.endRecording() }
        let value = try await body()
        return (value, Reading(bytesByPath: state.snapshot()))
    }
}
