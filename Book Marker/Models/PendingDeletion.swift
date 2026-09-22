import Foundation
import SwiftData

/// A tombstone for a record deleted locally after it had already been synced to Supabase.
///
/// Deleting the SwiftData object removes every trace of its `remoteID`, so without this record
/// SyncManager would have no way to know the remote row should go too — and the next sync down
/// would simply bring the "deleted" book, quote or word back.
@Model
final class PendingDeletion {
    /// Supabase table name: "books", "quotes" or "vocab_words".
    var table: String
    var remoteID: UUID
    var dateDeleted: Date

    init(table: String, remoteID: UUID) {
        self.table = table
        self.remoteID = remoteID
        self.dateDeleted = Date()
    }
}

extension ModelContext {
    /// Deletes a synced model locally and queues the matching Supabase row for deletion.
    func deleteSynced(_ book: Book) {
        if let remoteID = book.remoteID { insert(PendingDeletion(table: "books", remoteID: remoteID)) }
        delete(book)
    }

    func deleteSynced(_ quote: Quote) {
        if let remoteID = quote.remoteID { insert(PendingDeletion(table: "quotes", remoteID: remoteID)) }
        delete(quote)
    }

    func deleteSynced(_ word: VocabWord) {
        if let remoteID = word.remoteID { insert(PendingDeletion(table: "vocab_words", remoteID: remoteID)) }
        delete(word)
    }
}
