import Foundation

public struct UpstreamRelease: Equatable, Sendable {
    public let version: SemanticVersion
    public let releaseNotesURL: URL
}

/// The outcome of an upstream lookup.
///
/// Deliberately not `UpstreamRelease?`. With a bare optional, "the user has
/// not consented to update checks" and "GitHub did not answer" are the same
/// value, so `EngineFreshnessCheck` could only tell the user
///
///   "This may be because update checks are turned off, this Mac is offline,
///    or GitHub did not respond — this app can't tell which."
///
/// which is false: consent is the app's own setting, and it always knows it.
/// Every user read that sentence, on every launch, because the flag was
/// hardcoded off and no toggle existed anywhere. Separating the cases is what
/// lets the check say which one actually happened, and offer the setting as
/// the fix when the setting is the cause.
public enum UpstreamLookupResult: Equatable, Sendable {
    case release(UpstreamRelease)
    /// Nothing was sent: the user has not turned update checks on.
    case checksDisabled
    /// A request was attempted and produced no usable answer — offline,
    /// GitHub unreachable, rate-limited, or an unexpected response shape.
    case lookupFailed
}

public protocol UpstreamVersionProviding: Sendable {
    func latestRelease(repository: String) async -> UpstreamLookupResult
}

/// Looks up the latest release of a GitHub repository.
///
/// This is the only network call in the app. It is gated behind explicit user
/// consent (`isEnabled`) and returns nil — never an error — when consent is off,
/// the network is down, or the response is unexpected. PROPOSAL.md §6 B.
///
/// What actually goes out, once consent is on: a single GET to
/// `https://api.github.com/repos/<repository>/releases/latest`, with a fixed
/// `Accept`, a fixed `User-Agent` that names only the app (no OS build, no
/// per-machine identifier — verified on the raw wire in
/// `UpstreamVersionSourceTests`, since CFNetwork fills in its own `User-Agent`
/// and `Accept-Language` below the level a `URLProtocol` stub can see or
/// override), and a fixed `Accept-Language` that does not reveal the user's
/// system locale. No request body, no cookies, no credentials. The default
/// session is ephemeral, so nothing about this call is written to disk either.
public struct GitHubReleaseSource: UpstreamVersionProviding {
    private let session: URLSession
    private let isEnabled: @Sendable () -> Bool
    private let baseURL: URL

    /// Identifies the app to GitHub's API, not the machine it runs on. GitHub
    /// requires *some* User-Agent on api.github.com; CFNetwork's default one
    /// embeds the OS build (e.g. "CFNetwork/3860.600.21 Darwin/25.5.0"), which is
    /// exactly the kind of machine fingerprint this call must not send.
    private static let userAgent = "SOPS-GUI-HealthCheck/1.0"

    /// Fixed, not derived from `Locale.current` — sending the user's actual
    /// system language preference to GitHub is not part of this call's contract.
    private static let acceptLanguage = "en"

    private static let productionBaseURL = URL(string: "https://api.github.com")!

    public init(session: URLSession = URLSession(configuration: .ephemeral),
                isEnabled: @escaping @Sendable () -> Bool) {
        self.init(session: session, baseURL: Self.productionBaseURL, isEnabled: isEnabled)
    }

    /// Test-only seam: lets tests point this at a loopback listener to observe
    /// what actually reaches the wire, instead of the real GitHub host. Not part
    /// of the public interface.
    init(session: URLSession, baseURL: URL, isEnabled: @escaping @Sendable () -> Bool) {
        self.session = session
        self.baseURL = baseURL
        self.isEnabled = isEnabled
    }

    /// Test-only accessor for the session actually in use, so a test can verify
    /// what the default (no-argument) initializer installs without a network call.
    var sessionForTesting: URLSession { session }

    public func latestRelease(repository: String) async -> UpstreamLookupResult {
        // Checked before anything else, so "disabled" can never be reported
        // as a failed lookup and no request is built, let alone sent.
        guard isEnabled() else { return .checksDisabled }
        guard let url = URL(string: "\(baseURL.absoluteString)/repos/\(repository)/releases/latest") else {
            return .lookupFailed
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")

        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let release = Self.parseRelease(from: data)
        else { return .lookupFailed }

        return .release(release)
    }

    public static func parseRelease(from data: Data) -> UpstreamRelease? {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let version = SemanticVersion(parsing: payload.tag_name),
              let url = URL(string: payload.html_url),
              url.scheme == "https"
        else { return nil }
        return UpstreamRelease(version: version, releaseNotesURL: url)
    }
}
