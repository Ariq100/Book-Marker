import SwiftUI
import SwiftData

struct QuotesView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Quote.dateAdded, order: .reverse) private var allQuotes: [Quote]

    @State private var showingAddQuote = false
    @State private var showingSearch = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var filteredQuotes: [Quote] {
        guard !searchText.isEmpty else { return allQuotes }
        let q = searchText.lowercased()
        return allQuotes.filter {
            $0.text.lowercased().contains(q) || $0.bookTitle.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    if allQuotes.isEmpty {
                        emptyStateView
                    } else {
                        quoteList
                    }
                }
                
                if showingSearch {
                    searchOverlay
                        .zIndex(2)
                }
            }
            .navigationTitle("Quotes")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if !allQuotes.isEmpty {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showingSearch = true
                                }
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .fontWeight(.semibold)
                            }
                        }
                        
                        Button {
                            showingAddQuote = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
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
            Spacer()
            
            Image(systemName: "quote.opening")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo.opacity(0.6), .purple.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            Text("No quotes here yet")
                .font(.title3.weight(.semibold))
                
            Text("Click the (+) icon to add something")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
    }

    private var quoteList: some View {
        List {
            ForEach(allQuotes) { quote in
                QuoteRow(quote: quote)
                    .listRowSeparatorTint(Color(.systemGray5))
            }
            .onDelete { indexSet in
                indexSet.forEach { modelContext.deleteSynced(allQuotes[$0]) }
            }
        }
        .listStyle(.plain)
    }
    
    // MARK: - Search Overlay
    
    private var searchOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        showingSearch = false
                        searchText = ""
                    }
                }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.title3)
                    
                    TextField("Search quotes or books...", text: $searchText)
                        .focused($isSearchFocused)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .font(.title3)
                    
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.title3)
                        }
                    }
                }
                .padding(17)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 30))
                .padding()
                
                if !searchText.isEmpty {
                    if filteredQuotes.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "quote.closing")
                                .foregroundColor(.secondary.opacity(0.3))
                            Text("No quotes found")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredQuotes) { quote in
                                    QuoteRow(quote: quote)
                                        .padding(.horizontal)
                                        .padding(.vertical, 8)
                                    
                                    if quote.id != filteredQuotes.last?.id {
                                        Divider()
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .frame(maxHeight: 400)
                    }
                }
            }
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 30))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 10)
            .padding(.top, 30)
            .frame(maxHeight: 600, alignment: .top)
        }
        .onAppear {
            isSearchFocused = true
        }
    }
}

// MARK: - Quote Row

struct QuoteRow: View {
    let quote: Quote

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(quote.text)
                .font(.body)
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
