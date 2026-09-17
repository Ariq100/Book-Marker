import Foundation

/// Europeana (https://pro.europeana.eu/page/apis) — requires a free registered API key
/// (`wskey`). Like Google Books, that key must never ship inside the iOS app, so this provider
/// calls this app's own `search-europeana` Supabase Edge Function, which holds the key
/// server-side. Used for metadata and legally available cultural-heritage/digital content.
///
/// See SECRETS_SETUP.md for how to obtain and configure `EUROPEANA_API_KEY`.
final class EuropeanaProvider: BookProvider {
    static let shared = EuropeanaProvider()
    private init() {}

    let id: BookProviderID = .europeana

    private struct EdgeBookDTO: Decodable {
        let title: String
        let authors: [String]
        let publisher: String?
        let publicationDate: String?
        let language: String?
        let coverImageURL: String?
        let providerID: String
        let availability: String
        let rightsStatement: String?
    }

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        guard let results: [EdgeBookDTO] = try await EdgeFunctionClient.invoke(
            "search-europeana",
            query: ["q": trimmed]
        ) else { return [] }

        return results.map { dto in
            BookSearchResult(
                title: dto.title,
                subtitle: nil,
                authors: dto.authors,
                isbn10: nil,
                isbn13: nil,
                publisher: dto.publisher,
                publicationDate: dto.publicationDate,
                edition: nil,
                language: dto.language,
                coverImageURL: dto.coverImageURL.flatMap(URL.init),
                provider: .europeana,
                providerID: dto.providerID,
                availability: ContentAvailability(rawValue: dto.availability) ?? .metadataOnly,
                fullTextAvailable: false,
                previewAvailable: dto.availability == "previewOnly",
                searchableInside: false,
                textSource: nil,
                rightsInformation: dto.rightsStatement.map { RightsInformation(isPublicDomain: nil, license: nil, statement: $0) }
            )
        }
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        try await searchBooks(query: isbn).first
    }
}
