import SwiftUI
import SwiftData
import PhotosUI

/// Adding a quote is a four-step flow:
/// 1. pick a book from the Reading shelf,
/// 2. photograph the page (camera opens automatically; the photo library is a fallback),
/// 3. paint over the sentence with a highlighter,
/// 4. review the text Gemini extracted from the highlight, edit if needed, and save.
struct AddQuoteView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Book.title) private var allBooks: [Book]

    private var readingBooks: [Book] {
        allBooks.filter { $0.shelf == .reading }
    }

    private enum Step: Equatable { case selectBook, capture, highlight, review }

    @State private var step: Step = .selectBook
    @State private var selectedBook: Book?
    @State private var isShowingEmptyAlert = false

    // Capture
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: UIImage?

    // Highlight
    @State private var strokes: [HighlightStroke] = []
    @State private var canvasMode: HighlightCanvasView.Mode = .highlight
    @State private var brushSize: CGFloat = 24
    @State private var isExtracting = false

    // Review
    @State private var quoteText = ""
    @State private var pageNumberText = ""
    @State private var errorMessage: String?

    private enum FocusField: Hashable { case quoteField }
    @FocusState private var focus: FocusField?

    /// Longest edge kept in memory for the captured photo — full camera resolution is far more
    /// than needed to read print, and 12 MP images make drawing and rendering sluggish.
    private static let workingImageDimension: CGFloat = 2400

    private var canSave: Bool {
        selectedBook != nil && !quoteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Group {
                if readingBooks.isEmpty {
                    // Fallback empty view behind the alert
                    Color(.systemGroupedBackground).ignoresSafeArea()
                } else {
                    switch step {
                    case .selectBook: bookSelectionList
                    case .capture:    captureView
                    case .highlight:  highlightView
                    case .review:     reviewForm
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                if step != .selectBook {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Change Book") {
                            withAnimation { resetToBookSelection() }
                        }
                        .font(.subheadline)
                    }
                }
            }
            .onAppear {
                if readingBooks.isEmpty {
                    isShowingEmptyAlert = true
                }
            }
            .alert("Reading List Empty", isPresented: $isShowingEmptyAlert) {
                Button("OK") { dismiss() }
            } message: {
                Text("You need to add books to your Reading shelf before you can save quotes.")
            }
            .alert("Couldn't Extract Quote", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(errorMessage ?? "")
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraPicker { image in
                    showCamera = false
                    if let image { usePhoto(image) }
                }
                .ignoresSafeArea()
            }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        usePhoto(image)
                    } else {
                        errorMessage = "That photo couldn't be opened. Please try another."
                    }
                    photoItem = nil
                }
            }
        }
    }

    private var navigationTitle: String {
        switch step {
        case .selectBook: return "Select Book"
        case .capture:    return "Photograph Page"
        case .highlight:  return "Highlight Quote"
        case .review:     return "Add Quote"
        }
    }

    // MARK: - Book Selection

    private var bookSelectionList: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(readingBooks) { book in
                    Button {
                        select(book)
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

    // MARK: - Capture

    private var captureView: some View {
        VStack(spacing: 24) {
            if let book = selectedBook { selectedBookHeader(book) }

            Spacer()

            VStack(spacing: 12) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 56))
                    .foregroundStyle(.indigo)
                Text("Take a photo of the page")
                    .font(.title3.weight(.semibold))
                Text("Then highlight the sentence you want to save, just like marking up a photo.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            Spacer()

            VStack(spacing: 12) {
                if CameraPicker.isAvailable {
                    Button {
                        showCamera = true
                    } label: {
                        Label("Take Photo", systemImage: "camera.fill")
                            .primaryButtonStyle(enabled: true)
                    }
                }

                PhotosPicker(selection: $photoItem, matching: .images) {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                Button("Type it in instead") {
                    withAnimation { step = .review }
                }
                .font(.footnote)
                .padding(.top, 4)
            }
        }
        .padding()
        .background(Color(.systemGroupedBackground))
    }

    // MARK: - Highlight

    private var highlightView: some View {
        VStack(spacing: 0) {
            if let photo {
                HighlightCanvasView(image: photo, strokes: $strokes, mode: canvasMode, brushSize: brushSize)
                    .background(Color.black)
            }

            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    Picker("Tool", selection: $canvasMode) {
                        Image(systemName: "highlighter").tag(HighlightCanvasView.Mode.highlight)
                        Image(systemName: "hand.draw").tag(HighlightCanvasView.Mode.move)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                    .accessibilityLabel("Highlight or move photo")

                    Menu {
                        Picker("Brush Size", selection: $brushSize) {
                            Text("Thin").tag(CGFloat(14))
                            Text("Medium").tag(CGFloat(24))
                            Text("Thick").tag(CGFloat(38))
                        }
                    } label: {
                        Image(systemName: "lineweight")
                            .frame(width: 36, height: 32)
                    }
                    .accessibilityLabel("Brush size")

                    Spacer()

                    Button {
                        _ = strokes.popLast()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .frame(width: 36, height: 32)
                    }
                    .disabled(strokes.isEmpty)
                    .accessibilityLabel("Undo")

                    Button("Clear") { strokes.removeAll() }
                        .disabled(strokes.isEmpty)
                }

                Text(canvasMode == .highlight
                     ? "Drag over the sentence to highlight it."
                     : "Pinch to zoom and drag to move. Double-tap to reset.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 12) {
                    Button {
                        withAnimation { step = .capture }
                    } label: {
                        Text("Retake")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(16)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    Button {
                        extractQuote()
                    } label: {
                        Group {
                            if isExtracting {
                                ProgressView().tint(.white)
                            } else {
                                Text("Extract Quote")
                            }
                        }
                        .primaryButtonStyle(enabled: !strokes.isEmpty)
                    }
                    .disabled(strokes.isEmpty || isExtracting)
                }
            }
            .padding()
            .background(Color(.systemGroupedBackground))
        }
        .disabled(isExtracting)
    }

    // MARK: - Review

    private var reviewForm: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let book = selectedBook { selectedBookHeader(book) }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Quote", systemImage: "quote.opening")
                        .font(.headline)

                    ZStack(alignment: .topLeading) {
                        TextEditor(text: $quoteText)
                            .focused($focus, equals: .quoteField)
                            .frame(minHeight: 140)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .background(Color(.secondarySystemGroupedBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .onChange(of: quoteText) { _, newValue in
                                if newValue.count > Self.maxQuoteLength {
                                    quoteText = String(newValue.prefix(Self.maxQuoteLength))
                                }
                            }

                        if quoteText.isEmpty {
                            Text("Type the quote...")
                                .foregroundColor(.secondary)
                                .allowsHitTesting(false)
                                .padding(.top, 20)
                                .padding(.leading, 16)
                        }
                    }

                    if photo != nil {
                        Text("Check the text matches the page — you can edit it before saving.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Page (optional)", systemImage: "number")
                        .font(.headline)
                    TextField("e.g. 42", text: $pageNumberText)
                        .keyboardType(.numberPad)
                        .padding(12)
                        .background(Color(.secondarySystemGroupedBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .onChange(of: pageNumberText) { _, newValue in
                            let digits = String(newValue.filter(\.isNumber).prefix(5))
                            if digits != newValue { pageNumberText = digits }
                        }
                }

                Button {
                    saveQuote()
                } label: {
                    Text("Save Quote").primaryButtonStyle(enabled: canSave)
                }
                .disabled(!canSave)

                if photo != nil {
                    Button("Highlight Again") {
                        withAnimation { step = .highlight }
                    }
                    .frame(maxWidth: .infinity)
                    .font(.subheadline)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func selectedBookHeader(_ book: Book) -> some View {
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

    // MARK: - Logic

    /// Matches the server-side cap in the extract-quote function and the quotes.text constraint.
    private static let maxQuoteLength = 2000

    private func select(_ book: Book) {
        withAnimation {
            selectedBook = book
            step = .capture
        }
        // Prompt for the photo straight away; the capture screen stays behind as a fallback
        // (photo library, typing) if the camera is dismissed or unavailable.
        if CameraPicker.isAvailable {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showCamera = true }
        }
    }

    private func usePhoto(_ image: UIImage) {
        photo = image.resized(maxDimension: Self.workingImageDimension)
        strokes = []
        canvasMode = .highlight
        withAnimation { step = .highlight }
    }

    private func extractQuote() {
        guard let photo, !strokes.isEmpty else { return }
        isExtracting = true
        let highlighted = HighlightCanvasView.render(image: photo, strokes: strokes)
        Task {
            do {
                let text = try await QuoteExtractionService.extractQuote(from: highlighted)
                quoteText = String(text.prefix(Self.maxQuoteLength))
                withAnimation { step = .review }
            } catch {
                errorMessage = error.localizedDescription
            }
            isExtracting = false
        }
    }

    private func resetToBookSelection() {
        selectedBook = nil
        photo = nil
        strokes = []
        quoteText = ""
        pageNumberText = ""
        step = .selectBook
    }

    private func saveQuote() {
        guard let book = selectedBook else { return }
        let quote = Quote(
            text: quoteText.trimmingCharacters(in: .whitespacesAndNewlines),
            bookTitle: book.title,
            bookID: book.id,
            pageNumber: Int(pageNumberText).flatMap { $0 > 0 ? $0 : nil }
        )
        modelContext.insert(quote)
        try? modelContext.save()
        dismiss()
    }
}

private extension View {
    func primaryButtonStyle(enabled: Bool) -> some View {
        self
            .fontWeight(.semibold)
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(enabled ? Color.indigo : Color(.systemGray4))
            .foregroundColor(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .animation(.easeInOut(duration: 0.2), value: enabled)
    }
}
