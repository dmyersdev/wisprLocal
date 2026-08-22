import SwiftUI

struct DictionaryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var editorContext: DictionaryEditorContext?
    @State private var entryPendingDeletion: DictionaryEntry?

    private var visibleEntries: [DictionaryEntry] {
        let filteredEntries: [DictionaryEntry]
        if searchText.isEmpty {
            filteredEntries = appState.dictionaryEntries
        } else {
            filteredEntries = appState.dictionaryEntries.filter {
                $0.word.localizedCaseInsensitiveContains(searchText)
                    || ($0.misspelling?.localizedCaseInsensitiveContains(searchText) ?? false)
            }
        }
        return appState.dictionarySortOrder.sorted(filteredEntries)
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.96, green: 0.94, blue: 1.0).opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header
                if let recoveryMessage = appState.dictionaryRecoveryMessage {
                    Label(recoveryMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("dictionary.recovery-warning")
                }
                dictionaryContent
            }
            .padding(28)
            .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Dictionary")
        .searchable(text: $searchText, prompt: "Search words and corrections")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("Sort dictionary", selection: $appState.dictionarySortOrder) {
                    ForEach(DictionarySortOrder.allCases) { sortOrder in
                        Text(sortOrder.title).tag(sortOrder)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 146)
                .accessibilityIdentifier("dictionary.sort")

                Button {
                    editorContext = .new
                } label: {
                    Label("Add new", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("dictionary.add")
            }
        }
        .sheet(item: $editorContext) { context in
            DictionaryEditorView(entry: context.entry)
                .environmentObject(appState)
        }
        .alert(
            "Delete dictionary entry?",
            isPresented: deletionAlertIsPresented,
            presenting: entryPendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                appState.deleteDictionaryEntry(id: entry.id)
                entryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: { entry in
            Text("“\(entry.word)” will stop guiding dictation immediately. This can’t be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Dictionary")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Teach WisprLocal names, acronyms, and the exact spellings you use.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            Text(appState.dictionaryEntries.count.formatted())
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.10), in: Capsule())
                .help("Saved dictionary entries")
        }
    }

    @ViewBuilder
    private var dictionaryContent: some View {
        if visibleEntries.isEmpty {
            EmptyStateView(
                systemImage: searchText.isEmpty ? "character.book.closed" : "magnifyingglass",
                title: searchText.isEmpty ? "Teach WisprLocal your words" : "No dictionary entries found",
                message: searchText.isEmpty
                    ? "Add a colleague’s name, product term, acronym, or recurring correction."
                    : "Try a different word or correction."
            )
            .overlay(alignment: .bottom) {
                if searchText.isEmpty {
                    Button("Add dictionary entry") {
                        editorContext = .new
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 24)
                }
            }
        } else {
            List {
                ForEach(visibleEntries) { entry in
                    DictionaryRow(
                        entry: entry,
                        onToggleStar: { appState.toggleDictionaryEntryStarred(id: entry.id) },
                        onEdit: { editorContext = .edit(entry) },
                        onDelete: { entryPendingDeletion = entry }
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    entryPendingDeletion = nil
                }
            }
        )
    }
}

private struct DictionaryEditorContext: Identifiable {
    let id: UUID
    let entry: DictionaryEntry?

    static var new: Self {
        Self(id: UUID(), entry: nil)
    }

