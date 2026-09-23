import SwiftUI
import SwiftData

struct AddWordView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var wordText = ""
    @State private var definition = ""
    @State private var partOfSpeech = ""
    @State private var isLookingUp = false
    @State private var lookupError: String?
    @State private var lookupTask: Task<Void, Never>?
    /// The word most recently filled in from a lookup, so normalising `wordText` to it
    /// doesn't kick off a second lookup for the same word.
    @State private var lastLookedUpWord: String?

    private enum FocusField: Hashable { case word, definition }
    @FocusState private var focus: FocusField?

    private var canSave: Bool {
        !wordText.trimmingCharacters(in: .whitespaces).isEmpty &&
        !definition.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    wordSection
                    definitionSection
                    saveButton
                }
                .padding()
            }
            .navigationTitle("Add Word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear { focus = .word }
        }
    }

    // MARK: - Word Section

    private var wordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Word", systemImage: "a.magnify")
                .font(.headline)

            HStack(spacing: 10) {
                TextField("Enter a word…", text: $wordText)
                    .focused($focus, equals: .word)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.done)
                    .onSubmit { focus = nil }
                    .onChange(of: wordText) { _, newValue in
                        triggerLookup(word: newValue)
                    }

                if isLookingUp {
                    ProgressView()
                        .scaleEffect(0.85)
                        .transition(.opacity)
                }
            }
            .padding(14)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .animation(.easeInOut(duration: 0.2), value: isLookingUp)
        }
    }

    // MARK: - Definition Section

    private var definitionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Definition", systemImage: "doc.text")
                    .font(.headline)
                Spacer()
                if !partOfSpeech.isEmpty {
                    Text(partOfSpeech)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.indigo.opacity(0.12))
                        .foregroundColor(.indigo)
                        .clipShape(Capsule())
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $definition)
                    .focused($focus, equals: .definition)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)

                if definition.isEmpty {
                    Text(isLookingUp
                         ? "Fetching definition…"
                         : "Definition will appear here automatically,\nor type your own…")
                        .foregroundColor(.secondary)
                        .allowsHitTesting(false)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            if let error = lookupError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(error)
                }
                .font(.caption)
                .foregroundColor(.orange)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lookupError)
    }

    // MARK: - Save Button

    private var saveButton: some View {
        Button {
            saveWord()
        } label: {
            Text("Save Word")
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

    private func triggerLookup(word: String) {
        let trimmed = word.trimmingCharacters(in: .whitespaces)
        if trimmed == lastLookedUpWord { return }
        lastLookedUpWord = nil
        lookupTask?.cancel()
        lookupError = nil
        isLookingUp = false
        guard !trimmed.isEmpty else {
            definition = ""
            partOfSpeech = ""
            return
        }
        lookupTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000) // 700 ms debounce
            guard !Task.isCancelled else { return }
            await fetchDefinition(for: trimmed)
        }
    }

    @MainActor
    private func fetchDefinition(for word: String) async {
        isLookingUp = true
        do {
            let result = try await DictionaryService.shared.fetchDefinition(for: word)
            guard !Task.isCancelled else { return }
            lastLookedUpWord = result.word
            wordText = result.word          // normalise casing
            partOfSpeech = result.partOfSpeech
            definition = result.definition
        } catch {
            // A cancelled lookup was superseded by a newer one, which owns `isLookingUp`.
            guard !Task.isCancelled, !(error is CancellationError) else { return }
            lookupError = error.localizedDescription
        }
        isLookingUp = false
    }

    private func saveWord() {
        let vocab = VocabWord(
            word: wordText.trimmingCharacters(in: .whitespaces),
            definition: definition.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        modelContext.insert(vocab)
        try? modelContext.save()
        dismiss()
    }
}
