import Foundation

struct DictionaryResult {
    let word: String
    let partOfSpeech: String
    let definition: String
}

/// Looks up English definitions, trying several free dictionary APIs in order.
///
/// WHY THERE ARE THREE SOURCES: the primary API (dictionaryapi.dev) is a free, volunteer-run
/// service that periodically stops responding entirely — requests hang until they time out
/// rather than failing fast. When that happened the Add Word screen showed a spinner and then
/// nothing. Each source is now tried in turn with a short timeout, and the first one that
/// returns a usable definition wins:
///
///   1. Free Dictionary API — https://dictionaryapi.dev
///   2. Wiktionary REST API — https://en.wiktionary.org/api/rest_v1/
///   3. Datamuse             — https://www.datamuse.com/api/ (definitions from WordNet/Wiktionary)
///
/// None of them require an API key.
final class DictionaryService {
    static let shared = DictionaryService()
    private init() {}

    // MARK: - Errors

    enum DictionaryError: LocalizedError {
        case wordNotFound
        case noDefinitionFound
        case serviceUnavailable

        var errorDescription: String? {
            switch self {
            case .wordNotFound:       return "Word not found in dictionary."
            case .noDefinitionFound:  return "No definition found for this word."
            case .serviceUnavailable: return "Couldn't reach the dictionary. Check your connection or type your own definition."
            }
        }
    }

    // MARK: - Networking

    /// Short timeouts so a hung source falls through to the next one quickly instead of
    /// holding the lookup open for `URLSession.shared`'s 60-second default.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 8
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = [
            // Wikimedia asks API clients to identify themselves.
            "User-Agent": "BookMarker/1.0 (iOS; vocabulary lookup)",
            "Accept": "application/json",
        ]
        return URLSession(configuration: config)
    }()

    private typealias Source = (name: String, lookup: (String) async throws -> DictionaryResult)

    private var sources: [Source] {
        [
            ("Free Dictionary API", fetchFromFreeDictionary),
            ("Wiktionary", fetchFromWiktionary),
            ("Datamuse", fetchFromDatamuse),
        ]
    }

    // MARK: - Public API

    func fetchDefinition(for word: String) async throws -> DictionaryResult {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DictionaryError.wordNotFound }

        var sawNotFound = false

        for source in sources {
            try Task.checkCancellation()
            do {
                return try await source.lookup(trimmed)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch DictionaryError.wordNotFound, DictionaryError.noDefinitionFound {
                sawNotFound = true
                #if DEBUG
                print("[DictionaryService] \(source.name): no definition for \"\(trimmed)\"")
                #endif
            } catch {
                #if DEBUG
                print("[DictionaryService] \(source.name) failed: \(error)")
                #endif
            }
        }

        // If at least one source answered and simply didn't know the word, say so; otherwise
        // every source failed to respond, which is a connectivity problem, not a bad word.
        throw sawNotFound ? DictionaryError.wordNotFound : DictionaryError.serviceUnavailable
    }

    // MARK: - Shared helpers

    private func get(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        switch http.statusCode {
        case 200:      return data
        case 404:      throw DictionaryError.wordNotFound
        default:       throw URLError(.badServerResponse)
        }
    }

    private func encodedPathComponent(_ word: String) throws -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        guard let encoded = word.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw DictionaryError.wordNotFound
        }
        return encoded
    }

    // MARK: - Source 1: Free Dictionary API

    private struct FreeDictionaryEntry: Decodable {
        let word: String
        let meanings: [Meaning]

        struct Meaning: Decodable {
            let partOfSpeech: String
            let definitions: [Definition]

            struct Definition: Decodable {
                let definition: String
            }
        }
    }

    private func fetchFromFreeDictionary(_ word: String) async throws -> DictionaryResult {
        let path = try encodedPathComponent(word.lowercased())
        guard let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(path)") else {
            throw DictionaryError.wordNotFound
        }

        let data = try await get(url)
        let entries = try JSONDecoder().decode([FreeDictionaryEntry].self, from: data)

        guard let entry = entries.first,
              let meaning = entry.meanings.first(where: { !$0.definitions.isEmpty }),
              let def = meaning.definitions.first
        else { throw DictionaryError.noDefinitionFound }

        return DictionaryResult(word: entry.word, partOfSpeech: meaning.partOfSpeech, definition: def.definition)
    }

    // MARK: - Source 2: Wiktionary

    private struct WiktionaryEntry: Decodable {
        let partOfSpeech: String
        let definitions: [Definition]

        struct Definition: Decodable {
            let definition: String
        }
    }

    private func fetchFromWiktionary(_ word: String) async throws -> DictionaryResult {
        // Wiktionary page titles are case-sensitive; vocabulary words live on lowercase pages.
        let lower = word.lowercased()
        let path = try encodedPathComponent(lower)
        guard let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(path)") else {
            throw DictionaryError.wordNotFound
        }

        let data = try await get(url)
        let byLanguage = try JSONDecoder().decode([String: [WiktionaryEntry]].self, from: data)

        // Skip non-lexical sections such as "Symbol" (e.g. ISO language codes).
        let skipped: Set<String> = ["symbol", "letter", "abbreviation", "initialism"]
        for entry in byLanguage["en"] ?? [] where !skipped.contains(entry.partOfSpeech.lowercased()) {
            for def in entry.definitions {
                let text = Self.plainText(fromWiktionaryHTML: def.definition)
                if !text.isEmpty {
                    return DictionaryResult(word: lower, partOfSpeech: entry.partOfSpeech.lowercased(), definition: text)
                }
            }
        }
        throw DictionaryError.noDefinitionFound
    }

    /// Wiktionary definitions are HTML fragments that may also contain nested sub-sense
    /// lists. Keep only the top-level sense, strip tags, and decode common entities.
    private static func plainText(fromWiktionaryHTML html: String) -> String {
        var text = html
        if let nested = text.range(of: "<ol") { text = String(text[..<nested.lowerBound]) }
        if let newline = text.firstIndex(of: "\n") { text = String(text[..<newline]) }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&nbsp;": " "]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Source 3: Datamuse

    private struct DatamuseWord: Decodable {
        let word: String
        let defs: [String]?
    }

    private func fetchFromDatamuse(_ word: String) async throws -> DictionaryResult {
        let lower = word.lowercased()
        var components = URLComponents(string: "https://api.datamuse.com/words")
        components?.queryItems = [
            URLQueryItem(name: "sp", value: lower),
            URLQueryItem(name: "md", value: "d"),
            URLQueryItem(name: "max", value: "1"),
        ]
        guard let url = components?.url else { throw DictionaryError.wordNotFound }

        let data = try await get(url)
        let results = try JSONDecoder().decode([DatamuseWord].self, from: data)

        // `sp` is a spelling match, so make sure it's actually the word we asked for.
        guard let match = results.first, match.word.lowercased() == lower else {
            throw DictionaryError.wordNotFound
        }
        // Each def is formatted as "<pos>\t<definition>", e.g. "adj\tLasting a short time."
        guard let raw = match.defs?.first else { throw DictionaryError.noDefinitionFound }

        let parts = raw.split(separator: "\t", maxSplits: 1).map(String.init)
        let definition = (parts.last ?? raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !definition.isEmpty else { throw DictionaryError.noDefinitionFound }

        let posNames = ["n": "noun", "v": "verb", "adj": "adjective", "adv": "adverb"]
        let pos = parts.count == 2 ? (posNames[parts[0]] ?? "") : ""

        return DictionaryResult(word: match.word, partOfSpeech: pos, definition: definition)
    }
}
