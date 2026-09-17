import SwiftUI
import SwiftData

/// Manages downloading and locally persisting book cover images.
/// Covers are stored as `Data` on the `Book` SwiftData model so they
/// load instantly on subsequent app launches — no network needed.
@MainActor
final class CoverImageCache {
    static let shared = CoverImageCache()
    private init() {}

    /// Returns a SwiftUI Image for the given book, using the locally cached
    /// data if available. Downloads and persists the image the first time.
    func image(for book: Book, size: CoverImageView.CoverSize) async -> Image? {
        // Already cached
        if let data = book.coverImageData, let uiImage = UIImage(data: data) {
            return Image(uiImage: uiImage)
        }

        // Download — prefer a direct cover URL (non-Open-Library providers), falling back to
        // the legacy Open Library numeric-ID path.
        let data: Data?
        if let urlString = book.coverURLString, let url = URL(string: urlString) {
            data = await OpenLibraryService.shared.downloadCoverData(from: url)
        } else if let coverID = book.coverID {
            data = await OpenLibraryService.shared.downloadCoverData(coverID: coverID, sizeSuffix: size.urlSuffix)
        } else {
            data = nil
        }
        guard let data else { return nil }

        // Persist to model
        book.coverImageData = data

        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
    }
}

/// A view that displays a book cover, using local cache when available.
/// Falls back to the placeholder if no cover ID exists or download fails.
struct CachedCoverImageView: View {
    let book: Book
    let size: CoverImageView.CoverSize

    @State private var cachedImage: Image?
    @State private var isLoading = false

    var body: some View {
        Group {
            if let img = cachedImage {
                img
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if isLoading {
                CoverImageView.placeholderView(size: size)
                    .overlay(ProgressView().tint(.white).scaleEffect(0.7))
            } else {
                CoverImageView.placeholderView(size: size)
            }
        }
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .clipShape(RoundedRectangle(cornerRadius: size.cornerRadius))
        .task(id: book.id) {
            guard cachedImage == nil else { return }
            isLoading = true
            cachedImage = await CoverImageCache.shared.image(for: book, size: size)
            isLoading = false
        }
    }
}
