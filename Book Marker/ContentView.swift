import SwiftUI

struct ContentView: View {
    @State private var authManager = AuthManager.shared
    @State private var showSettings = false
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        Group {
            if authManager.isRestoringSession {
                // A persisted session is still being read back from the Keychain. Showing
                // AuthView here would flash the login screen at every returning user.
                launchPlaceholder
            } else if authManager.isAuthenticated {
                mainTabView
            } else {
                AuthView()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: authManager.isRestoringSession)
        .task {
            SyncManager.shared.start(context: modelContext)
        }
        // Fires on launch once the session is restored, and again on every sign-in/switch.
        .task(id: authManager.currentUser?.id) {
            await SyncManager.shared.userDidChange(to: authManager.currentUser?.id)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                SyncManager.shared.requestSync(after: .zero)
            case .background:
                // Flush pending autosaves and push before iOS suspends the app.
                try? modelContext.save()
                Task { await SyncManager.shared.syncNow() }
            default:
                break
            }
        }
    }

    private var launchPlaceholder: some View {
        VStack(spacing: 16) {
            AppLogo(size: 96)
            ProgressView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
    
    private var mainTabView: some View {
        TabView {
            NavigationStack {
                LibraryView()
                    .toolbar {
                        ToolbarItem(placement: .navigationBarTrailing) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "gearshape")
                            }
                        }
                    }
                    .navigationDestination(isPresented: $showSettings) {
                        SettingsView()
                    }
            }
            .tabItem {
                Label("Library", systemImage: "books.vertical.fill")
            }

            QuotesView()
                .tabItem {
                    Label("Quotes", systemImage: "quote.opening")
                }

            VocabView()
                .tabItem {
                    Label("Vocab", systemImage: "character.book.closed.fill")
                }
        }
        .tint(.indigo)
    }
}
