import Foundation
import SwiftData

@Model
final class Quote {
    var id: UUID
    var text: String
    var bookTitle: String
    var dateAdded: Date
    // MARK: - Sync fields (used by SyncManager)
    var remoteID: UUID?
    var needsSync: Bool
    var updatedAt: Date

    init(id: UUID = UUID(), text: String, bookTitle: String) {
        self.id = id
        self.text = text
        self.bookTitle = bookTitle
        self.dateAdded = Date()
        self.remoteID = nil
        self.needsSync = true
        self.updatedAt = Date()
    }
}
