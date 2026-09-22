import Foundation

/// The `URLSession` every book provider and content lookup must use instead of
/// `URLSession.shared`.
///
/// WHY THIS EXISTS: `URLSession.shared` defaults to `timeoutIntervalForRequest = 60`. Because
/// `BookSearchCoordinator` fans out to all providers and waits for the whole task group, a
/// single unreachable provider held the entire search open for a full minute before the user
/// saw anything — the slowest provider, not the fastest, decided how long a search took.
///
/// These timeouts are deliberately aggressive: book search is an interactive, type-ahead
/// operation where a provider that hasn't answered in a few seconds is worth abandoning. A
/// provider that times out simply contributes no results (the coordinator maps every failure
/// to an empty array), so the cost of being wrong here is a few missing suggestions, never an
/// error.
enum ProviderSession {
    /// Per-request ceiling. Anything slower than this is treated as unavailable.
    static let requestTimeout: TimeInterval = 8

    /// Whole-resource ceiling, including redirects and retries.
    static let resourceTimeout: TimeInterval = 12

    static let shared: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        // Providers are queried in parallel; without a raised per-host cap the default (4 on
        // iOS) would serialize requests that happen to share a host.
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = false
        config.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: config)
    }()
}
