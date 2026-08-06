import Foundation

public struct UpstreamRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseNotesURL: URL
}

public protocol UpstreamVersionProviding: Sendable {
    func latestRelease(repository: String) async -> UpstreamRelease?
}

/// Looks up the latest release of a GitHub repository.
///
/// This is the only network call in the app. It is gated behind explicit user
/// consent (`isEnabled`) and returns nil — never an error — when consent is off,
/// the network is down, or the response is unexpected. PROPOSAL.md §6 B.
public struct GitHubReleaseSource: UpstreamVersionProviding {
    private let session: URLSession
    private let isEnabled: @Sendable () -> Bool

    public init(session: URLSession = .shared, isEnabled: @escaping @Sendable () -> Bool) {
        self.session = session
        self.isEnabled = isEnabled
    }

    public func latestRelease(repository: String) async -> UpstreamRelease? {
        guard isEnabled() else { return nil }
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        return Self.parseRelease(from: data)
    }

    public static func parseRelease(from data: Data) -> UpstreamRelease? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(parsing: payload.tag_name),
              let url = URL(string: payload.html_url)
        else { return nil }
        return UpstreamRelease(version: version, releaseNotesURL: url)
    }
}
