import Foundation
import SwiftData

enum Shelf: String, Codable, CaseIterable {
    case reading = "Reading"
    case bucketList = "Bucket List"
    case done = "Done"

    var systemImage: String {
        switch self {
        case .reading:    return "book.fill"
        case .bucketList: return "list.star"
        case .done:       return "checkmark.seal.fill"
        }
    }
}

@Model
final class Book {
    var id: UUID
    var title: String
    var author: String
    var coverID: Int?
    /// Open Library Work ID, e.g. "/works/OL12345W" — used to fetch quote suggestions
    var olid: String?
    var shelf: Shelf
    var dateAdded: Date
    /// Locally cached cover image data — avoids repeated network fetches
    var coverImageData: Data?
    // MARK: - Sync fields (used by SyncManager)
    /// The UUID of the corresponding row in Supabase. nil means never synced.
    var remoteID: UUID?
    /// True when local changes have not yet been pushed to Supabase.
    var needsSync: Bool
    /// Last time this record was modified locally; used for last-write-wins conflict resolution.
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        coverID: Int? = nil,
        olid: String? = nil,
        shelf: Shelf = .bucketList
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverID = coverID
        self.olid = olid
        self.shelf = shelf
        self.dateAdded = Date()
        self.coverImageData = nil
        self.remoteID = nil
        self.needsSync = true
        self.updatedAt = Date()
    }
}
