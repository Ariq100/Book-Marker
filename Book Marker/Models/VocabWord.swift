import Foundation
import SwiftData

@Model
final class VocabWord {
    var id: UUID
    var word: String
    var definition: String
    var dateAdded: Date

    init(id: UUID = UUID(), word: String, definition: String) {
        self.id = id
        self.word = word
        self.definition = definition
        self.dateAdded = Date()
    }
}
