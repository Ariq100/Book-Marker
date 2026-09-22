import Foundation

/// Internet Archive (https://archive.org/developers/) — no API key required for the public
/// search/metadata endpoints used here.
///
/// COPYRIGHT SAFETY: `searchBooks` always returns `.metadataOnly` / not-full-text-available,
/// even for items that look like they might be scanned books. Full-text/OCR availability is
/// only ever confirmed by `bookDetails(providerID:)`, which fetches the item's own metadata and
/// checks `access-restricted-item` plus whether an OCR text file is actually listed in the
/// item's files. This app never assumes an Internet Archive item is freely readable just
/// because it exists in search results — lending-restricted items are marked unavailable, not
/// downloaded or bypassed.
final class InternetArchiveProvider: BookProvider {
    static let shared = InternetArchiveProvider()
    private init() {}

    let id: BookProviderID = .internetArchive

    private static let userAgent = "BookMarker-iOS/1.0 (+contact: not-yet-configured; see Config.swift)"

    private func makeRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Decodable types

    private struct SearchResponse: Decodable {
        struct ResponseBody: Decodable { let docs: [Doc] }
        let response: ResponseBody

        struct Doc: Decodable {
            let identifier: String
            let title: String?
            let creator: StringOrArray?
            let year: String?
            let publisher: StringOrArray?
            let isbn: StringOrArray?
            let language: StringOrArray?
        }
    }

    /// Internet Archive's search API inconsistently returns either a single string or an array
    /// of strings for fields like `creator`/`isbn`/`publisher` depending on the item.
    private enum StringOrArray: Decodable {
        case one(String)
        case many([String])

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) {
                self = .one(value)
            } else {
                self = .many((try? container.decode([String].self)) ?? [])
            }
        }

        var values: [String] {
            switch self {
            case .one(let s): return [s]
            case .many(let arr): return arr
            }
        }
    }

    private struct MetadataResponse: Decodable {
        let metadata: Metadata?
        let server: String?
        let dir: String?
        let files: [FileEntry]?

        struct Metadata: Decodable {
            let accessRestrictedItem: String?
            let mediatype: String?

            enum CodingKeys: String, CodingKey {
                case accessRestrictedItem = "access-restricted-item"
                case mediatype
            }
        }

        struct FileEntry: Decodable {
            let name: String
            let format: String?
        }
    }

    // MARK: - BookProvider

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let encoded = "\(trimmed) AND mediatype:texts".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
        else { return [] }

        guard let url = URL(string: "https://archive.org/advancedsearch.php?q=\(encoded)&fl[]=identifier&fl[]=title&fl[]=creator&fl[]=year&fl[]=publisher&fl[]=isbn&fl[]=language&rows=20&output=json")
        else { return [] }

        let (data, _) = try await ProviderSession.shared.data(for: makeRequest(url))
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)

        return decoded.response.docs.map { doc in
            let isbns = doc.isbn?.values ?? []
            return BookSearchResult(
                title: doc.title ?? doc.identifier,
                subtitle: nil,
                authors: doc.creator?.values ?? [],
                isbn10: isbns.first { $0.count == 10 },
                isbn13: isbns.first { $0.count == 13 },
                publisher: doc.publisher?.values.first,
                publicationDate: doc.year,
                edition: nil,
                language: doc.language?.values.first,
                coverImageURL: URL(string: "https://archive.org/services/img/\(doc.identifier)"),
                provider: .internetArchive,
                providerID: doc.identifier,
                // Conservative default — confirmed only via bookDetails(providerID:).
                availability: .metadataOnly,
                fullTextAvailable: false,
                previewAvailable: true,
                searchableInside: true,
                textSource: nil,
                rightsInformation: nil
            )
        }
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        try await searchBooks(query: "isbn:\(isbn)").first
    }

    /// Fetches the item's real metadata to confirm (not assume) whether full text is legally
    /// accessible. This is the only place `.fullTextAvailable` is ever set for this provider.
    func bookDetails(providerID: String) async throws -> BookSearchResult? {
        guard let url = URL(string: "https://archive.org/metadata/\(providerID)") else { return nil }
        let (data, _) = try await ProviderSession.shared.data(for: makeRequest(url))
        let decoded = try JSONDecoder().decode(MetadataResponse.self, from: data)

        let isRestricted = decoded.metadata?.accessRestrictedItem == "true"
        let hasOCRText = decoded.files?.contains { $0.name.hasSuffix("_djvu.txt") } ?? false
        let isTextItem = decoded.metadata?.mediatype == "texts"

        let availability: ContentAvailability
        if isTextItem && !isRestricted && hasOCRText {
            availability = .fullTextAvailable
        } else if isTextItem {
            availability = .previewOnly
        } else {
            availability = .metadataOnly
        }

        guard let base = try? await searchBooks(query: providerID).first(where: { $0.providerID == providerID }) else {
            return nil
        }

        var result = base
        result.availability = availability
        result.fullTextAvailable = availability == .fullTextAvailable
        result.textSource = availability == .fullTextAvailable
            ? "https://archive.org/download/\(providerID)/\(providerID)_djvu.txt"
            : nil
        result.rightsInformation = RightsInformation(
            isPublicDomain: availability == .fullTextAvailable ? true : nil,
            license: nil,
            statement: isRestricted ? "Access-restricted on Internet Archive (lending required)" : nil
        )
        return result
    }
}
