import SwiftUI

struct ContentView: View {
    @State private var authManager = AuthManager.shared
    @State private var showSettings = false
    
    var body: some View {
        Group {
            if authManager.isAuthenticated {
                mainTabView
            } else {
                AuthView()
            }
        }
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
