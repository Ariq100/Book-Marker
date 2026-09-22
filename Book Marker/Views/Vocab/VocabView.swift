import SwiftUI
import SwiftData

struct VocabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabWord.dateAdded, order: .reverse) private var allWords: [VocabWord]

    @State private var showingAddWord = false
    @State private var showingSearch = false
    @State private var searchText = ""
    @FocusState private var isSearchFocused: Bool

    private var filteredWords: [VocabWord] {
        guard !searchText.isEmpty else { return allWords }
        let q = searchText.lowercased()
        return allWords.filter {
            $0.word.lowercased().contains(q) || $0.definition.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VStack {
                    if allWords.isEmpty {
                        emptyStateView
                    } else {
                        wordList
                    }
                }
                
                if showingSearch {
                    searchOverlay
                        .zIndex(2)
                }
            }
            .navigationTitle("Vocab")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        if !allWords.isEmpty {
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
                            showingAddWord = true
                        } label: {
                            Image(systemName: "plus")
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddWord) {
                AddWordView()
            }
        }
    }

    // MARK: - Subviews

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo.opacity(0.6), .purple.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            Text("No words here yet")
                .font(.title3.weight(.semibold))
                
            Text("Click the (+) icon to add something")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
    }

    private var wordList: some View {
        List {
            ForEach(allWords) { word in
                VocabWordRow(word: word)
                    .listRowSeparatorTint(Color(.systemGray5))
            }
            .onDelete { indexSet in
                indexSet.forEach { modelContext.deleteSynced(allWords[$0]) }
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showingSearch = false
                        searchText = ""
                    }
                }

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.title3)
                    
                    TextField("Search words or meanings...", text: $searchText)
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
                .padding(12)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
                
                if !searchText.isEmpty {
                    if filteredWords.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "character.book.closed")
                                .foregroundColor(.secondary.opacity(0.6))
                            Text("No words found")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .frame(maxWidth: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredWords) { word in
                                    VocabWordRow(word: word)
                                        .padding(.horizontal)
                                        .padding(.vertical, 8)
                                    
                                    if word.id != filteredWords.last?.id {
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
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.2), radius: 20, x: 0, y: 10)
            .padding(.horizontal, 20)
            .padding(.top, 60)
            .frame(maxHeight: 600, alignment: .top)
        }
        .onAppear {
            isSearchFocused = true
        }
    }
}

// MARK: - Word Row

struct VocabWordRow: View {
    let word: VocabWord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(word.word)
                .font(.headline)

            Text(word.definition)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}
