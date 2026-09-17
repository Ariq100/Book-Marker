import Foundation

/// Google Books (https://developers.google.com/books/docs/v1/using) — per current
/// documentation, public search requests must be accompanied by an API key. That key is a
/// private credential (tied to a Google Cloud project's quota) and must never ship inside the
/// iOS app, so this provider never calls Google directly: it calls this app's own
/// `search-google-books` Supabase Edge Function, which holds the key server-side.
///
/// See SECRETS_SETUP.md for how to create and configure `GOOGLE_BOOKS_API_KEY`.
final class GoogleBooksProvider: BookProvider {
    static let shared = GoogleBooksProvider()
    private init() {}

    let id: BookProviderID = .googleBooks

    private struct EdgeBookDTO: Decodable {
        let title: String
        let subtitle: String?
        let authors: [String]
        let isbn10: String?
        let isbn13: String?
        let publisher: String?
        let publicationDate: String?
        let language: String?
        let coverImageURL: String?
        let providerID: String
        let availability: String
        let fullTextAvailable: Bool
        let previewAvailable: Bool
        let textSource: String?
        let rightsStatement: String?
    }

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        guard let results: [EdgeBookDTO] = try await EdgeFunctionClient.invoke(
            "search-google-books",
            query: ["q": trimmed]
        ) else { return [] }

        return results.map(map(_:))
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        guard let results: [EdgeBookDTO] = try await EdgeFunctionClient.invoke(
            "search-google-books",
            query: ["isbn": isbn]
        ) else { return nil }
        return results.first.map(map(_:))
    }

    private func map(_ dto: EdgeBookDTO) -> BookSearchResult {
        BookSearchResult(
            title: dto.title,
            subtitle: dto.subtitle,
            authors: dto.authors,
            isbn10: dto.isbn10,
            isbn13: dto.isbn13,
            publisher: dto.publisher,
            publicationDate: dto.publicationDate,
            edition: nil,
            language: dto.language,
            coverImageURL: dto.coverImageURL.flatMap(URL.init),
            provider: .googleBooks,
            providerID: dto.providerID,
            availability: ContentAvailability(rawValue: dto.availability) ?? .metadataOnly,
            fullTextAvailable: dto.fullTextAvailable,
            previewAvailable: dto.previewAvailable,
            searchableInside: false,
            textSource: dto.textSource,
            rightsInformation: dto.rightsStatement.map { RightsInformation(isPublicDomain: nil, license: nil, statement: $0) }
        )
    }
}
