import SwiftUI

struct SnippetsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var editorContext: SnippetEditorContext?
    @State private var snippetPendingDeletion: Snippet?

    private var filteredSnippets: [Snippet] {
        guard !searchText.isEmpty else { return appState.snippets }
        return appState.snippets.filter {
            $0.trigger.localizedCaseInsensitiveContains(searchText)
                || $0.expansion.localizedCaseInsensitiveContains(searchText)
        }
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
                if let recoveryMessage = appState.snippetRecoveryMessage {
                    Label(recoveryMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("snippets.recovery-warning")
                }
                snippetContent
            }
            .padding(28)
            .frame(maxWidth: 860, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle("Snippets")
        .searchable(text: $searchText, prompt: "Search snippets")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorContext = .new
                } label: {
                    Label("Add new", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
                .accessibilityIdentifier("snippets.add")
            }
        }
        .sheet(item: $editorContext) { context in
            SnippetEditorView(snippet: context.snippet)
                .environmentObject(appState)
        }
        .alert(
            "Delete snippet?",
            isPresented: deletionAlertIsPresented,
            presenting: snippetPendingDeletion
        ) { snippet in
            Button("Delete", role: .destructive) {
                appState.deleteSnippet(id: snippet.id)
                snippetPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                snippetPendingDeletion = nil
            }
        } message: { snippet in
            Text("“\(snippet.trigger)” will stop expanding immediately. This can’t be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Snippets")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Say a short trigger and WisprLocal inserts the full text exactly as you saved it.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading)
            }
            Spacer()
            Text(appState.snippets.count.formatted())
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.10), in: Capsule())
                .help("Saved snippets")
        }
    }

    @ViewBuilder
    private var snippetContent: some View {
        if filteredSnippets.isEmpty {
            EmptyStateView(
                systemImage: searchText.isEmpty ? "text.badge.plus" : "magnifyingglass",
                title: searchText.isEmpty ? "Create your first snippet" : "No snippets found",
                message: searchText.isEmpty
                    ? "Try “my meeting link” or “my email signature” as a trigger."
                    : "Try a different trigger or expansion."
            )
            .overlay(alignment: .bottom) {
                if searchText.isEmpty {
                    Button("Add new snippet") {
                        editorContext = .new
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.bottom, 24)
                }
            }
        } else {
            List {
                ForEach(filteredSnippets) { snippet in
                    SnippetRow(
                        snippet: snippet,
                        onEdit: { editorContext = .edit(snippet) },
                        onDelete: { snippetPendingDeletion = snippet }
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
            get: { snippetPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    snippetPendingDeletion = nil
                }
            }
        )
    }
}

private struct SnippetEditorContext: Identifiable {
    let id: UUID
    let snippet: Snippet?

    static var new: Self {
        Self(id: UUID(), snippet: nil)
    }

    static func edit(_ snippet: Snippet) -> Self {
        Self(id: snippet.id, snippet: snippet)
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "quote.opening")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
                .frame(width: 34, height: 34)
                .background(Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 6) {
                Text(snippet.trigger)
                    .font(.headline)
                    .lineLimit(1)
                Text(snippet.expansion)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                Text("Edited \(snippet.editedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 12)

            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit snippet")
            .accessibilityLabel("Edit \(snippet.trigger)")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete snippet")
            .accessibilityLabel("Delete \(snippet.trigger)")
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
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct SnippetEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @FocusState private var focusedField: Field?

    let snippet: Snippet?

    @State private var trigger: String
    @State private var expansion: String
    @State private var validationMessage: String?

    private enum Field {
        case trigger
        case expansion
    }

    init(snippet: Snippet?) {
        self.snippet = snippet
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snippet == nil ? "Add snippet" : "Edit snippet")
                        .font(.title2.weight(.semibold))
                    Text("The trigger is what you’ll say while dictating.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                Section("Snippet") {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField(
                            "Spoken trigger",
                            text: $trigger,
                            prompt: Text("For example: my meeting link")
                        )
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .trigger)
                            .accessibilityIdentifier("snippet.editor.trigger")
                        CharacterCountLabel(
                            current: Snippet.normalizedTrigger(trigger).count,
                            limit: Snippet.triggerCharacterLimit
                        )
                    }
                }

                Section("Expansion") {
                    VStack(alignment: .leading, spacing: 6) {
                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $expansion)
                                .font(.body)
                                .focused($focusedField, equals: .expansion)
                                .frame(minHeight: 150)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.45))
                                )
                                .accessibilityLabel("Expansion text")
                                .accessibilityHint("The exact text inserted when you say the trigger")
                                .accessibilityIdentifier("snippet.editor.expansion")
                            if expansion.isEmpty {
                                Text("Enter the text to insert")
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        CharacterCountLabel(current: expansion.count, limit: Snippet.expansionCharacterLimit)
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
                Text("Tip: choose a phrase you won’t say by accident.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(snippet == nil ? "Add snippet" : "Save changes") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!canSave)
                .accessibilityIdentifier("snippet.editor.save")
            }
            .padding(16)
        }
        .frame(width: 560, height: 510)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            focusedField = .trigger
        }
        .onChange(of: trigger) { _ in
            validationMessage = nil
        }
        .onChange(of: expansion) { _ in
            validationMessage = nil
        }
    }

    private var canSave: Bool {
        let normalizedTrigger = Snippet.normalizedTrigger(trigger)
        return !normalizedTrigger.isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && normalizedTrigger.count <= Snippet.triggerCharacterLimit
            && expansion.count <= Snippet.expansionCharacterLimit
    }

    private var inlineValidationMessage: String? {
        let normalizedTrigger = Snippet.normalizedTrigger(trigger)
        if normalizedTrigger.count > Snippet.triggerCharacterLimit {
            return SnippetValidationError.triggerTooLong.localizedDescription
        }
        if expansion.count > Snippet.expansionCharacterLimit {
            return SnippetValidationError.expansionTooLong.localizedDescription
        }
        return nil
    }

    private func save() {
        do {
            try appState.saveSnippet(id: snippet?.id, trigger: trigger, expansion: expansion)
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

private struct CharacterCountLabel: View {
    let current: Int
    let limit: Int

    var body: some View {
        Text("\(current.formatted()) / \(limit.formatted())")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(current > limit ? Color.red : Color.secondary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