    static func edit(_ entry: DictionaryEntry) -> Self {
        Self(id: entry.id, entry: entry)
    }
}

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onToggleStar: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onToggleStar) {
                Image(systemName: entry.isStarred ? "star.fill" : "star")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(entry.isStarred ? Color.orange : Color.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(entry.isStarred ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .help(entry.isStarred ? "Unstar word" : "Star word")
            .accessibilityLabel(entry.isStarred ? "Unstar \(entry.word)" : "Star \(entry.word)")

            VStack(alignment: .leading, spacing: 6) {
                Text(entry.word)
                    .font(.headline)
                    .lineLimit(1)

                if let misspelling = entry.normalizedMisspelling {
                    Label {
                        Text("Corrects “\(misspelling)”")
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Vocabulary word or phrase")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Text("Edited \(entry.editedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit dictionary entry")
            .accessibilityLabel("Edit \(entry.word)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete dictionary entry")
            .accessibilityLabel("Delete \(entry.word)")
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.90), in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(nsColor: .separatorColor).opacity(0.30))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button(entry.isStarred ? "Unstar" : "Star", action: onToggleStar)
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct DictionaryEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?

    let entry: DictionaryEntry?

    @State private var word: String
    @State private var correctMisspelling: Bool
    @State private var misspelling: String
    @State private var isStarred: Bool
    @State private var validationMessage: String?

    private enum Field {
        case word
        case misspelling
    }

    init(entry: DictionaryEntry?) {
        self.entry = entry
        _word = State(initialValue: entry?.word ?? "")
        _correctMisspelling = State(initialValue: entry?.misspelling != nil)
        _misspelling = State(initialValue: entry?.misspelling ?? "")
        _isStarred = State(initialValue: entry?.isStarred ?? false)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry == nil ? "Add to dictionary" : "Edit dictionary entry")
                        .font(.title2.weight(.semibold))
                    Text("Use the exact spelling and capitalization you want in your writing.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                Section("Vocabulary") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            "Word or short phrase",
                            text: $word,
                            prompt: Text("For example: McKenzie or API")
                        )
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .word)
                        .accessibilityIdentifier("dictionary.editor.word")
                        DictionaryCharacterCountLabel(
                            current: DictionaryEntry.normalizedTerm(word).count,
                            limit: DictionaryEntry.termCharacterLimit
                        )
                    }

                    Toggle("Star this word", isOn: $isStarred)
                        .help("Starred words receive priority in transcription guidance.")
                        .accessibilityIdentifier("dictionary.editor.starred")
                }

                Section("Correction") {
                    Toggle("Correct a misspelling", isOn: $correctMisspelling)
                        .accessibilityIdentifier("dictionary.editor.correct-misspelling")

                    if correctMisspelling {
                        VStack(alignment: .leading, spacing: 6) {
                            TextField(
                                "Incorrect spelling",
                                text: $misspelling,
                                prompt: Text("What transcription currently produces")
                            )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .misspelling)
                            .accessibilityHint("This spelling will be replaced with the vocabulary entry above")
                            .accessibilityIdentifier("dictionary.editor.misspelling")
                            DictionaryCharacterCountLabel(
                                current: DictionaryEntry.normalizedTerm(misspelling).count,
                                limit: DictionaryEntry.termCharacterLimit
                            )
                        }
                    }
                }

                if let message = inlineValidationMessage ?? validationMessage {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Text("Changes apply to your next dictation.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(entry == nil ? "Add word" : "Save changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
                .accessibilityIdentifier("dictionary.editor.save")
            }
            .padding(16)
        }
        .frame(width: 560, height: correctMisspelling ? 500 : 450)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focusedField = .word
        }
        .onChange(of: word) { _ in
            validationMessage = nil
        }
        .onChange(of: misspelling) { _ in
            validationMessage = nil
        }
        .onChange(of: correctMisspelling) { isEnabled in
            validationMessage = nil
            if isEnabled {
                focusedField = .misspelling
            }
        }
    }

    private var canSave: Bool {
        let normalizedWord = DictionaryEntry.normalizedTerm(word)
        let normalizedMisspelling = DictionaryEntry.normalizedTerm(misspelling)
        return !normalizedWord.isEmpty
            && normalizedWord.count <= DictionaryEntry.termCharacterLimit
            && (!correctMisspelling || !normalizedMisspelling.isEmpty)
            && normalizedMisspelling.count <= DictionaryEntry.termCharacterLimit
    }

    private var inlineValidationMessage: String? {
        let normalizedWord = DictionaryEntry.normalizedTerm(word)
        let normalizedMisspelling = DictionaryEntry.normalizedTerm(misspelling)
        if normalizedWord.count > DictionaryEntry.termCharacterLimit {
            return DictionaryValidationError.wordTooLong.localizedDescription
        }
        if correctMisspelling, normalizedMisspelling.count > DictionaryEntry.termCharacterLimit {
            return DictionaryValidationError.misspellingTooLong.localizedDescription
        }
        return nil
    }

    private func save() {
        do {
            try appState.saveDictionaryEntry(
                id: entry?.id,
                word: word,
                misspelling: correctMisspelling ? misspelling : nil,
                isStarred: isStarred
            )
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

private struct DictionaryCharacterCountLabel: View {
    let current: Int
    let limit: Int

    var body: some View {
        Text("\(current.formatted()) / \(limit.formatted())")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(current > limit ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
