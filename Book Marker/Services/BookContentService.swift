import Foundation

/// Fetches book content from Open Library's Works API to power
/// the quote autocomplete dropdown. Only called for books on the Reading shelf.
///
/// AN ACTOR, NOT A CLASS: `prewarm(books:)` fans out one detached task per book, and every one
/// of them writes `cache`. As a plain `final class` that was an unsynchronized read-modify-write
/// from several tasks at once — a genuine data race, and the source of the concurrency
/// complaints in the console. Actor isolation serializes all cache access.
actor BookContentService {
    static let shared = BookContentService()
    private init() {}

    // MARK: - In-memory cache (session-level)
    // Key: Open Library work key, Value: array of candidate strings
    private var cache: [String: [String]] = [:]

    /// Maps "title\u{1}author" -> resolved Open Library work key (or nil when Open Library has
    /// nothing). Cached separately so a book with no `olid` costs at most one resolution lookup
    /// per session, including when the answer is "no match".
    private var resolvedWorkKeys: [String: String?] = [:]

    // MARK: - Decodable types for Works API

    private struct WorkDetail: Decodable {
        let title: String?
        let description: WorkDescription?
        let subjects: [String]?
        let table_of_contents: [TOCEntry]?
        let excerpts: [Excerpt]?

        struct TOCEntry: Decodable {
            let title: String?
            let label: String?
        }

        struct Excerpt: Decodable {
            let excerpt: String?
        }
    }

    private enum WorkDescription: Decodable {
        case string(String)
        case typed(String)

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let str = try? container.decode(String.self) {
                self = .string(str)
                return
            }
            struct TypedValue: Decodable { let value: String }
            if let typed = try? container.decode(TypedValue.self) {
                self = .typed(typed.value)
                return
            }
            self = .string("")
        }

        var text: String {
            switch self {
            case .string(let s): return s
            case .typed(let s): return s
            }
        }
    }

    // MARK: - Public API

    /// The plain-value snapshot of a `Book` that this service works with.
    ///
    /// `Book` is a SwiftData `@Model`, which is neither `Sendable` nor safe to touch off the
    /// context that owns it. Passing one into an actor is what produced the "non-Sendable type
    /// crossing actor boundary" errors; callers now snapshot on the main actor and hand over
    /// immutable strings instead.
    struct BookRef: Sendable, Hashable {
        let olid: String?
        let title: String
        let author: String

        @MainActor
        init(_ book: Book) {
            self.olid = book.olid
            self.title = book.title
            self.author = book.author
        }
    }

    /// Returns autocomplete candidates for the given book filtered by the user's current input.
    /// Candidates are sourced from the Works API: description sentences, TOC titles, subjects.
    func suggestions(for book: BookRef, matching input: String) async -> [String] {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard let workKey = await workKey(for: book) else { return [] }

        // Use in-memory cache if available
        let candidates: [String]
        if let cached = cache[workKey] {
            candidates = cached
        } else {
            candidates = await fetchCandidates(olid: workKey, bookTitle: book.title, author: book.author)
            cache[workKey] = candidates
        }

        let query = input.lowercased()
        return candidates.filter { $0.lowercased().contains(query) }
    }

    /// Pre-warm the cache for all books in the Reading shelf.
    func prewarm(books: [BookRef]) async {
        await withTaskGroup(of: Void.self) { group in
            for book in books {
                group.addTask { _ = await self.suggestionsSource(for: book) }
            }
        }
    }

    /// Resolves and caches a book's candidate list without filtering — the prewarm path.
    private func suggestionsSource(for book: BookRef) async {
        guard let workKey = await workKey(for: book), cache[workKey] == nil else { return }
        cache[workKey] = await fetchCandidates(olid: workKey, bookTitle: book.title, author: book.author)
    }

    // MARK: - Work-key resolution

    /// `Book.olid` is only ever populated for books added from Open Library — `BookSearchResult`
    /// defines it as `provider == .openLibrary ? providerID : nil`. Because the coordinator
    /// dedupes across providers and keeps whichever result is richest, a book the user added is
    /// just as likely to have come from Google Books or Gutendex, leaving `olid` nil and the
    /// suggestion dropdown permanently empty. When that happens, look the work up in Open
    /// Library by title and author so suggestions work regardless of which provider the book
    /// was originally added from.
    private func workKey(for book: BookRef) async -> String? {
        if let olid = book.olid, !olid.isEmpty { return olid }

        let cacheKey = "\(book.title)\u{1}\(book.author)"
        if let cached = resolvedWorkKeys[cacheKey] { return cached }

        let resolved = await lookUpWorkKey(title: book.title, author: book.author)
        resolvedWorkKeys[cacheKey] = resolved
        return resolved
    }

    private struct WorkSearchResponse: Decodable {
        struct Doc: Decodable { let key: String? }
        let docs: [Doc]
    }

    private func lookUpWorkKey(title: String, author: String) async -> String? {
        var components = URLComponents(string: "https://openlibrary.org/search.json")
        components?.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "author", value: author),
            URLQueryItem(name: "limit", value: "1"),
            URLQueryItem(name: "fields", value: "key"),
        ]
        guard let url = components?.url,
              let (data, _) = try? await ProviderSession.shared.data(from: url),
              let decoded = try? JSONDecoder().decode(WorkSearchResponse.self, from: data)
        else { return nil }

        // Keys come back as "/works/OL123W"; fetchCandidates strips the leading slash itself.
        return decoded.docs.first?.key
    }

    // MARK: - Private

    private func fetchCandidates(olid: String, bookTitle: String, author: String) async -> [String] {
        // Build a clean work key: strip leading slash if present
        let workKey = olid.hasPrefix("/works/") ? String(olid.dropFirst(1)) : olid
        guard let url = URL(string: "https://openlibrary.org/\(workKey).json") else {
            return []
        }

        guard let (data, _) = try? await ProviderSession.shared.data(from: url),
              let detail = try? JSONDecoder().decode(WorkDetail.self, from: data) else {
            return []
        }

        var candidates: [String] = []

        // 1. Description — split into sentences
        if let desc = detail.description?.text, !desc.isEmpty {
            let sentences = splitIntoSentences(desc)
            candidates.append(contentsOf: sentences)
        }

        // 2. Table of contents titles
        if let toc = detail.table_of_contents {
            for entry in toc {
                if let t = entry.title, !t.isEmpty { candidates.append(t) }
                if let l = entry.label, !l.isEmpty { candidates.append(l) }
            }
        }

        // 3. Subjects (good for thematic quotes)
        if let subjects = detail.subjects {
            candidates.append(contentsOf: subjects.filter { $0.count > 8 })
        }

        // 4. Excerpts (when available)
        if let excerpts = detail.excerpts {
            for excerpt in excerpts {
                if let e = excerpt.excerpt, !e.isEmpty {
                    candidates.append(contentsOf: splitIntoSentences(e))
                }
            }
        }

        // Deduplicate and filter out very short entries
        let seen = NSMutableOrderedSet()
        for c in candidates where c.count >= 12 {
            seen.add(c.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return seen.array as? [String] ?? []
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            if let s = sub?.trimmingCharacters(in: .whitespacesAndNewlines), s.count >= 12 {
                sentences.append(s)
            }
        }
        return sentences
    }
}
