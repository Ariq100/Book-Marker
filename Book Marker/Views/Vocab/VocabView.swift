import SwiftUI
import SwiftData

struct VocabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \VocabWord.dateAdded, order: .reverse) private var allWords: [VocabWord]

    @State private var searchText = ""
    @State private var showingAddWord = false

    private var filteredWords: [VocabWord] {
        guard !searchText.isEmpty else { return allWords }
        let q = searchText.lowercased()
        return allWords.filter {
            $0.word.lowercased().contains(q) || $0.definition.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if allWords.isEmpty {
                    emptyStateView
                } else if filteredWords.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    wordList
                }
            }
            .navigationTitle("Vocab")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText, prompt: "Search by word or meaning…")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAddWord = true
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
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
            Image(systemName: "character.book.closed.fill")
                .font(.system(size: 56))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo.opacity(0.7), .purple.opacity(0.5)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            Text("Build your vocabulary")
                .font(.title3.weight(.semibold))
            Text("Tap + to look up and save a new word")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }

    private var wordList: some View {
        List {
            ForEach(filteredWords) { word in
                VocabWordRow(word: word)
                    .listRowSeparatorTint(Color(.systemGray5))
            }
            .onDelete { indexSet in
                indexSet.forEach { modelContext.delete(filteredWords[$0]) }
            }
        }
        .listStyle(.plain)
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
