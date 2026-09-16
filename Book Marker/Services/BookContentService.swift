import Foundation

/// Fetches book content from Open Library's Works API to power
/// the quote autocomplete dropdown. Only called for books on the Reading shelf.
final class BookContentService {
    static let shared = BookContentService()
    private init() {}

    // MARK: - In-memory cache (session-level)
    // Key: olid string, Value: array of candidate strings
    private var cache: [String: [String]] = [:]

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

    /// Returns autocomplete candidates for the given book filtered by the user's current input.
    /// Candidates are sourced from the Works API: description sentences, TOC titles, subjects.
    func suggestions(for book: Book, matching input: String) async -> [String] {
        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        guard let olid = book.olid else { return [] }

        // Use in-memory cache if available
        let candidates: [String]
        if let cached = cache[olid] {
            candidates = cached
        } else {
            candidates = await fetchCandidates(olid: olid, bookTitle: book.title, author: book.author)
            cache[olid] = candidates
        }

        let query = input.lowercased()
        return candidates.filter { $0.lowercased().contains(query) }
    }

    /// Pre-warm the cache for all books in the Reading shelf.
    func prewarm(books: [Book]) {
        for book in books {
            guard let olid = book.olid, cache[olid] == nil else { continue }
            Task {
                let result = await fetchCandidates(olid: olid, bookTitle: book.title, author: book.author)
                self.cache[olid] = result
            }
        }
    }

    // MARK: - Private

    private func fetchCandidates(olid: String, bookTitle: String, author: String) async -> [String] {
        // Build a clean work key: strip leading slash if present
        let workKey = olid.hasPrefix("/works/") ? String(olid.dropFirst(1)) : olid
        guard let url = URL(string: "https://openlibrary.org/\(workKey).json") else {
            return []
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
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
