import Foundation
import Testing
@testable import SopsHealth

/// Records every request that reaches the URL loading system and can serve a
/// canned response for it, so tests can prove *whether a request was made at
/// all* rather than just inspecting the outcome. Registered on an ephemeral
/// `URLSessionConfiguration`, so nothing here ever touches the real network.
///
/// State is process-wide (URLProtocol is a class registered with the loading
/// system, not an instance we control), so the suite runs serialized to keep
/// tests from observing each other's requests/stubs.
final class RecordingURLProtocol: URLProtocol, @unchecked Sendable {
    private struct Stub {
        let data: Data
        let statusCode: Int
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _recordedRequests: [URLRequest] = []
    nonisolated(unsafe) private static var _stubs: [URL: Stub] = [:]

    static var recordedRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return _recordedRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _recordedRequests = []
        _stubs = [:]
    }

    static func stub(_ url: URL, data: Data, statusCode: Int) {
        lock.lock(); defer { lock.unlock() }
        _stubs[url] = Stub(data: data, statusCode: statusCode)
    }

    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self._recordedRequests.append(request)
        let stub = request.url.flatMap { Self._stubs[$0] }
        Self.lock.unlock()

        guard let stub, let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: stub.statusCode, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            // No stub registered for this URL: fail closed rather than let the
            // request escape to the real network.
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Captures the raw plaintext bytes of exactly one incoming loopback TCP
/// connection and answers with a canned HTTP response.
///
/// `URLProtocol` intercepts requests *above* CFNetwork's own header injection
/// (see the reviewer's finding that `User-Agent`/`Accept-Language` get added
/// below that layer), so it cannot see what actually leaves the process. This
/// listens on `127.0.0.1` only — never a real network interface — and reads
/// what genuinely went out on the wire, byte for byte.
///
/// Built on raw BSD sockets rather than `Network.framework`: `NWListener`
/// consistently failed with `POSIXErrorCode(rawValue: 22)` ("Invalid
/// argument") in this environment even with no sandbox restriction in play,
/// while a plain `socket()`/`bind()`/`listen()` on `127.0.0.1` works
/// normally. Verified with a standalone repro before writing this class.
final class LoopbackHTTPCapture: @unchecked Sendable {
    struct CaptureFailure: Error, CustomStringConvertible {
        let description: String
    }

    let port: UInt16
    private let responseBody: Data
    private let listenSocket: Int32
    private let semaphore = DispatchSemaphore(value: 0)
    private var capturedRequestText = ""

    init(responseBody: Data) throws {
        self.responseBody = responseBody

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw CaptureFailure(description: "socket() failed: errno \(errno)")
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0 // ask the OS for an ephemeral port

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw CaptureFailure(description: "bind() on 127.0.0.1 failed: errno \(errno)")
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                _ = getsockname(fd, sa, &len)
            }
        }

        guard listen(fd, 1) == 0 else {
            close(fd)
            throw CaptureFailure(description: "listen() failed: errno \(errno)")
        }

        // Only assign stored properties above this point; `self` is not fully
        // initialized until they're all set, and beginAccepting() below
        // escapes `self` into a background thread.
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.listenSocket = fd

