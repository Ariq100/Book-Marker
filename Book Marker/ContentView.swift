import SwiftUI

struct ContentView: View {
    @State private var authManager = AuthManager.shared
    @State private var showSettings = false
    
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
    }

    private var launchPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 48))
                .foregroundStyle(.indigo)
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
