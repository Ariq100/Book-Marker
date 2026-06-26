import SwiftUI
import SwiftData

struct SearchView: View {
    @State private var query = ""
    @State private var results: [BookSearchResult] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedBook: BookSearchResult?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                Divider()

                ZStack {
                    if isLoading {
                        loadingView
                    } else if let error = errorMessage {
                        errorView(message: error)
                    } else if results.isEmpty && !query.isEmpty {
                        emptyResultsView
                    } else if results.isEmpty {
                        promptView
                    } else {
                        resultsList
                    }
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .sheet(item: $selectedBook) { book in
                BookDetailSheet(result: book)
            }
        }
        .onChange(of: query) { _, newValue in
            scheduleSearch(for: newValue)
        }
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Title, author, or ISBN…", text: $query)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .onSubmit { scheduleSearch(for: query) }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .scaleEffect(1.3)
            Text("Searching…")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
    }

    private var emptyResultsView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "book.closed")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.6))
            Text("No results for \"\(query)\"")
                .font(.subheadline)
                .foregroundColor(.secondary)                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var promptView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo, .purple],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text("Find your next read")
                .font(.title3.weight(.semibold))
            Text("Search by title, author, or any keyword")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var resultsList: some View {
        List(results) { result in
            Button {
                selectedBook = result
            } label: {
                SearchResultRow(result: result)
            }
            .buttonStyle(.plain)
            .listRowSeparatorTint(Color(.systemGray5))
        }
        .listStyle(.plain)
    }

    // MARK: - Logic

    private func scheduleSearch(for value: String) {
        searchTask?.cancel()
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else {
            results = []
            errorMessage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000) // 400 ms debounce
            guard !Task.isCancelled else { return }
            await performSearch(query: value)
        }
    }

    @MainActor
    private func performSearch(query: String) async {
        isLoading = true
        errorMessage = nil
        do {
            results = try await OpenLibraryService.shared.search(query: query)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "Search failed. Check your connection and try again."
            results = []
        }
        isLoading = false
    }
}

// MARK: - Row

struct SearchResultRow: View {
    let result: BookSearchResult

    var body: some View {
        HStack(spacing: 14) {
            CoverImageView(coverID: result.coverID, size: .small)
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(result.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let year = result.firstPublishYear {
                    Text(String(year))
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.8))
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
    }
}
