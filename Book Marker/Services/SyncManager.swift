//
//  SyncManager.swift
//  Book Marker
//
//  TASK 6

// WHY AN ACTOR:
// SyncManager is declared as a Swift `actor` rather than a `class` to serialize all access to its
// internal state and prevent data races. Without an actor, concurrent calls to `syncUp` and
// `syncDown` (e.g. triggered simultaneously on app foreground and a background refresh) could
// interleave, corrupting the list of records being processed or issuing duplicate upserts.
// The actor's serial executor guarantees that only one sync operation runs at a time without
// needing manual locks or DispatchQueues.

// REQUIRED MODEL CHANGES — add these two properties to each of Book, Quote, and VocabWord in
// their respective model files. SwiftData will handle the migration automatically in DEBUG builds.
// For production releases, create a proper migration plan.
//
// In Book.swift, Quote.swift, and VocabWord.swift — add inside the class body:
//   var remoteID: UUID?          // nil = record has never been synced to Supabase
//   var needsSync: Bool = true   // true = local changes not yet pushed to Supabase
//   var updatedAt: Date = Date() // used for last-write-wins conflict resolution
//
// Also update each model's init() to set: needsSync = true, remoteID = nil, updatedAt = Date()

// REQUIRED SUPABASE RLS POLICIES — run the following SQL in your Supabase SQL Editor for each table.
// Replace `books`, `quotes`, and `vocab_words` accordingly.
//
// -- Enable RLS (if not already enabled)
// ALTER TABLE books ENABLE ROW LEVEL SECURITY;
//
// -- SELECT: users can only read their own rows
// CREATE POLICY "Users can select own books"
//   ON books FOR SELECT
//   USING (auth.uid() = user_id);
//
// -- INSERT: users can only insert rows for themselves
// CREATE POLICY "Users can insert own books"
//   ON books FOR INSERT
//   WITH CHECK (auth.uid() = user_id);
//
// -- UPDATE: users can only update their own rows
// CREATE POLICY "Users can update own books"
//   ON books FOR UPDATE
//   USING (auth.uid() = user_id)
//   WITH CHECK (auth.uid() = user_id);
//
// -- DELETE: users can only delete their own rows
// CREATE POLICY "Users can delete own books"
//   ON books FOR DELETE
//   USING (auth.uid() = user_id);
//
// Repeat the above for `quotes` and `vocab_words` tables, adjusting the policy names accordingly.

// CONFLICT RESOLUTION — DELIBERATE SIMPLIFICATION:
// This implementation uses a last-write-wins strategy: when a remote row has a newer `updated_at`
// timestamp than the local record, the remote version wins and overwrites local data. This is simple
// and sufficient for a single-user, multi-device scenario, but has known limitations:
// - Simultaneous edits on two offline devices will silently discard one edit when both come back online.
// - It does not handle partial field conflicts (e.g. only the title changed on one device, only the
//   shelf changed on another).
// Real conflict resolution (e.g. CRDTs, operational transforms, or user-facing merge UI) is
// explicitly out of scope for this implementation.

import Foundation
import SwiftData
import Network
import Supabase

// MARK: - Remote row DTOs (Decodable / Encodable)

/// Maps to the `books` table in Supabase.
/// Column names use snake_case to match Postgres conventions.
struct RemoteBook: Codable {
    var id: UUID               // remoteID
    var userId: UUID
    var localId: UUID          // the SwiftData model's local `id`
    var title: String
    var author: String
    var coverId: Int?
    var olid: String?
    var shelf: String          // Shelf.rawValue
    var dateAdded: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId      = "user_id"
        case localId     = "local_id"
        case title
        case author
        case coverId     = "cover_id"
        case olid
        case shelf
        case dateAdded   = "date_added"
        case updatedAt   = "updated_at"
    }
}

/// Maps to the `quotes` table in Supabase.
struct RemoteQuote: Codable {
    var id: UUID
    var userId: UUID
    var localId: UUID
    var text: String
    var bookTitle: String
    var dateAdded: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case localId   = "local_id"
        case text
        case bookTitle = "book_title"
        case dateAdded = "date_added"
        case updatedAt = "updated_at"
    }
}

