import Foundation

/// Library of Congress (https://www.loc.gov/apis/) — the public search API used here needs no
/// API key. Used purely for metadata/discovery (title, author, publication info, identifiers,
/// digitized-collection links); it is not a full-text source for arbitrary books.
final class LibraryOfCongressProvider: BookProvider {
    static let shared = LibraryOfCongressProvider()
    private init() {}

    let id: BookProviderID = .libraryOfCongress

    private struct SearchResponse: Decodable {
        let results: [Item]

        struct Item: Decodable {
            let id: String?
            let title: String?
            let contributor: [String]?
            let date: String?
            let language: [String]?
            let item: ItemDetail?

            struct ItemDetail: Decodable {
                let publisher: [String]?
            }
        }
    }

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.loc.gov/search/?q=\(encoded)&fo=json&fa=partof:catalog&c=20")
        else { return [] }

        var request = URLRequest(url: url)
        request.setValue("BookMarker-iOS/1.0", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await ProviderSession.shared.data(for: request)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)

        return decoded.results.compactMap { item in
            guard let title = item.title, let identifier = item.id else { return nil }
            return BookSearchResult(
                title: title,
                subtitle: nil,
                authors: item.contributor ?? [],
                isbn10: nil,
                isbn13: nil,
                publisher: item.item?.publisher?.first,
                publicationDate: item.date,
                edition: nil,
                language: item.language?.first,
                coverImageURL: nil,
                provider: .libraryOfCongress,
                providerID: identifier,
                availability: .metadataOnly,
                fullTextAvailable: false,
                previewAvailable: false,
                searchableInside: false,
                textSource: nil,
                rightsInformation: nil
            )
        }
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        try await searchBooks(query: isbn).first
    }
}
