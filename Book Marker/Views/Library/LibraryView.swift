import SwiftUI
import SwiftData

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Book.dateAdded, order: .reverse) private var allBooks: [Book]
    @State private var selectedShelf: Shelf = .reading

    private var booksOnShelf: [Book] {
        allBooks.filter { $0.shelf == selectedShelf }
    }

    private let columns = [
        GridItem(.adaptive(minimum: 100, maximum: 130), spacing: 16)
    ]

    @State private var showingSearch = false

    var body: some View {
        NavigationStack {
            ZStack {
                VStack(spacing: 0) {
                    shelfPicker
                        .padding(.horizontal)
                        .padding(.bottom, 8)

                    Divider()

                    if booksOnShelf.isEmpty {
                        emptyShelfView
                    } else {
                        bookGrid
                    }
                }
                
                if showingSearch {
                    SpotlightSearchOverlay(isPresented: $showingSearch)
                        // Make sure it sits on top of everything
                        .zIndex(2)
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSearch = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                }
            }
        }
    }

    // MARK: - Subviews

    private var shelfPicker: some View {
        Picker("Shelf", selection: $selectedShelf.animation()) {
            ForEach(Shelf.allCases, id: \.self) { shelf in
                Text(shelf.rawValue).tag(shelf)
            }
        }
        .pickerStyle(.segmented)
        .padding(.top, 8)
    }

    private var emptyShelfView: some View {
        VStack(spacing: 16) {
            Spacer()
            
            Image(systemName: selectedShelf.systemImage)
                .font(.system(size: 52))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.indigo.opacity(0.6), .purple.opacity(0.4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            
            Text("No books here yet")
                .font(.title3.weight(.semibold))
                
            Text("Click the (+) icon to add something")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Spacer()
        }
    }

    private var bookGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(booksOnShelf) { book in
                    BookGridCell(book: book, onMove: { newShelf in
                        withAnimation { book.shelf = newShelf }
                    }, onDelete: {
                        withAnimation { modelContext.delete(book) }
                    })
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Grid Cell

struct BookGridCell: View {
    let book: Book
    let onMove: (Shelf) -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            CachedCoverImageView(book: book, size: .medium)
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)

            VStack(spacing: 3) {
                Text(book.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                Text(book.author)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .contextMenu {
            Menu("Move to…") {
                ForEach(Shelf.allCases.filter { $0 != book.shelf }, id: \.self) { shelf in
                    Button {
                        onMove(shelf)
                    } label: {
                        Label(shelf.rawValue, systemImage: shelf.systemImage)
                    }
                }
            }
            Divider()
            Button(role: .destructive, action: onDelete) {
                Label("Remove from Library", systemImage: "trash")
            }
        }
    }
}
