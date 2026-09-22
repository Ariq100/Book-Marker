import Foundation
import SwiftData

@Model
final class Quote {
    var id: UUID
    var text: String
    var bookTitle: String
    /// The associated Book's local `id`, when the quote was saved from a book already in the
    /// library. `bookTitle` is kept as a plain string too since a quote can outlive/outlast a
    /// book being removed, and to preserve existing data saved before this field existed.
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
        text: String,
        bookTitle: String,
        bookID: UUID? = nil,
        pageNumber: Int? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.text = text
        self.bookTitle = bookTitle
        self.bookID = bookID
        self.pageNumber = pageNumber
        self.note = note
        self.dateAdded = Date()
        self.remoteID = nil
        self.needsSync = true
        self.updatedAt = Date()
    }

    /// Call after editing any synced field so SyncManager pushes the change and last-write-wins
    /// resolution sees this edit as the newest version.
    func markDirty() {
        needsSync = true
        updatedAt = Date()
    }
}
