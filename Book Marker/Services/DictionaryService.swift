import Foundation

struct DictionaryResult {
    let word: String
    let partOfSpeech: String
    let definition: String
}

final class DictionaryService {
    static let shared = DictionaryService()
    private init() {}

    // MARK: - Errors

    enum DictionaryError: LocalizedError {
        case wordNotFound
        case noDefinitionFound

        var errorDescription: String? {
            switch self {
            case .wordNotFound:      return "Word not found in dictionary."
            case .noDefinitionFound: return "No definition found for this word."
            }
        }
    }

    // MARK: - Private decodable types

    private struct APIResponse: Decodable {
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

    // MARK: - Public API

    func fetchDefinition(for word: String) async throws -> DictionaryResult {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw DictionaryError.wordNotFound }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://api.dictionaryapi.dev/api/v2/entries/en/\(encoded)")
        else { throw DictionaryError.wordNotFound }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DictionaryError.wordNotFound
        }

        let results = try JSONDecoder().decode([APIResponse].self, from: data)

        guard let first = results.first,
              let meaning = first.meanings.first,
              let def = meaning.definitions.first
        else { throw DictionaryError.noDefinitionFound }

        return DictionaryResult(
            word: first.word,
            partOfSpeech: meaning.partOfSpeech,
            definition: def.definition
        )
    }
}
