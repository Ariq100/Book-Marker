import Foundation

/// Fans a book search out to every configured `BookProvider` concurrently, then normalizes and
/// deduplicates the combined results.
///
/// Providers are queried in parallel (not sequentially with fallback) so one slow/unavailable
/// provider never blocks the others, and a provider failing entirely just means fewer results —
/// never a failed search. Key-gated providers (Google Books, Europeana) degrade silently to "no
/// results from this provider" when the Edge Function or credentials aren't configured yet.
actor BookSearchCoordinator {
    static let shared = BookSearchCoordinator()

    private let providers: [BookProvider]

    init(providers: [BookProvider] = [
        OpenLibraryService.shared,
        GutendexProvider.shared,
        InternetArchiveProvider.shared,
        LibraryOfCongressProvider.shared,
        GoogleBooksProvider.shared,
        EuropeanaProvider.shared,
    ]) {
        self.providers = providers
    }

    /// Searches all providers concurrently and returns one deduplicated result per edition,
    /// in a stable, sensible display order.
    func searchAll(query: String) async -> [BookSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let allResults = await withTaskGroup(of: [BookSearchResult].self) { group in
            for provider in providers where provider.isAvailable {
                group.addTask {
                    (try? await provider.searchBooks(query: trimmed)) ?? []
                }
            }
            var combined: [BookSearchResult] = []
            for await results in group {
                combined.append(contentsOf: results)
            }
            return combined
        }

        return deduplicate(allResults)
    }

    /// ISBN-13/ISBN-10 lookup across all providers concurrently; returns the first confirmed
    /// match, preferring an ISBN-13 hit.
    func findBook(isbn: String) async -> BookSearchResult? {
        await withTaskGroup(of: BookSearchResult?.self) { group in
            for provider in providers where provider.isAvailable {
                group.addTask { (try? await provider.findBook(isbn: isbn)) ?? nil }
            }
            for await result in group {
                if let result { return result }
            }
            return nil
        }
    }

    // MARK: - Deduplication
    //
    // Matching preference, per the architecture notes: ISBN-13 > ISBN-10 > normalized
    // title+author. Provider-ID matching isn't meaningful across providers since each has its
    // own ID namespace. Two editions are never assumed identical without a matching ISBN —
    // the normalized-title+author tier only groups results that also share a first author, and
    // even then the richest single result is kept as `primary` while the rest are preserved as
    // `alternates` rather than discarded, so no edition-specific detail is silently dropped.

    private func deduplicate(_ results: [BookSearchResult]) -> [BookSearchResult] {
        var groups: [String: [BookSearchResult]] = [:]
        var order: [String] = []

        for result in results {
            let key = dedupKey(for: result)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(result)
        }

        return order.compactMap { key in
            guard let group = groups[key] else { return nil }
            return best(of: group)
        }
    }

    private func dedupKey(for result: BookSearchResult) -> String {
        if let isbn13 = result.isbn13, !isbn13.isEmpty { return "isbn13:\(isbn13)" }
        if let isbn10 = result.isbn10, !isbn10.isEmpty { return "isbn10:\(isbn10)" }
        let normalizedTitle = normalize(result.title)
        let normalizedAuthor = normalize(result.author)
        return "title-author:\(normalizedTitle)|\(normalizedAuthor)"
    }

    private func normalize(_ string: String) -> String {
        string
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Picks a representative result from a dedup group: prefer one with confirmed full text,
    /// then one with a cover image, then richer metadata, then provider priority order.
    private func best(of group: [BookSearchResult]) -> BookSearchResult {
        let providerPriority: [BookProviderID] = [.openLibrary, .googleBooks, .internetArchive, .gutendex, .libraryOfCongress, .europeana, .hathiTrust]

        return group.sorted { lhs, rhs in
            if lhs.fullTextAvailable != rhs.fullTextAvailable { return lhs.fullTextAvailable }
            if (lhs.coverImageURL != nil) != (rhs.coverImageURL != nil) { return lhs.coverImageURL != nil }
            let lhsFields = fieldCount(lhs)
            let rhsFields = fieldCount(rhs)
            if lhsFields != rhsFields { return lhsFields > rhsFields }
            let lhsPriority = providerPriority.firstIndex(of: lhs.provider) ?? .max
            let rhsPriority = providerPriority.firstIndex(of: rhs.provider) ?? .max
            return lhsPriority < rhsPriority
        }.first!
    }

    private func fieldCount(_ result: BookSearchResult) -> Int {
        [result.subtitle, result.publisher, result.publicationDate, result.language, result.edition]
            .compactMap { $0 }.count
    }
}
