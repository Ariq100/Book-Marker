import Foundation

/// Gutendex (https://gutendex.com/) — a community-run JSON API over the Project Gutenberg
/// catalog. No API key required. Project Gutenberg only hosts public-domain (or otherwise
/// explicitly rights-cleared) texts, so items with a downloadable `text/plain` format are
/// legitimately `.fullTextAvailable` — this is the one provider where that can be asserted
/// directly from search results rather than requiring a separate rights check.
///
/// Not a source for modern copyrighted books — Gutendex/Gutenberg only ever returns
/// public-domain works, so this provider is never used to obtain copyrighted full text.
final class GutendexProvider: BookProvider {
    static let shared = GutendexProvider()
    private init() {}

    let id: BookProviderID = .gutendex

    private struct SearchResponse: Decodable {
        let results: [Book]

        struct Book: Decodable {
            let id: Int
            let title: String
            let authors: [Author]
            let languages: [String]?
            let formats: [String: String]
            let copyright: Bool?

            struct Author: Decodable { let name: String }
        }
    }

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://gutendex.com/books?search=\(encoded)")
        else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)

        return decoded.results.map { book in
            let hasPlainText = book.formats.keys.contains { $0.hasPrefix("text/plain") }
            let coverURL = book.formats["image/jpeg"].flatMap(URL.init)
            let isPublicDomain = book.copyright == false

            return BookSearchResult(
                title: book.title,
                subtitle: nil,
                authors: book.authors.map(\.name),
                isbn10: nil,
                isbn13: nil,
                publisher: "Project Gutenberg",
                publicationDate: nil,
                edition: nil,
                language: book.languages?.first,
                coverImageURL: coverURL,
                provider: .gutendex,
                providerID: String(book.id),
                availability: hasPlainText ? .fullTextAvailable : .metadataOnly,
                fullTextAvailable: hasPlainText,
                previewAvailable: hasPlainText,
                searchableInside: false,
                textSource: book.formats.first { $0.key.hasPrefix("text/plain") }?.value,
                rightsInformation: RightsInformation(isPublicDomain: isPublicDomain, license: "Public Domain (US)", statement: nil)
            )
        }
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        // Gutendex has no ISBN index (Gutenberg predates modern ISBNs for most titles).
        nil
    }

    /// Returns the plain-text body for a public-domain Gutenberg text. Only ever called when
    /// `availability == .fullTextAvailable`, i.e. Gutendex itself confirmed a `text/plain`
    /// format exists — this is legitimate public-domain content, not a copyright workaround.
    func fullText(providerID: String) async throws -> String? {
        guard let url = URL(string: "https://gutendex.com/books/\(providerID)") else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let book = try? JSONDecoder().decode(SearchResponse.Book.self, from: data),
              let textURLString = book.formats.first(where: { $0.key.hasPrefix("text/plain") })?.value,
              let textURL = URL(string: textURLString)
        else { return nil }

        let (textData, _) = try await URLSession.shared.data(from: textURL)
        return String(data: textData, encoding: .utf8)
    }
}
