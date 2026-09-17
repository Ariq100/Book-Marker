import SwiftUI
import SwiftData

struct AddQuoteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Book.title) private var allBooks: [Book]

    private var readingBooks: [Book] {
        allBooks.filter { $0.shelf == .reading }
    }

    @State private var selectedBook: Book?
    @State private var quoteText = ""
    
    // Autocomplete state
    @State private var suggestions: [String] = []
    @State private var fetchTask: Task<Void, Never>?
    @State private var isShowingEmptyAlert = false

    private enum FocusField: Hashable { case quoteField }
    @FocusState private var focus: FocusField?

    private var canSave: Bool {
        selectedBook != nil && !quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if readingBooks.isEmpty {
                    // Fallback empty view behind the alert
                    Color(.systemGroupedBackground).ignoresSafeArea()
                } else if selectedBook == nil {
                    bookSelectionList
                } else {
                    quoteEntryForm
                }
            }
            .navigationTitle(selectedBook == nil ? "Select Book" : "Add Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if selectedBook != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change Book") { 
                            withAnimation {
                                selectedBook = nil
                                quoteText = ""
                                suggestions = []
                            }
                        }
                        .font(.subheadline)
                    }
                }
            }
            .onAppear {
                if readingBooks.isEmpty {
                    isShowingEmptyAlert = true
                } else {
                    // Prewarm cache for reading books
                    BookContentService.shared.prewarm(books: readingBooks)
                }
            }
            .alert("Reading List Empty", isPresented: $isShowingEmptyAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("You need to add books to your Reading shelf before you can save quotes.")
            }
        }
    }

    // MARK: - Book Selection

    private var bookSelectionList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(readingBooks) { book in
                    Button {
                        withAnimation {
                            selectedBook = book
                        }
                        // Give the UI a moment to transition before focusing
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            focus = .quoteField
                        }
                    } label: {
                        bookCard(for: book)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func bookCard(for book: Book) -> some View {
        HStack(spacing: 16) {
            CachedCoverImageView(book: book, size: .medium)
                .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(book.title)
                    .font(.headline)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                
                Text(book.author)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            
            Image(systemName: "chevron.right")
                .foregroundColor(Color(.systemGray3))
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }

    // MARK: - Quote Entry

    private var quoteEntryForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let book = selectedBook {
                    HStack(spacing: 12) {
                        CachedCoverImageView(book: book, size: .small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(book.author)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Quote", systemImage: "quote.opening")
                        .font(.headline)

                    ZStack(alignment: .topLeading) {
                        VStack(spacing: 0) {
                            TextEditor(text: $quoteText)
                                .focused($focus, equals: .quoteField)
                                .frame(minHeight: 120)
                                .scrollContentBackground(.hidden)
                                .padding(12)
                                .onChange(of: quoteText) { _, newValue in
                                    updateSuggestions(for: newValue)
                                }
                            
                            if !suggestions.isEmpty {
                                Divider()
                                autocompleteDropdown
                            }
                        }
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        if quoteText.isEmpty {
                            Text("Start typing a sentence...")
                                .foregroundColor(.secondary)
                                .allowsHitTesting(false)
                                .padding(.top, 20)
                                .padding(.leading, 16)
                        }
                    }
                }

                saveButton
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }
    
    private var autocompleteDropdown: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(5), id: \.self) { suggestion in
                Button {
                    quoteText = suggestion
                    suggestions = []
                    focus = nil // unfocus
                } label: {
                    HStack {
                        Text(suggestion)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                        Spacer()
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)
                
                if suggestion != suggestions.prefix(5).last {
                    Divider().padding(.leading, 12)
                }
            }
        }
        .background(Color(.secondarySystemGroupedBackground))
    }

    // MARK: - Save

    private var saveButton: some View {
        Button {
            saveQuote()
        } label: {
            Text("Save Quote")
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
                .padding(16)
                .background(canSave ? Color.indigo : Color(.systemGray4))
                .foregroundColor(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .animation(.easeInOut(duration: 0.2), value: canSave)
        }
        .disabled(!canSave)
    }

    // MARK: - Logic

    private func updateSuggestions(for text: String) {
        guard let book = selectedBook else { return }
        fetchTask?.cancel()
        
        guard text.count >= 3 else {
            suggestions = []
            return
        }
        
        fetchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            
            let results = await BookContentService.shared.suggestions(for: book, matching: text)
            guard !Task.isCancelled else { return }
            
            withAnimation(.easeInOut(duration: 0.2)) {
                suggestions = results
            }
        }
    }

    private func saveQuote() {
        guard let book = selectedBook else { return }
        let quote = Quote(
            text: quoteText.trimmingCharacters(in: .whitespacesAndNewlines),
            bookTitle: book.title,
            bookID: book.id
        )
        modelContext.insert(quote)
        dismiss()
    }
}