        beginAccepting()
    }

    private func beginAccepting() {
        Thread.detachNewThread { [self] in
            let client = accept(listenSocket, nil, nil)
            guard client >= 0 else {
                semaphore.signal()
                return
            }
            defer { close(client) }

            var buffer = [UInt8](repeating: 0, count: 65536)
            var received = Data()
            while !String(decoding: received, as: UTF8.self).contains("\r\n\r\n") {
                let n = read(client, &buffer, buffer.count)
                guard n > 0 else { break }
                received.append(contentsOf: buffer[0..<n])
            }
            capturedRequestText = String(decoding: received, as: UTF8.self)

            let header = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(responseBody.count)\r\nConnection: close\r\n\r\n"
            var full = Data(header.utf8)
            full.append(responseBody)
            full.withUnsafeBytes { raw in
                _ = write(client, raw.baseAddress, raw.count)
            }
            semaphore.signal()
        }
    }

    /// Blocks the calling (background) thread until one request has been
    /// captured and answered, or the timeout elapses.
    func waitForRequest(timeout: TimeInterval = 5) -> String? {
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return capturedRequestText
    }

    func stop() {
        close(listenSocket)
    }

    /// Cheap capability probe: true if this process can actually bind a
    /// loopback TCP socket right now. Some environments — a hardened CI
    /// runner, a network-denied sandbox — refuse even loopback binding; in
    /// those, the wire-capture test should skip, not fail, since a bind
    /// refusal there says nothing about whether `GitHubReleaseSource` sets
    /// its headers correctly.
    static func canBindLoopback() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        addr.sin_port = 0

        return withUnsafePointer(to: &addr) { ptr -> Bool in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

@Suite("GitHubReleaseSource", .serialized)
struct UpstreamVersionSourceTests {

    // Trimmed shape of the real api.github.com/repos/getsops/sops/releases/latest response.
    private let realPayload = Data("""
    {
      "tag_name": "v3.13.3",
      "published_at": "2026-07-23T05:27:57Z",
      "html_url": "https://github.com/getsops/sops/releases/tag/v3.13.3"
    }
    """.utf8)

    @Test("parses a real GitHub release payload")
    func parsesRealPayload() throws {
        let release = try #require(GitHubReleaseSource.parseRelease(from: realPayload))
        #expect(release.version == SemanticVersion(3, 13, 3))
        #expect(release.releaseNotesURL.absoluteString == "https://github.com/getsops/sops/releases/tag/v3.13.3")
    }

    @Test("returns nil for malformed or truncated payloads instead of crashing")
    func toleratesGarbage() {
        #expect(GitHubReleaseSource.parseRelease(from: Data("not json".utf8)) == nil)
        #expect(GitHubReleaseSource.parseRelease(from: Data("{}".utf8)) == nil)
    }

    @Test("rejects a non-https release URL, e.g. javascript:, rather than passing it through")
    func rejectsJavascriptScheme() {
        let payload = Data("""
        {
          "tag_name": "v3.13.3",
          "html_url": "javascript:alert(1)"
        }
        """.utf8)
        #expect(GitHubReleaseSource.parseRelease(from: payload) == nil)
    }

    @Test("rejects a plain http release URL, not just non-URL schemes")
    func rejectsHTTPScheme() {
        let payload = Data("""
        {
          "tag_name": "v3.13.3",
          "html_url": "http://github.com/getsops/sops/releases/tag/v3.13.3"
        }
        """.utf8)
        #expect(GitHubReleaseSource.parseRelease(from: payload) == nil)
    }

    @Test("makes no network request at all when the user has not consented")
    func respectsConsent() async {
        RecordingURLProtocol.reset()
        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { false })

        let result = await source.latestRelease(repository: "getsops/sops")

        // `.checksDisabled`, not a generic failure: the check downstream tells
        // the user *which* of the two happened, and can only do that if this
        // distinction survives the return.
        #expect(result == .checksDisabled)
        #expect(RecordingURLProtocol.recordedRequests.isEmpty,
                "no request should reach the URL loading system when consent is off")
    }

    @Test("makes exactly one minimal request when the user has consented")
    func makesRequestWhenConsented() async throws {
        RecordingURLProtocol.reset()
        let expectedURL = URL(string: "https://api.github.com/repos/getsops/sops/releases/latest")!
        RecordingURLProtocol.stub(expectedURL, data: realPayload, statusCode: 200)

        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { true })

        let result = await source.latestRelease(repository: "getsops/sops")

        guard case .release(let release) = result else {
            Issue.record("expected a release, got \(result)")
            return
        }
        #expect(release.version == SemanticVersion(3, 13, 3))

        let requests = RecordingURLProtocol.recordedRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == expectedURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "SOPS-GUI-HealthCheck/1.0")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a rate-limited (403) response yields a failed lookup, not an error")
    func rateLimitedYieldsNil() async {
        RecordingURLProtocol.reset()
        let url = URL(string: "https://api.github.com/repos/getsops/sops/releases/latest")!
        RecordingURLProtocol.stub(url, data: Data("{\"message\":\"rate limited\"}".utf8), statusCode: 403)

        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { true })

        // A failed lookup, never `.checksDisabled` — consent is on here, and
        // blaming the setting would send the user to change something that is
        // already correct.
        #expect(await source.latestRelease(repository: "getsops/sops") == .lookupFailed)
    }

    @Test("an unknown repository (404) response yields a failed lookup, not an error")
    func unknownRepositoryYieldsNil() async {
        RecordingURLProtocol.reset()
        let url = URL(string: "https://api.github.com/repos/FiloSottile/age/releases/latest")!
        RecordingURLProtocol.stub(url, data: Data("{\"message\":\"Not Found\"}".utf8), statusCode: 404)

        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { true })

        #expect(await source.latestRelease(repository: "FiloSottile/age") == .lookupFailed)
    }

    @Test("the default session (no session argument) persists nothing: no shared disk cookie jar, no disk cache")
    func defaultSessionDoesNotPersist() {
        let source = GitHubReleaseSource(isEnabled: { true })
        let configuration = source.sessionForTesting.configuration

        #expect(configuration.httpCookieStorage !== HTTPCookieStorage.shared,
                "must not use the disk-backed shared cookie jar that other app networking might populate")
        #expect(configuration.urlCache?.diskCapacity == 0,
                "must not cache responses to disk")
    }

    @Test(
        "the request on the wire carries a fixed User-Agent and Accept-Language, not CFNetwork's own",
        .enabled(
            if: LoopbackHTTPCapture.canBindLoopback(),
            "loopback networking unavailable in this environment"
        )
    )
    func headersOnTheWireAreFixed() async throws {
        // RecordingURLProtocol intercepts above CFNetwork's own header injection, so it
        // cannot see (or prove an override of) headers CFNetwork adds itself — this test
        // reads genuine bytes off a loopback socket instead. Loopback only, never a real
        // network interface.
        let capture = try LoopbackHTTPCapture(responseBody: realPayload)
        defer { capture.stop() }

        let baseURL = URL(string: "http://127.0.0.1:\(capture.port)")!
        let session = URLSession(configuration: .ephemeral)
        let source = GitHubReleaseSource(session: session, baseURL: baseURL, isEnabled: { true })

        let releaseTask = Task { await source.latestRelease(repository: "getsops/sops") }

        // Block a dedicated background thread, not the Swift concurrency pool,
        // while waiting for the raw bytes to arrive.
        let requestText: String? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: capture.waitForRequest(timeout: 5))
            }
        }

        let release = await releaseTask.value
        let request = try #require(requestText, "no request reached the loopback listener")

        #expect(release == .release(UpstreamRelease(
            version: SemanticVersion(3, 13, 3),
            releaseNotesURL: URL(string: "https://github.com/getsops/sops/releases/tag/v3.13.3")!)))
        #expect(request.hasPrefix("GET /repos/getsops/sops/releases/latest HTTP/1.1"))
        #expect(request.contains("User-Agent: SOPS-GUI-HealthCheck/1.0\r\n"))
        #expect(request.contains("Accept-Language: en\r\n"))
        // The property this whole test exists to prove: CFNetwork's own defaults,
        // which would leak the OS build and the user's real system language, must
        // not appear anywhere in what actually left the process.
        #expect(!request.contains("CFNetwork"))
        #expect(!request.contains("Darwin/"))
    }
}
