import SwiftUI
import SwiftData

struct BookDetailSheet: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var savedBooks: [Book]

    let result: BookSearchResult
    @State private var selectedShelf: Shelf = .bucketList
    @State private var saved = false

    private var alreadySaved: Bool {
        savedBooks.contains { $0.title == result.title && $0.author == result.author }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Cover hero
                    coverHero

                    // Metadata
                    bookInfo

                    Divider().padding(.horizontal)

                    // Shelf selector
                    shelfSelector

                    // CTA
                    addButton
                        .padding(.horizontal)
                        .padding(.bottom, 24)
                }
                .padding(.top, 28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Subviews

    private var coverHero: some View {
        VStack {
            CoverImageView(imageURL: result.coverImageURL, size: .large)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 12)
        }
    }

    private var bookInfo: some View {
        VStack(spacing: 8) {
            Text(result.title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Text(result.author)
                .font(.subheadline)
                .foregroundColor(.secondary)

            if let year = result.firstPublishYear {
                Text("First published \(year)")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
            }
        }
    }

    private var shelfSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add to shelf")
                .font(.headline)
                .padding(.horizontal)

            ForEach(Shelf.allCases, id: \.self) { shelf in
                shelfRow(shelf)
            }
        }
    }

    private func shelfRow(_ shelf: Shelf) -> some View {
        let isSelected = selectedShelf == shelf
        return Button {
            withAnimation(.spring(response: 0.3)) {
                selectedShelf = shelf
            }
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.indigo : Color(.systemGray5))
                        .frame(width: 38, height: 38)
                    Image(systemName: shelf.systemImage)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSelected ? .white : .secondary)
                }

                Text(shelf.rawValue)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .indigo : Color(.systemGray4))
                    .font(.title3)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.indigo.opacity(0.08) : Color(.systemGray6))
            )
            .padding(.horizontal)
        }
        .buttonStyle(.plain)
    }

    private var addButton: some View {
        Button {
            withAnimation {
                saveBook()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: alreadySaved || saved ? "checkmark.circle.fill" : "plus.circle.fill")
                Text(alreadySaved || saved ? "Added to Library" : "Add to Library")
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(alreadySaved || saved ? Color(.systemGray4) : Color.indigo)
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .animation(.easeInOut(duration: 0.2), value: saved)
        }
        .disabled(alreadySaved || saved)
    }

    // MARK: - Logic

    private func saveBook() {
        // Open Library covers are still addressed by numeric ID (gives us resizable variants
        // via CoverImageCache); every other provider hands back a direct image URL instead.
        let openLibraryCoverID: Int? = {
            guard result.provider == .openLibrary, let url = result.coverImageURL else { return nil }
            let filename = url.lastPathComponent // "12345-M.jpg"
            let idPart = filename.split(separator: "-").first.map(String.init)
            return idPart.flatMap(Int.init)
        }()

        let book = Book(
            title: result.title,
            author: result.author,
            coverID: openLibraryCoverID,
            coverURLString: openLibraryCoverID == nil ? result.coverImageURL?.absoluteString : nil,
            olid: result.olid,
            shelf: selectedShelf
        )
        modelContext.insert(book)
        try? modelContext.save()
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
        }
    }
}