/// Maps to the `vocab_words` table in Supabase.
struct RemoteVocabWord: Codable {
    var id: UUID
    var userId: UUID
    var localId: UUID
    var word: String
    var definition: String
    var dateAdded: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case localId   = "local_id"
        case word
        case definition
        case dateAdded = "date_added"
        case updatedAt = "updated_at"
    }
}

// MARK: - SyncManager

actor SyncManager {
    static let shared = SyncManager()

    // NWPathMonitor is used to check network reachability before any sync attempt.
    // This prevents URLSession errors from bubbling up as user-facing crashes when offline.
    private let monitor = NWPathMonitor()
    private var currentPath: NWPath?
    private nonisolated(unsafe) var monitorTask: Task<Void, Never>?

    private var isConnected: Bool {
        currentPath?.status == .satisfied
    }

    private init() {
        let queue = DispatchQueue(label: "com.bookmarker.SyncManager.NWPathMonitor")
        monitor.start(queue: queue)
        // Capture monitor directly so we don't need to access self in a nonisolated context.
        let monitor = self.monitor
        monitorTask = Task.detached(priority: .background) { [weak self] in
            for await path in monitor.paths {
                await self?.updatePath(path)
            }
        }
    }

    deinit {
        monitor.cancel()
        monitorTask?.cancel()
    }

    private func updatePath(_ path: NWPath) {
        currentPath = path
    }

    // MARK: - Sync Up

    /// Pushes all local records where `needsSync == true` to Supabase using upsert semantics.
    /// Records with a nil `remoteID` are treated as new inserts; existing remoteIDs trigger updates.
    ///
    /// - Parameter modelContext: The SwiftData `ModelContext` from which to fetch local records.
    /// - Note: This method is a no-op if there is no active internet connection.
    func syncUp(modelContext: ModelContext) async throws {
        guard isConnected else {
            // No network — skip silently. Retry will happen on next foreground event.
            return
        }

        guard let currentUser = AuthManager.shared.currentUser else { return }
        let userId = currentUser.id
        let client = AuthManager.shared.client

        // --- Books ---
        let booksDescriptor = FetchDescriptor<Book>(
            predicate: #Predicate { $0.needsSync == true }
        )
        let dirtyBooks = (try? modelContext.fetch(booksDescriptor)) ?? []

        if !dirtyBooks.isEmpty {
            let remoteBooks: [RemoteBook] = dirtyBooks.map { book in
                let remoteID = book.remoteID ?? UUID()
                // Assign a remoteID if this is a first-time sync for this record.
                // (The caller must save the context after syncUp returns so this persists.)
                book.remoteID = remoteID
                return RemoteBook(
                    id: remoteID,
                    userId: userId,
                    localId: book.id,
                    title: book.title,
                    author: book.author,
                    coverId: book.coverID,
                    olid: book.olid,
                    shelf: book.shelf.rawValue,
                    dateAdded: book.dateAdded,
                    updatedAt: book.updatedAt
                )
            }
            try await client
                .from("books")
                .upsert(remoteBooks, onConflict: "id")
                .execute()

            dirtyBooks.forEach { $0.needsSync = false }
        }

        // --- Quotes ---
        let quotesDescriptor = FetchDescriptor<Quote>(
            predicate: #Predicate { $0.needsSync == true }
        )
        let dirtyQuotes = (try? modelContext.fetch(quotesDescriptor)) ?? []

        if !dirtyQuotes.isEmpty {
            let remoteQuotes: [RemoteQuote] = dirtyQuotes.map { quote in
                let remoteID = quote.remoteID ?? UUID()
                quote.remoteID = remoteID
                return RemoteQuote(
                    id: remoteID,
                    userId: userId,
                    localId: quote.id,
                    text: quote.text,
                    bookTitle: quote.bookTitle,
                    dateAdded: quote.dateAdded,
                    updatedAt: quote.updatedAt
                )
            }
            try await client
                .from("quotes")
                .upsert(remoteQuotes, onConflict: "id")
                .execute()

            dirtyQuotes.forEach { $0.needsSync = false }
        }

        // --- Vocab Words ---
        let vocabDescriptor = FetchDescriptor<VocabWord>(
            predicate: #Predicate { $0.needsSync == true }
        )
        let dirtyVocab = (try? modelContext.fetch(vocabDescriptor)) ?? []

        if !dirtyVocab.isEmpty {
            let remoteVocab: [RemoteVocabWord] = dirtyVocab.map { word in
                let remoteID = word.remoteID ?? UUID()
                word.remoteID = remoteID
                return RemoteVocabWord(
                    id: remoteID,
                    userId: userId,
                    localId: word.id,
                    word: word.word,
                    definition: word.definition,
                    dateAdded: word.dateAdded,
                    updatedAt: word.updatedAt
                )
            }
            try await client
                .from("vocab_words")
                .upsert(remoteVocab, onConflict: "id")
                .execute()

            dirtyVocab.forEach { $0.needsSync = false }
        }

        // Persist the remoteID and needsSync = false changes back to SwiftData.
        try? modelContext.save()
    }

    // MARK: - Sync Down

    /// Pulls all remote rows for the current authenticated user and returns them as model instances.
    /// Does NOT insert them into any `ModelContext` — the caller is responsible for merging
    /// the returned records against local data using the last-write-wins strategy on `updatedAt`.
    ///
    /// - Returns: A tuple of arrays of `Book`, `Quote`, and `VocabWord` instances ready for merging.
    /// - Note: This method is a no-op if there is no active internet connection.
    func syncDown() async throws -> (books: [Book], quotes: [Quote], vocabWords: [VocabWord]) {
        guard isConnected else {
            return ([], [], [])
        }

        guard AuthManager.shared.currentUser != nil else {
            return ([], [], [])
        }

        let client = AuthManager.shared.client

        // Fetch remote books
        let remoteBooks: [RemoteBook] = try await client
            .from("books")
            .select()
            .execute()
            .value

        // Fetch remote quotes
        let remoteQuotes: [RemoteQuote] = try await client
            .from("quotes")
            .select()
            .execute()
            .value

        // Fetch remote vocab words
        let remoteVocab: [RemoteVocabWord] = try await client
            .from("vocab_words")
            .select()
            .execute()
            .value

        // Map remote DTOs to local model instances.
        // These are NOT yet inserted into a ModelContext — the caller merges them.
        let books: [Book] = remoteBooks.map { remote in
            let book = Book(
                id: remote.localId,
                title: remote.title,
                author: remote.author,
                coverID: remote.coverId,
                olid: remote.olid,
                shelf: Shelf(rawValue: remote.shelf) ?? .bucketList
            )
            book.dateAdded = remote.dateAdded
            book.remoteID = remote.id
            book.updatedAt = remote.updatedAt
            // Downloaded records are already in sync with remote.
            book.needsSync = false
            return book
        }

        let quotes: [Quote] = remoteQuotes.map { remote in
            let quote = Quote(
                id: remote.localId,
                text: remote.text,
                bookTitle: remote.bookTitle
            )
            quote.dateAdded = remote.dateAdded
            quote.remoteID = remote.id
            quote.updatedAt = remote.updatedAt
            quote.needsSync = false
            return quote
        }

        let vocabWords: [VocabWord] = remoteVocab.map { remote in
            let word = VocabWord(
                id: remote.localId,
                word: remote.word,
                definition: remote.definition
            )
            word.dateAdded = remote.dateAdded
            word.remoteID = remote.id
            word.updatedAt = remote.updatedAt
            word.needsSync = false
            return word
        }

        return (books, quotes, vocabWords)
    }
}

// MARK: - NWPathMonitor async extension

private extension NWPathMonitor {
    /// An `AsyncStream` of `NWPath` values emitted whenever the network path changes.
    var paths: AsyncStream<NWPath> {
        AsyncStream { continuation in
            self.pathUpdateHandler = { path in
                continuation.yield(path)
            }
        }
    }
}
