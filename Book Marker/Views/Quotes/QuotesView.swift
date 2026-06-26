import SwiftUI
import SwiftData

struct QuotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Quote.dateAdded, order: .reverse) private var allQuotes: [Quote]

    @State private var searchText = ""
    @State private var showingAddQuote = false

    private var filteredQuotes: [Quote] {
        guard !searchText.isEmpty else { return allQuotes }
        let q = searchText.lowercased()
        return allQuotes.filter {
            $0.text.lowercased().contains(q) || $0.bookTitle.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allQuotes.isEmpty {
                    emptyStateView
                } else if filteredQuotes.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    quoteList
                }
            }
            .navigationTitle("Quotes")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search quotes or book titles…")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddQuote = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
            }
            .sheet(isPresented: $showingAddQuote) {
                AddQuoteView()
            }
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "quote.opening")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo.opacity(0.7), .purple.opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text("No quotes yet")
                .font(.title3.weight(.semibold))
            Text("Tap + to save a line that stayed with you")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var quoteList: some View {
        List {
            ForEach(filteredQuotes) { quote in
                QuoteRow(quote: quote)
                    .listRowSeparatorTint(Color(.systemGray5))
            }
            .onDelete { indexSet in
                indexSet.forEach { modelContext.delete(filteredQuotes[$0]) }
            }
        }
        .listStyle(.plain)
    }
}

// MARK: - Quote Row

struct QuoteRow: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("No results for \"\"")
                .font(.subheadline)
                .foregroundColor(.secondary)                .font(.body)
                .italic()
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.indigo)
                    .frame(width: 3, height: 14)
                Text(quote.bookTitle)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.indigo)
            }
        }
        .padding(.vertical, 8)
    }
}
