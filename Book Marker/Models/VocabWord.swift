import Foundation
import SwiftData

@Model
final class VocabWord {
    var id: UUID
    var word: String
    var definition: String
    var dateAdded: Date
    // MARK: - Sync fields (used by SyncManager)
    var remoteID: UUID?
    var needsSync: Bool
    var updatedAt: Date

    init(id: UUID = UUID(), word: String, definition: String) {
        self.id = id
        self.word = word
        self.definition = definition
        self.dateAdded = Date()
        self.remoteID = nil
        self.needsSync = true
        self.updatedAt = Date()
    }
}
