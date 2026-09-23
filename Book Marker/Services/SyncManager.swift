//
//  SyncManager.swift
//  Book Marker
//
//  TASK 6

// WHY @MainActor RATHER THAN AN ACTOR:
// SwiftData `@Model` objects and `ModelContext` are bound to the context's actor, and the app's
// context is the main one. The previous `actor` version read and mutated models from the actor's
// own executor — a data race SwiftData does not tolerate. Running on the main actor keeps every
// model access on the right thread; the network calls still `await` and so never block the UI.
// Overlapping requests are serialized with `isSyncing` / `needsAnotherPass` instead.

// REQUIRED SUPABASE RLS POLICIES — see supabase/migrations/ for the actual, versioned SQL
// (0001_enable_rls_and_ownership_policies.sql) rather than duplicating it here. Every
// user-owned table (books, quotes, vocab_words) has RLS enabled with SELECT/INSERT/UPDATE/DELETE
// policies scoped to `auth.uid() = user_id`, including WITH CHECK on INSERT/UPDATE so a client
// can never spoof or reassign ownership. See SECURITY.md for the full model and how to run the
// RLS test suite in supabase/tests/rls_tests.sql.

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
import OSLog
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
    var coverUrl: String?
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
        case coverUrl    = "cover_url"
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
    /// FK to `books.id` (the REMOTE book id, i.e. `Book.remoteID`) — not the local SwiftData id.
    var bookId: UUID?
    var pageNumber: Int?
    var note: String?
    var dateAdded: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case localId   = "local_id"
        case text
        case bookTitle = "book_title"
        case bookId    = "book_id"
        case pageNumber = "page_number"
        case note
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
    /// FK to `books.id` (the REMOTE book id, i.e. `Book.remoteID`) — not the local SwiftData id.
    var bookId: UUID?
    var pageNumber: Int?
    var note: String?
    var dateAdded: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId    = "user_id"
        case localId   = "local_id"
        case word
        case definition
        case bookId    = "book_id"
        case pageNumber = "page_number"
        case note
        case dateAdded = "date_added"
        case updatedAt = "updated_at"
    }
}

// MARK: - SyncManager

@MainActor
final class SyncManager {
    static let shared = SyncManager()

    private let logger = Logger(subsystem: "com.bookmarker.app", category: "Sync")

    /// The main-actor context views write to. Set once by `start(context:)`.
    private var context: ModelContext?
    private var isSyncing = false
    private var needsAnotherPass = false
    private var debounceTask: Task<Void, Never>?
    private var saveObserver: NSObjectProtocol?

    // Only used to kick off a sync when connectivity returns. Requests are not gated on it: the
    // monitor reports nothing until its first callback, so gating on it silently skipped the
    // launch sync. An offline request simply fails and is retried on the next trigger.
    private let monitor = NWPathMonitor()
    private var wasConnected = true

    private static let ownerDefaultsKey = "syncOwnerUserID"

    private init() {}

    /// Wires the manager to the app's main context. Local saves (SwiftUI autosave or explicit
    /// `save()` calls) schedule a debounced push, and regaining connectivity triggers a sync.
    func start(context: ModelContext) {
        guard self.context == nil else { return }
        self.context = context

        saveObserver = NotificationCenter.default.addObserver(
            forName: ModelContext.didSave, object: context, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isSyncing else { return }
                self.requestSync()
            }
        }

        monitor.pathUpdateHandler = { [weak self] path in
            let connected = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if connected && !self.wasConnected { self.requestSync() }
                self.wasConnected = connected
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.bookmarker.SyncManager.NWPathMonitor"))
    }

    /// Coalesces bursts of edits into a single sync shortly afterwards.
    func requestSync(after delay: Duration = .seconds(2)) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    /// Called whenever the signed-in user changes. Local data belonging to a *different* account
    /// is wiped before syncing — otherwise the next sync would upload the previous user's books
    /// into this user's account.
    func userDidChange(to userID: UUID?) async {
        guard let userID else { return }
        let defaults = UserDefaults.standard
        let previousOwner = defaults.string(forKey: Self.ownerDefaultsKey).flatMap(UUID.init)
        if let previousOwner, previousOwner != userID {
            resetLocalData()
        }
        defaults.set(userID.uuidString, forKey: Self.ownerDefaultsKey)
        await syncNow()
    }

