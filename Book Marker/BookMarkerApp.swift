import SwiftUI
import SwiftData

@main
struct BookMarkerApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(
                for: Book.self, Quote.self, VocabWord.self
            )
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(container)
    }
}
