import Foundation
import Testing
@testable import SopsHealth

/// Records every request that reaches a *specific, instrumented* `URLSession`
/// — never a globally registered one.
///
/// `Scripts/test-network-denied.sh`'s own header names the gap this closes:
/// the sandboxed run proves a denied network doesn't break the health suite,
/// but not that the app never *attempts* a request, because failures swallow
/// into `.lookupFailed` and the existing consent tests
/// (`UpstreamVersionSourceTests`) drive `RecordingURLProtocol` on a session
/// they build themselves, never on the one `HealthReport.standard` actually
/// wires up for the app.
///
/// The obvious fix — `URLProtocol.registerClass()`, once, process-wide — does
/// not work here. Measured directly with a throwaway spike (register a class,
/// fire a request through `URLSession.shared`, `URLSession(configuration:
/// .default)`, and `URLSession(configuration: .ephemeral)`, and check which
/// ones the class actually sees): only `URLSession.shared` is intercepted.
/// Neither an explicit `.default`-configuration session nor an `.ephemeral`
/// one is, unless that session's own `protocolClasses` names the class. And
/// `.ephemeral` is exactly what `GitHubReleaseSource`'s production
/// initializer builds (`UpstreamVersionSource.swift`) — the one and only
/// place in this app that constructs a `URLSession` at all, per
/// `constructsExactlyOneURLSession` below. A global `registerClass` would
/// therefore read "zero requests" whether or not one was actually made on
/// that session: an observation point with exactly the hole that matters,
/// which is worse than no observation point, because it reads as proof.
///
/// So this recorder is attached the same way `RecordingURLProtocol` already
/// is in `UpstreamVersionSourceTests` — as a named entry in one session's own
/// `protocolClasses` — and that session is handed to the *real* production
/// call chain via `HealthReport.standard`'s `upstream:` seam (see that
/// function's doc comment), so what runs is `EngineFreshnessCheck` calling
/// the real, unmodified `GitHubReleaseSource.latestRelease`, not a stand-in
/// for it.
///
/// A separate class from `RecordingURLProtocol`, deliberately: `URLProtocol`
/// state is per-class static storage, not per-instance, so two suites that
/// each register their own session-scoped class don't share state and don't
/// need to coordinate `.serialized` ordering with each other — only within
/// themselves, which the `@Suite` below still does, for the same reason
/// `UpstreamVersionSourceTests` does.
final class FullReportRequestRecorder: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _recordedRequests: [URLRequest] = []

    static var recordedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recordedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _recordedRequests = []
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FullReportRequestRecorder.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._recordedRequests.append(request)
        Self.lock.unlock()
        // Fail closed rather than let anything that does reach this session
        // escape to the real network — same contract as
        // `RecordingURLProtocol`'s unstubbed branch.
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

@Suite("Full health report makes zero requests with consent off", .serialized)
struct FullReportNetworkGuardTests {

    /// The proof problem 2 of ticket #21 asked for: not "the outcome is
    /// correct" (that was already covered) but "nothing was attempted".
    ///
    /// Uses the real `HealthReport.standard` — the same construction
    /// `App/SopsGUIApp.swift` calls — with every check that has one running
    /// for real (`ExternalToolCheck` spawns the real CLIs on this machine;
    /// `SecurityPostureCheck` and `ProjectHealthCheck` run their real logic
    /// against an empty project set). The only substitution is the session
    /// backing `GitHubReleaseSource`, and that substitution changes nothing
    /// about the logic under test — `latestRelease` checks `isEnabled()`
    /// before doing anything else, for the real reason stated in its own doc
    /// comment, not because a test asked it to.
    @Test("running the standard report end to end, with consent off, sends nothing to the URL loading system")
    func standardReportWithConsentOffSendsNothing() async {
        FullReportRequestRecorder.reset()

        let upstream = GitHubReleaseSource(
            session: FullReportRequestRecorder.makeSession(),
            baseURL: URL(string: "https://api.github.com")!,
            isEnabled: { false })

        let report = HealthReport.standard(
            updateChecksEnabled: { false },
            keyStore: UnshippedKeyStore(),
            appUpdates: UnshippedAppUpdates(),
            upstream: upstream)

        let findings = await report.run()

        // Not vacuous: the report actually ran checks (and, in particular,
        // asked the engine-freshness check to run, which is the one that
        // could have touched the network).
        #expect(!findings.isEmpty)
        #expect(findings.contains { $0.id.hasPrefix("engine.") })

        let requests = FullReportRequestRecorder.recordedRequests
        #expect(requests.isEmpty,
                "a full health report with consent off reached the URL loading system: \(requests.map { $0.url?.absoluteString ?? "?" })")
    }

    /// Closes the hole this suite's own header names: an observation point
    /// only proves something if a request made outside its knowledge is
    /// still invisible to *every other* test in the suite. This is that
    /// audit, done once as a standing test rather than trusted as a one-time
    /// grep — a second `URLSession(` added anywhere else in `Sources/` in the
    /// future, ephemeral or not, would not be reached by the seam above, and
    /// this is what would say so.
    @Test("the app constructs a URLSession in exactly one place")
    func constructsExactlyOneURLSession() throws {
        // …/Tests/SopsHealthTests/<this file> → …/Sources
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SopsHealthTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // SopsGUIKit
            .appendingPathComponent("Sources")
        #expect(FileManager.default.fileExists(atPath: sources.path),
                "sanity: expected this package's Sources at \(sources.path)")

        let enumerator = try #require(FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil))

        var filesConstructingASession: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let contents = try String(contentsOf: url, encoding: .utf8)
            if contents.contains("URLSession(") {
                filesConstructingASession.append(url.lastPathComponent)
            }
        }

        #expect(filesConstructingASession == ["UpstreamVersionSource.swift"],
                "expected exactly UpstreamVersionSource.swift to construct a URLSession, found: \(filesConstructingASession.sorted())")
    }
}
