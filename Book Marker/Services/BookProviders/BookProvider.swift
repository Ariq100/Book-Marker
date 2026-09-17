import Foundation

/// A single book metadata/text source (Open Library, Google Books, Internet Archive, ...).
///
/// Every provider is independently replaceable: the app must keep working if any one provider
/// is slow, down, or removed. Concrete providers only implement the capabilities they actually
/// support — the protocol extension below supplies safe "unsupported" defaults for the rest,
/// so e.g. a metadata-only provider doesn't need to implement `searchInsideBook`.
protocol BookProvider: Sendable {
    var id: BookProviderID { get }

    /// Whether this provider is currently usable (e.g. false for a provider that needs a
    /// secret which hasn't been configured yet, or one that's documented as unimplemented).
    var isAvailable: Bool { get }

    /// Free-text search (title, author, or keyword).
    func searchBooks(query: String) async throws -> [BookSearchResult]

    /// Direct ISBN-10/ISBN-13 lookup. Returns nil if not found.
    func findBook(isbn: String) async throws -> BookSearchResult?

    /// Fetch full details for a result previously returned by this same provider.
    func bookDetails(providerID: String) async throws -> BookSearchResult?

    /// Full-text-in-book search ("search inside"), where the provider supports it.
    /// Returns matching snippets/sentences. Empty array if unsupported or nothing found.
    func searchInsideBook(providerID: String, query: String) async throws -> [String]

    /// Returns the legally-available full text for a book, only when `availability`
    /// for that item is `.fullTextAvailable`. Returns nil otherwise — never attempts to
    /// work around access restrictions.
    func fullText(providerID: String) async throws -> String?
}

// MARK: - Default "unsupported" implementations for optional capabilities

extension BookProvider {
    var isAvailable: Bool { true }

    func bookDetails(providerID: String) async throws -> BookSearchResult? { nil }

    func searchInsideBook(providerID: String, query: String) async throws -> [String] { [] }

    func fullText(providerID: String) async throws -> String? { nil }
}

/// Thrown by providers to distinguish "this provider has nothing to say" from a real network
/// failure, so the coordinator can decide whether to surface an error or just skip silently.
enum BookProviderError: Error {
    case notConfigured(BookProviderID)
    case invalidQuery
    case requestFailed(underlying: Error)
    case decodingFailed(underlying: Error)
}
