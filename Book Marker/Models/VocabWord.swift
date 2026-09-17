import Foundation
import SwiftData

@Model
final class VocabWord {
    var id: UUID
    var word: String
    var definition: String
    /// The associated Book's local `id`, when the word was saved while reading a specific book.
    var bookID: UUID?
    var pageNumber: Int?
    var note: String?
    var dateAdded: Date
    // MARK: - Sync fields (used by SyncManager)
    var remoteID: UUID?
    var needsSync: Bool
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        word: String,
        definition: String,
        bookID: UUID? = nil,
        pageNumber: Int? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.word = word
        self.definition = definition
        self.bookID = bookID
        self.pageNumber = pageNumber
        self.note = note
        self.dateAdded = Date()
        self.remoteID = nil
        self.needsSync = true
        self.updatedAt = Date()
    }
}
