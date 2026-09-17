import Foundation

/// Every book metadata/text source the app knows how to query.
/// Adding a new provider means adding a case here and a conforming `BookProvider`.
enum BookProviderID: String, Codable, CaseIterable, Hashable {
    case openLibrary
    case googleBooks
    case internetArchive
    case gutendex
    case libraryOfCongress
    case europeana
    case hathiTrust

    var displayName: String {
        switch self {
        case .openLibrary:       return "Open Library"
        case .googleBooks:       return "Google Books"
        case .internetArchive:   return "Internet Archive"
        case .gutendex:          return "Project Gutenberg"
        case .libraryOfCongress: return "Library of Congress"
        case .europeana:         return "Europeana"
        case .hathiTrust:        return "HathiTrust"
        }
    }
}

/// What level of text access is actually available for a book from a given source.
///
/// IMPORTANT: never infer `.fullTextAvailable` just because a provider returned metadata.
/// Only set it when the source's own rights/access data confirms the text is legally
/// readable (e.g. a public-domain Internet Archive/Gutenberg item). Everything else should
/// default to `.metadataOnly` or `.previewOnly`. See section 20 of the architecture notes
/// in BOOK_API_PROVIDERS.md — this app never downloads full text it doesn't have the right to.
enum ContentAvailability: String, Codable, Hashable {
    /// Legally, freely accessible full text (public domain, open-access OCR, etc.)
    case fullTextAvailable
    /// Snippet/preview only (e.g. Google Books preview, limited Search Inside snippet)
    case previewOnly
    /// Title/author/cover/identifiers only — no readable text through this provider
    case metadataOnly
    /// The user typed or pasted the text themselves
    case userProvidedText
    /// Captured via on-device OCR of the user's own physical copy (Vision framework)
    case ocrCaptured
    /// Nothing usable was found
    case unavailable
}

struct RightsInformation: Codable, Hashable {
    var isPublicDomain: Bool?
    var license: String?
    var statement: String?
}

/// A provider-agnostic search result. Every `BookProvider` normalizes its raw API response into
/// this shape so the rest of the app (search UI, dedup, "add to library") never needs to know
/// which upstream API a result came from.
///
/// Edition matters: two editions of the same work can have different page numbers and text
/// layout, so results are never silently merged across editions — only exact ISBN/provider-ID
/// matches are deduplicated (see `BookSearchCoordinator`).
struct BookSearchResult: Identifiable, Hashable {
    var title: String
    var subtitle: String?
    var authors: [String]
    var isbn10: String?
    var isbn13: String?
    var publisher: String?
    /// Kept as the provider's raw string — publication date formats vary too much
    /// across sources (year-only, full date, "c1920", etc.) to normalize safely.
    var publicationDate: String?
    var edition: String?
    var language: String?
    var coverImageURL: URL?
    var provider: BookProviderID
    /// Provider-specific identifier (Open Library work key, Gutendex id, Internet Archive
    /// identifier, Google Books volume id, HathiTrust htid, Europeana record id, ...).
    var providerID: String
    var availability: ContentAvailability
    var fullTextAvailable: Bool
    var previewAvailable: Bool
    /// Whether this provider's "search inside" capability can be used for this specific item.
    var searchableInside: Bool
    /// Where full/preview text can actually be fetched from, if anywhere (a URL or provider note).
    var textSource: String?
    var rightsInformation: RightsInformation?

    var id: String { "\(provider.rawValue):\(providerID)" }

    // MARK: - Convenience

    var author: String { authors.first ?? "Unknown Author" }

    var firstPublishYear: Int? {
        guard let publicationDate else { return nil }
        return Int(publicationDate.prefix(4))
    }

    /// Non-nil only for Open Library results, where the rest of the app already
    /// treats the work key as the canonical per-book identifier (`Book.olid`).
    var olid: String? { provider == .openLibrary ? providerID : nil }
}

/// The result of matching/deduplicating results from multiple providers for the same edition.
struct DedupedBookResult {
    /// The result chosen to represent this group (prefers the provider with the richest metadata).
    var primary: BookSearchResult
    /// Other providers that also returned a match for the same edition, most useful when the
    /// primary provider's availability is `.metadataOnly` and another provider has full text.
    var alternates: [BookSearchResult]
}
