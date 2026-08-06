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

    @Test("makes no network request at all when the user has not consented")
    func respectsConsent() async {
        RecordingURLProtocol.reset()
        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { false })

        let result = await source.latestRelease(repository: "getsops/sops")

        #expect(result == nil)
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

        #expect(result?.version == SemanticVersion(3, 13, 3))

        let requests = RecordingURLProtocol.recordedRequests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        #expect(request.url == expectedURL)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("a rate-limited (403) response yields nil, not an error")
    func rateLimitedYieldsNil() async {
        RecordingURLProtocol.reset()
        let url = URL(string: "https://api.github.com/repos/getsops/sops/releases/latest")!
        RecordingURLProtocol.stub(url, data: Data("{\"message\":\"rate limited\"}".utf8), statusCode: 403)

        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { true })

        #expect(await source.latestRelease(repository: "getsops/sops") == nil)
    }

    @Test("an unknown repository (404) response yields nil, not an error")
    func unknownRepositoryYieldsNil() async {
        RecordingURLProtocol.reset()
        let url = URL(string: "https://api.github.com/repos/FiloSottile/age/releases/latest")!
        RecordingURLProtocol.stub(url, data: Data("{\"message\":\"Not Found\"}".utf8), statusCode: 404)

        let session = RecordingURLProtocol.makeSession()
        let source = GitHubReleaseSource(session: session, isEnabled: { true })

        #expect(await source.latestRelease(repository: "FiloSottile/age") == nil)
    }
}
