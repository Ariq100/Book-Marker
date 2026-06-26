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
    var shelf: Shelf
    var dateAdded: Date

    init(
        id: UUID = UUID(),
        title: String,
        author: String,
        coverID: Int? = nil,
        shelf: Shelf = .bucketList
    ) {
        self.id = id
        self.title = title
        self.author = author
        self.coverID = coverID
        self.shelf = shelf
        self.dateAdded = Date()
    }
}
