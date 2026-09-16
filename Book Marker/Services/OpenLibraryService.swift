import Foundation

struct BookSearchResult: Identifiable {
    let id: String       // Open Library key, e.g. "/works/OL12345W"
    let title: String
    let author: String
    let coverID: Int?
    let firstPublishYear: Int?

    /// The Open Library Work ID — same as `id`, exposed separately for clarity
    var olid: String { id }
}

final class OpenLibraryService {
    static let shared = OpenLibraryService()
    private init() {}

    // MARK: - Private decodable types

    private struct SearchResponse: Decodable {
        let docs: [Doc]

        struct Doc: Decodable {
            let key: String
            let title: String
            let author_name: [String]?
            let cover_i: Int?
            let first_publish_year: Int?
        }
    }

    // MARK: - Public API

    func search(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://openlibrary.org/search.json?q=\(encoded)&limit=20")
        else { return [] }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)

        return response.docs.map { doc in
            BookSearchResult(
                id: doc.key,
                title: doc.title,
                author: doc.author_name?.first ?? "Unknown Author",
                coverID: doc.cover_i,
                firstPublishYear: doc.first_publish_year
            )
        }
    }

    // MARK: - Cover Image

    /// Downloads the cover image data for a given coverID and size suffix ("S", "M", "L").
    func downloadCoverData(coverID: Int, sizeSuffix: String = "M") async -> Data? {
        guard let url = URL(string: "https://covers.openlibrary.org/b/id/\(coverID)-\(sizeSuffix).jpg") else {
            return nil
        }
        return try? await URLSession.shared.data(from: url).0
    }
}
