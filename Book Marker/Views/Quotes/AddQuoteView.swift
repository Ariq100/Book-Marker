import SwiftUI
import SwiftData

struct AddQuoteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Book.title) private var allBooks: [Book]

    private var readingBooks: [Book] {
        allBooks.filter { $0.shelf == .reading }
    }

    @State private var bookSearch = ""
    @State private var selectedBook: Book?
    @State private var quoteText = ""

    private enum FocusField: Hashable { case bookField, quoteField }
    @FocusState private var focus: FocusField?

    private var filteredBooks: [Book] {
        if bookSearch.isEmpty { return readingBooks }
        let q = bookSearch.lowercased()
        return readingBooks.filter {
            $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q)
        }
    }

    private var showDropdown: Bool {
        focus == .bookField && selectedBook == nil && !filteredBooks.isEmpty
    }

    private var canSave: Bool {
        selectedBook != nil && !quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    bookSection
                    quoteSection
                    saveButton
                }
                .padding()
            }
            .navigationTitle("Add Quote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focus = .bookField }
        }
    }

    // MARK: - Book section

    private var bookSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Book", systemImage: "book.fill")
                .font(.headline)

            if readingBooks.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                    Text("Add books to your **Reading** shelf first")
                        .font(.subheadline)
                }
                .foregroundColor(.orange)
                .padding(14)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                bookInputArea
            }
        }
    }

    private var bookInputArea: some View {
        VStack(spacing: 0) {
            // Input / selected display
            ZStack {
                if let book = selectedBook {
                    selectedBookRow(book)
                } else {
                    bookSearchField
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            // Dropdown
            if showDropdown {
                bookDropdown
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: showDropdown)
    }

    private func selectedBookRow(_ book: Book) -> some View {
        HStack(spacing: 10) {
            CoverImageView(coverID: book.coverID, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(book.author)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                selectedBook = nil
                bookSearch = ""
                focus = .bookField
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.title3)
            }
        }
    }

    private var bookSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search your Reading shelf…", text: $bookSearch)
                .focused($focus, equals: .bookField)
                .autocorrectionDisabled()
        }
    }

    private var bookDropdown: some View {
        VStack(spacing: 0) {
            ForEach(Array(filteredBooks.enumerated()), id: \.element.id) { index, book in
                Button {
                    withAnimation {
                        selectedBook = book
                        bookSearch = ""
                        focus = .quoteField
                    }
                } label: {
                    HStack(spacing: 10) {
                        CoverImageView(coverID: book.coverID, size: .small)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(book.author)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if index < filteredBooks.count - 1 {
                    Divider().padding(.leading, 66)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 5)
        .padding(.top, 6)
        .zIndex(1)
    }

    // MARK: - Quote section

    private var quoteSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Quote", systemImage: "quote.opening")
                .font(.headline)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $quoteText)
                    .focused($focus, equals: .quoteField)
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)

                if quoteText.isEmpty {
                    Text("Type or paste the quote here…")
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Save button

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

    private func saveQuote() {
        guard let book = selectedBook else { return }
        let quote = Quote(
            text: quoteText.trimmingCharacters(in: .whitespacesAndNewlines),
            bookTitle: book.title
        )
        modelContext.insert(quote)
        dismiss()
    }
}
