import SwiftUI
import SwiftData

/// A custom, Spotlight-like search interface that overlays the current screen.
/// It searches books using the Open Library API and displays them in a card-like layout
/// that sits on top of the parent view.
struct SpotlightSearchOverlay: View {
    // Binding to control the visibility of the overlay from the parent view.
    @Binding var isPresented: Bool

    // State properties for query input, search results, and API states.
    @State private var query = ""
    @State private var results: [BookSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    // Tracks which book has been tapped to show its details sheet.
    @State private var selectedBook: BookSearchResult?
    
    // Keeps track of the active asynchronous search task. Used to cancel prior search
    // tasks when the user continues typing (debounce mechanism).
    @State private var searchTask: Task<Void, Never>?
    
    // Focus state to automatically request keyboard focus when the search overlay is presented.
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Semi-transparent dimming background that covers the entire screen.
            // Tapping it dismisses the search overlay with an animation.
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isPresented = false
                    }
                }

            // The Spotlight Search Panel container
            VStack(spacing: 0) {
                // Search input text field
                searchBar
                    .padding()
                
                // Dynamic content section based on search states
                if isLoading {
                    loadingView
                } else if let error = errorMessage {
                    errorView(message: error)
                } else if results.isEmpty && !query.isEmpty {
                    emptyResultsView
                } else if !results.isEmpty {
                    resultsList
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 10)
            // Positioned towards the top/middle of the screen, matching Spotlight's native behavior.
            .padding(.top, 20)
            .frame(maxHeight: 600, alignment: .top)
            // Presents the BookDetailSheet modal when a search result is tapped.
            .sheet(item: $selectedBook) { book in
                BookDetailSheet(result: book)
            }
        }
        // Animates the fade-in and fade-out of the entire overlay view.
        .opacity(isPresented ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: isPresented)
        // Monitored query changes: Schedules a new search task whenever the input changes.
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
        // Automatically focuses the search field when the overlay is displayed.
        .onChange(of: isPresented) { _, presented in
            if presented {
                isFocused = true
            } else {
                isFocused = false
            }
        }
    }

    // MARK: - Subviews

    /// Renders the search bar containing a magnifying glass, the text input, and a clear button.
    private var searchBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.title3)
            
            TextField("Search books to add...", text: $query)
                .focused($isFocused)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .font(.title3)
                .onSubmit { scheduleSearch(for: query) } // Triggers instant search on Return/Search key
            
            // X icon clear button appears only when there is query text.
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// Loading spinner view shown while fetching results.
    private var loadingView: some View {
        VStack {
            ProgressView()
                .padding()
        }
        .frame(maxWidth: .infinity)
    }

    /// Error message container shown if the API request fails.
    private func errorView(message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    /// Empty results state shown when query does not return any matches.
    private var emptyResultsView: some View {
        VStack(spacing: 8) {
            Image(systemName: "book.closed")
                .foregroundColor(.secondary.opacity(0.6))
            Text("No results for \"\(query)\"")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity)
    }

    /// Scrollable container showing the lists of books retrieved from Open Library.
    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(results) { result in
                    Button {
                        selectedBook = result
                    } label: {
                        SearchResultRow(result: result)
                            .padding(.horizontal)
                    }
                    .buttonStyle(.plain)
                    
                    // Adds a separator divider between list elements, except after the last element.
                    if result.id != results.last?.id {
                        Divider()
                            .padding(.leading, 70) // Indented to align with the text content (skipping the cover thumbnail).
                    }
                }
            }
            .padding(.vertical, 8)
        }
        // Enforces a maximum height limit so the results list doesn't take over the screen.
        .frame(maxHeight: 400)
    }

    // MARK: - Logic

    /// Debounces and schedules the search task to avoid sending requests to the API for every keystroke.
    /// Cancels any existing task and initiates a new one with a 400ms delay.
    private func scheduleSearch(for value: String) {
        searchTask?.cancel() // Cancel previous API lookup task
        
        // Return early if the query is empty or whitespace only
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        
        // Schedule a new async task
        searchTask = Task {
            // Wait for 400ms to see if the user stops typing
            try? await Task.sleep(nanoseconds: 400_000_000)
            
            // If the user typed something else and this task was canceled during sleep, stop execution.
            guard !Task.isCancelled else { return }
            
            // Execute the API call on the main thread
            await performSearch(query: value)
        }
    }

    /// Makes the network request to Open Library API.
    /// Runs on the MainActor (Main Thread) to update the @State variables safely.
    @MainActor
    private func performSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        do {
            // Call the OpenLibrary service to request data
            results = try await OpenLibraryService.shared.search(query: query)
        } catch {
            // Verify if the error wasn't triggered by search task cancellation
            guard !Task.isCancelled else { return }
            errorMessage = "Search failed. Check your connection."
            results = []
        }
        isLoading = false
    }
}
