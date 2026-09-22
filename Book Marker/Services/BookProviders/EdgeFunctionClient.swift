import Foundation

/// Shared helper for calling this app's own Supabase Edge Functions — the only place providers
/// that need a private third-party API key (Google Books, Europeana, ...) are allowed to reach
/// the network from. The private key itself lives only in the Edge Function's server-side
/// secrets; the iOS app never sees it (see SECRETS_SETUP.md).
///
/// Every call is authenticated with the current user's session token, matching the Edge
/// Functions' own requirement to authenticate the caller before doing any work.
enum EdgeFunctionClient {
    enum ClientError: Error {
        case notAuthenticated
        case invalidResponse
        case serverError(status: Int, message: String?)
    }

    /// Invokes `functions/v1/<name>` with the given query parameters and decodes the JSON body.
    /// Returns nil (rather than throwing) when there's no signed-in user, so callers can treat
    /// a key-gated provider as simply "unavailable right now" instead of a hard failure.
    static func invoke<T: Decodable>(_ name: String, query: [String: String]) async throws -> T? {
        guard let session = try? await AuthManager.shared.client.auth.session else {
            return nil
        }

        var components = URLComponents(url: SupabaseConfig.projectURL.appendingPathComponent("functions/v1/\(name)"), resolvingAgainstBaseURL: false)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw ClientError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(SupabaseConfig.anonKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await ProviderSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }

        guard (200...299).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            throw ClientError.serverError(status: http.statusCode, message: message)
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}
