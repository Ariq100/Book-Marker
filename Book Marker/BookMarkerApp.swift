import SwiftUI
import SwiftData

@main
struct BookMarkerApp: App {
    let container: ModelContainer

    init() {
        let schema = Schema([Book.self, Quote.self, VocabWord.self, PendingDeletion.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            container = try ModelContainer(for: schema, configurations: config)
        } catch {
            // Schema has changed (e.g. new sync fields added). Delete the old store and recreate.
            // Data will be restored from Supabase on next sync.
            let storeURL = config.url
            try? FileManager.default.removeItem(at: storeURL)
            // Also remove associated WAL/SHM files
            let wal = storeURL.appendingPathExtension("wal")
            let shm = storeURL.appendingPathExtension("shm")
            try? FileManager.default.removeItem(at: wal)
            try? FileManager.default.removeItem(at: shm)
            do {
                container = try ModelContainer(for: schema, configurations: config)
            } catch {
                fatalError("Failed to create ModelContainer even after store reset: \(error)")
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
