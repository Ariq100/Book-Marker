import Foundation

/// HathiTrust (https://www.hathitrust.org/) Bibliographic API
/// (https://www.hathitrust.org/member-libraries/resources-for-librarians/data-resources/bibliographic-api/)
///
/// Verified against current documentation: the Bibliographic API is free, keyless, and intended
/// for looking up a small number of items at a time by identifier (ISBN/OCLC/LCCN/htid) — it is
/// metadata + rights status only, never full text. HathiTrust's actual full-text/page-image
/// access (the Data API) requires institutional affiliation and signed agreements, which is out
/// of scope for a consumer app, so `fullText` is intentionally left unimplemented here — do not
/// wire this up without a real institutional agreement in place.
final class HathiTrustProvider: BookProvider {
    static let shared = HathiTrustProvider()
    private init() {}

    let id: BookProviderID = .hathiTrust

    func searchBooks(query: String) async throws -> [BookSearchResult] {
        // The Bibliographic API is identifier-based (ISBN/OCLC/LCCN/htid), not a free-text
        // search endpoint, so general keyword search isn't supported here.
        []
    }

    func findBook(isbn: String) async throws -> BookSearchResult? {
        let cleaned = isbn.filter { $0.isNumber || $0 == "X" || $0 == "x" }
        guard !cleaned.isEmpty,
              let url = URL(string: "https://catalog.hathitrust.org/api/volumes/brief/json/isbn:\(cleaned)")
        else { return nil }

        let (data, _) = try await ProviderSession.shared.data(from: url)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = json["records"] as? [String: Any],
              let firstRecord = records.values.first as? [String: Any],
              let titles = firstRecord["titles"] as? [String], let title = titles.first
        else { return nil }

        let publishDates = firstRecord["publishDates"] as? [String]
        let isbn13 = cleaned.count == 13 ? cleaned : nil
        let isbn10 = cleaned.count == 10 ? cleaned : nil

        // `items` carries per-volume rights; if ANY listed item is openly accessible
        // ("pd" / "world" access) we surface that, but we still never fetch page text —
        // only the Data API (institutional-only) can do that legally.
        let items = json["items"] as? [[String: Any]] ?? []
        let hasOpenAccessItem = items.contains { ($0["usRightsString"] as? String)?.lowercased().contains("full text") == true }

        return BookSearchResult(
            title: title,
            subtitle: nil,
            authors: [],
            isbn10: isbn10,
            isbn13: isbn13,
            publisher: nil,
            publicationDate: publishDates?.first,
            edition: nil,
            language: nil,
            coverImageURL: nil,
            provider: .hathiTrust,
            providerID: "isbn:\(cleaned)",
            availability: .metadataOnly,
            fullTextAvailable: false,
            previewAvailable: hasOpenAccessItem,
            searchableInside: false,
            textSource: nil,
            rightsInformation: RightsInformation(
                isPublicDomain: nil,
                license: nil,
                statement: "Full text requires HathiTrust institutional access (Data API), not implemented in this app."
            )
        )
    }
}
