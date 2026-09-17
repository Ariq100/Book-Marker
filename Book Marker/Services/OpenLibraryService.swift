import Foundation

/// Open Library (https://openlibrary.org/developers/api) — no API key required for the public
/// endpoints used here. Per Open Library's usage guidelines we identify the app with a
/// descriptive User-Agent and avoid bulk/aggressive requests; results that power the quote
/// autocomplete dropdown (`BookContentService`) are cached in-memory per session.
final class OpenLibraryService: BookProvider {
    static let shared = OpenLibraryService()
    private init() {}

    let id: BookProviderID = .openLibrary

    private static let userAgent = "BookMarker-iOS/1.0 (+contact: not-yet-configured; see Config.swift)"

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Private decodable types (search.json)

    private struct SearchResponse: Decodable {
        let docs: [Doc]

        struct Doc: Decodable {
            let key: String
            let title: String
            let author_name: [String]?
            let cover_i: Int?
            let first_publish_year: Int?
            let isbn: [String]?
            let publisher: [String]?
            let language: [String]?
            let ia: [String]?   // Internet Archive identifiers, when a scan exists
        }
    }

    // MARK: - Private decodable types (ISBN "Books API")

    private struct ISBNLookupResponse: Decodable {
        struct BookRecord: Decodable {
            struct NamedRef: Decodable { let name: String }
            struct Cover: Decodable { let small: String?; let medium: String?; let large: String? }

            let title: String
            let subtitle: String?
            let authors: [NamedRef]?
            let publishers: [NamedRef]?
            let publish_date: String?
            let cover: Cover?
        }
    }

    // MARK: - BookProvider

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        try await search(query: query)
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        let cleaned = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard !cleaned.isEmpty,
              let url = URL(string: "https://openlibrary.org/api/books?bibkeys=ISBN:\(cleaned)&format=json&jscmd=data")
        else { return nil }

        let (data, _) = try await URLSession.shared.data(for: makeRequest(url))
        let decoded = try JSONDecoder().decode([String: ISBNLookupResponse.BookRecord].self, from: data)
        guard let record = decoded["ISBN:\(cleaned)"] else { return nil }

        let coverURL = record.cover?.large.flatMap(URL.init) ?? record.cover?.medium.flatMap(URL.init)
        let isbn13 = cleaned.count == 13 ? cleaned : nil
        let isbn10 = cleaned.count == 10 ? cleaned : nil

        return BookSearchResult(
            title: record.title,
            subtitle: record.subtitle,
            authors: record.authors?.map(\.name) ?? [],
            isbn10: isbn10,
            isbn13: isbn13,
            publisher: record.publishers?.first?.name,
            publicationDate: record.publish_date,
            edition: nil,
            language: nil,
            coverImageURL: coverURL,
            provider: .openLibrary,
            providerID: "ISBN:\(cleaned)",
            availability: .metadataOnly,
            fullTextAvailable: false,
            previewAvailable: false,
            searchableInside: false,
            textSource: nil,
            rightsInformation: nil
        )
    }

    /// Best-effort "search inside" using Open Library's experimental Search Inside API
    /// (https://openlibrary.org/dev/docs/api/search_inside), which actually runs on Internet
    /// Archive's `fulltext/inside.php` endpoint and requires a scanned edition's IA identifier —
    /// not every book has one. This endpoint is explicitly experimental and may change or
    /// disappear upstream; failures here are swallowed (empty result) rather than surfaced,
    /// since the caller should treat "search inside" as a nice-to-have, not a guarantee.
    func searchInsideBook(providerID: String, query: String) async throws -> [String] {
        // `providerID` here is expected to be an Internet Archive identifier (see `ia` field
        // returned by search). Resolving an arbitrary Open Library work key to an IA id would
        // require an extra edition lookup, which callers should do via `InternetArchiveProvider`.
        //
        // The inside.php host is per-item (e.g. "ia601409.us.archive.org"), so it must be
        // discovered from the item's metadata first — there is no fixed/global host.
        guard let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }

        guard let metadataURL = URL(string: "https://archive.org/metadata/\(providerID)"),
              let (metadataData, _) = try? await URLSession.shared.data(for: makeRequest(metadataURL)),
              let metadata = try? JSONSerialization.jsonObject(with: metadataData) as? [String: Any],
              let server = metadata["server"] as? String,
              let dir = metadata["dir"] as? String
        else { return [] }

        guard let url = URL(string: "https://\(server)/fulltext/inside.php?item_id=\(providerID)&doc=\(providerID)&path=\(dir)&q=\(encodedQuery)")
        else { return [] }

        guard let (data, response) = try? await URLSession.shared.data(for: makeRequest(url)),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = json["matches"] as? [[String: Any]]
        else { return [] }

        return matches.compactMap { $0["text"] as? String }
    }

    // MARK: - Existing search (kept source-compatible; now returns the richer BookSearchResult)

    func search(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://openlibrary.org/search.json?q=\(encoded)&limit=20")
        else { return [] }

        let (data, _) = try await URLSession.shared.data(for: makeRequest(url))
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)

        return response.docs.map { doc in
            let coverURL = doc.cover_i.flatMap {
                URL(string: "https://covers.openlibrary.org/b/id/\($0)-M.jpg")
            }
            let isbns = doc.isbn ?? []
            return BookSearchResult(
                title: doc.title,
                subtitle: nil,
                authors: doc.author_name ?? [],
                isbn10: isbns.first { $0.count == 10 },
                isbn13: isbns.first { $0.count == 13 },
                publisher: doc.publisher?.first,
                publicationDate: doc.first_publish_year.map(String.init),
                edition: nil,
                language: doc.language?.first,
                coverImageURL: coverURL,
                provider: .openLibrary,
                providerID: doc.key,
                availability: .metadataOnly,
                fullTextAvailable: false,
                previewAvailable: false,
                searchableInside: !(doc.ia ?? []).isEmpty,
                textSource: doc.ia?.first,
                rightsInformation: nil
            )
        }
    }

    // MARK: - Cover Image

    /// Downloads the cover image data for a given coverID and size suffix ("S", "M", "L").
    func downloadCoverData(coverID: Int, sizeSuffix: String = "M") async -> Data? {
        guard let url = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-\(sizeSuffix).jpg") else {
            return nil
        }
        return try? await URLSession.shared.data(for: makeRequest(url)).0
    }

    /// Downloads cover image data from an arbitrary cover URL (used for non-Open-Library
    /// providers, whose results carry a direct image URL rather than a numeric cover ID).
    func downloadCoverData(from url: URL) async -> Data? {
        try? await URLSession.shared.data(for: makeRequest(url)).0
    }
}