    /// Removes every locally stored record. Called on explicit sign-out and account deletion so
    /// the next person to use the device can't see the previous account's library.
    func resetLocalData() {
        debounceTask?.cancel()
        UserDefaults.standard.removeObject(forKey: Self.ownerDefaultsKey)
        // Cached HTTP responses (book searches, dictionary lookups) can reveal what the previous
        // account was reading.
        URLCache.shared.removeAllCachedResponses()
        guard let context else { return }
        do {
            try context.delete(model: Quote.self)
            try context.delete(model: VocabWord.self)
            try context.delete(model: Book.self)
            try context.delete(model: PendingDeletion.self)
            try context.save()
        } catch {
            logger.error("Failed to reset local data: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// True when there are local edits or deletions not yet in Supabase.
    func hasUnsyncedChanges() -> Bool {
        guard let context else { return false }
        let dirty = (try? context.fetchCount(FetchDescriptor<Book>(predicate: #Predicate { $0.needsSync }))) ?? 0
            + ((try? context.fetchCount(FetchDescriptor<Quote>(predicate: #Predicate { $0.needsSync }))) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor<VocabWord>(predicate: #Predicate { $0.needsSync }))) ?? 0)
            + ((try? context.fetchCount(FetchDescriptor<PendingDeletion>())) ?? 0)
        return dirty > 0
    }

    /// Pushes local changes, then pulls and merges remote changes. Safe to call at any time:
    /// a call made while a sync is running schedules exactly one more pass afterwards.
    func syncNow() async {
        guard let context, let userID = AuthManager.shared.currentUser?.id else { return }
        if isSyncing {
            needsAnotherPass = true
            return
        }
        isSyncing = true
        defer { isSyncing = false }

        repeat {
            needsAnotherPass = false
            do {
                try await pushDeletions(context: context)
                try await syncUp(context: context, userID: userID)
                try await syncDown(context: context)
                try context.save()
            } catch {
                // Offline or transient server errors: leave needsSync set and retry on the next
                // trigger. Never surface raw errors — they can include server internals.
                logger.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                return
            }
        } while needsAnotherPass
    }

    // MARK: - Deletions

    private func pushDeletions(context: ModelContext) async throws {
        let tombstones = try context.fetch(FetchDescriptor<PendingDeletion>())
        guard !tombstones.isEmpty else { return }
        let client = AuthManager.shared.client

        // Quotes and words first, books last, so the book_id foreign keys never block a delete.
        for table in ["quotes", "vocab_words", "books"] {
            let batch = tombstones.filter { $0.table == table }
            guard !batch.isEmpty else { continue }
            try await client
                .from(table)
                .delete()
                .in("id", values: batch.map { $0.remoteID.uuidString })
                .execute()
            batch.forEach { context.delete($0) }
        }
    }

    // MARK: - Sync Up

    /// Pushes every local record where `needsSync == true` to Supabase using upsert semantics.
    private func syncUp(context: ModelContext, userID: UUID) async throws {
        let client = AuthManager.shared.client

        // --- Books --- (first, so quotes/words below can reference them by FK)
        let dirtyBooks = try context.fetch(FetchDescriptor<Book>(predicate: #Predicate { $0.needsSync }))
        if !dirtyBooks.isEmpty {
            let snapshot = dirtyBooks.map { ($0, $0.updatedAt) }
            let rows: [RemoteBook] = dirtyBooks.map { book in
                let remoteID = book.remoteID ?? UUID()
                book.remoteID = remoteID
                return RemoteBook(
                    id: remoteID,
                    userId: userID,
                    localId: book.id,
                    title: book.title,
                    author: book.author,
                    coverId: book.coverID,
                    coverUrl: book.coverURLString,
                    olid: book.olid,
                    shelf: book.shelf.rawValue,
                    dateAdded: book.dateAdded,
                    updatedAt: book.updatedAt
                )
            }
            try await client.from("books").upsert(rows, onConflict: "id").execute()
            Self.markSynced(snapshot)
        }

        // Every book that exists locally has now been pushed at least once, so a missing
        // remoteID means the book is gone — send no FK rather than inventing one that would
        // violate the foreign key constraint and fail the whole batch.
        func remoteBookID(for localBookID: UUID?) -> UUID? {
            guard let localBookID else { return nil }
            let descriptor = FetchDescriptor<Book>(predicate: #Predicate { $0.id == localBookID })
            return (try? context.fetch(descriptor))?.first?.remoteID
        }

        // --- Quotes ---
        let dirtyQuotes = try context.fetch(FetchDescriptor<Quote>(predicate: #Predicate { $0.needsSync }))
        if !dirtyQuotes.isEmpty {
            let snapshot = dirtyQuotes.map { ($0, $0.updatedAt) }
            let rows: [RemoteQuote] = dirtyQuotes.map { quote in
                let remoteID = quote.remoteID ?? UUID()
                quote.remoteID = remoteID
                return RemoteQuote(
                    id: remoteID,
                    userId: userID,
                    localId: quote.id,
                    text: quote.text,
                    bookTitle: quote.bookTitle,
                    bookId: remoteBookID(for: quote.bookID),
                    pageNumber: quote.pageNumber,
                    note: quote.note,
                    dateAdded: quote.dateAdded,
                    updatedAt: quote.updatedAt
                )
            }
            try await client.from("quotes").upsert(rows, onConflict: "id").execute()
            Self.markSynced(snapshot)
        }

        // --- Vocab Words ---
        let dirtyWords = try context.fetch(FetchDescriptor<VocabWord>(predicate: #Predicate { $0.needsSync }))
        if !dirtyWords.isEmpty {
            let snapshot = dirtyWords.map { ($0, $0.updatedAt) }
            let rows: [RemoteVocabWord] = dirtyWords.map { word in
                let remoteID = word.remoteID ?? UUID()
                word.remoteID = remoteID
                return RemoteVocabWord(
                    id: remoteID,
                    userId: userID,
                    localId: word.id,
                    word: word.word,
                    definition: word.definition,
                    bookId: remoteBookID(for: word.bookID),
                    pageNumber: word.pageNumber,
                    note: word.note,
                    dateAdded: word.dateAdded,
                    updatedAt: word.updatedAt
                )
            }
            try await client.from("vocab_words").upsert(rows, onConflict: "id").execute()
            Self.markSynced(snapshot)
        }
    }

    /// Clears `needsSync` only on records that weren't edited again while the upload was in
    /// flight — an edit made during the `await` must still be pushed on the next pass.
    private static func markSynced<M: SyncableModel>(_ snapshot: [(M, Date)]) {
        for (model, pushedVersion) in snapshot where model.updatedAt == pushedVersion {
            model.needsSync = false
        }
    }

    // MARK: - Sync Down

    /// Pulls every remote row for the current user and merges it into the local store:
    /// - rows unknown locally are inserted (unless a local deletion is still pending),
    /// - rows newer than the local copy overwrite it, unless the local copy has unpushed edits,
    /// - synced local records whose remote row is gone were deleted on another device.
    private func syncDown(context: ModelContext) async throws {
        let client = AuthManager.shared.client

        let remoteBooks: [RemoteBook] = try await client.from("books").select().execute().value
        let remoteQuotes: [RemoteQuote] = try await client.from("quotes").select().execute().value
        let remoteWords: [RemoteVocabWord] = try await client.from("vocab_words").select().execute().value

        let pendingDeletes = Set(try context.fetch(FetchDescriptor<PendingDeletion>()).map(\.remoteID))

        // --- Books ---
        let localBooks = try context.fetch(FetchDescriptor<Book>())
        let booksByRemoteID = Dictionary(localBooks.compactMap { b in b.remoteID.map { ($0, b) } }, uniquingKeysWith: { a, _ in a })
        for remote in remoteBooks where !pendingDeletes.contains(remote.id) {
            if let local = booksByRemoteID[remote.id] {
                guard Self.remoteWins(remote.updatedAt, over: local) else { continue }
                local.title = remote.title
                local.author = remote.author
                local.coverID = remote.coverId
                local.coverURLString = remote.coverUrl
                local.olid = remote.olid
                local.shelf = Shelf(rawValue: remote.shelf) ?? local.shelf
                local.updatedAt = remote.updatedAt
            } else {
                let book = Book(
                    id: remote.localId,
                    title: remote.title,
                    author: remote.author,
                    coverID: remote.coverId,
                    coverURLString: remote.coverUrl,
                    olid: remote.olid,
                    shelf: Shelf(rawValue: remote.shelf) ?? .bucketList
                )
                book.dateAdded = remote.dateAdded
                book.remoteID = remote.id
                book.updatedAt = remote.updatedAt
                book.needsSync = false
                context.insert(book)
            }
        }
        Self.removeDeletedElsewhere(localBooks, remoteIDs: Set(remoteBooks.map(\.id)), context: context)

        // quotes/words store the REMOTE book id; map it back to the local SwiftData Book.id.
        let remoteToLocalBookID = Dictionary(remoteBooks.map { ($0.id, $0.localId) }, uniquingKeysWith: { a, _ in a })

        // --- Quotes ---
        let localQuotes = try context.fetch(FetchDescriptor<Quote>())
        let quotesByRemoteID = Dictionary(localQuotes.compactMap { q in q.remoteID.map { ($0, q) } }, uniquingKeysWith: { a, _ in a })
        for remote in remoteQuotes where !pendingDeletes.contains(remote.id) {
            let bookID = remote.bookId.flatMap { remoteToLocalBookID[$0] }
            if let local = quotesByRemoteID[remote.id] {
                guard Self.remoteWins(remote.updatedAt, over: local) else { continue }
                local.text = remote.text
                local.bookTitle = remote.bookTitle
                local.bookID = bookID
                local.pageNumber = remote.pageNumber
                local.note = remote.note
                local.updatedAt = remote.updatedAt
            } else {
                let quote = Quote(
                    id: remote.localId,
                    text: remote.text,
                    bookTitle: remote.bookTitle,
                    bookID: bookID,
                    pageNumber: remote.pageNumber,
                    note: remote.note
                )
                quote.dateAdded = remote.dateAdded
                quote.remoteID = remote.id
                quote.updatedAt = remote.updatedAt
                quote.needsSync = false
                context.insert(quote)
            }
        }
        Self.removeDeletedElsewhere(localQuotes, remoteIDs: Set(remoteQuotes.map(\.id)), context: context)

        // --- Vocab Words ---
        let localWords = try context.fetch(FetchDescriptor<VocabWord>())
        let wordsByRemoteID = Dictionary(localWords.compactMap { w in w.remoteID.map { ($0, w) } }, uniquingKeysWith: { a, _ in a })
        for remote in remoteWords where !pendingDeletes.contains(remote.id) {
            let bookID = remote.bookId.flatMap { remoteToLocalBookID[$0] }
            if let local = wordsByRemoteID[remote.id] {
                guard Self.remoteWins(remote.updatedAt, over: local) else { continue }
                local.word = remote.word
                local.definition = remote.definition
                local.bookID = bookID
                local.pageNumber = remote.pageNumber
                local.note = remote.note
                local.updatedAt = remote.updatedAt
            } else {
                let word = VocabWord(
                    id: remote.localId,
                    word: remote.word,
                    definition: remote.definition,
                    bookID: bookID,
                    pageNumber: remote.pageNumber,
                    note: remote.note
                )
                word.dateAdded = remote.dateAdded
                word.remoteID = remote.id
                word.updatedAt = remote.updatedAt
                word.needsSync = false
                context.insert(word)
            }
        }
        Self.removeDeletedElsewhere(localWords, remoteIDs: Set(remoteWords.map(\.id)), context: context)
    }

    /// Last-write-wins, except that a local record with unpushed edits is never overwritten.
    /// The 1 ms tolerance absorbs Postgres (microsecond) vs. Swift `Date` round-trip rounding,
    /// which would otherwise make every unchanged row look "newer" on every pull.
    private static func remoteWins<M: SyncableModel>(_ remoteUpdatedAt: Date, over local: M) -> Bool {
        !local.needsSync && remoteUpdatedAt.timeIntervalSince(local.updatedAt) > 0.001
    }

    private static func removeDeletedElsewhere<M: SyncableModel>(_ locals: [M], remoteIDs: Set<UUID>, context: ModelContext) {
        for model in locals {
            guard let remoteID = model.remoteID, !model.needsSync, !remoteIDs.contains(remoteID) else { continue }
            context.delete(model)
        }
    }
}

// MARK: - SyncableModel

/// The sync bookkeeping fields shared by Book, Quote and VocabWord.
protocol SyncableModel: PersistentModel {
    var remoteID: UUID? { get set }
    var needsSync: Bool { get set }
    var updatedAt: Date { get set }
}

extension Book: SyncableModel {}
extension Quote: SyncableModel {}
extension VocabWord: SyncableModel {}
