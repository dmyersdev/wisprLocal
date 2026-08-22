import AppKit
import SwiftUI

private struct ScratchpadDeleteCandidate: Identifiable {
    let id: UUID
    let title: String
}

private struct ScratchpadLinkRequest: Identifiable {
    let id = UUID()
}

struct ScratchpadHubView: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject private var store: ScratchpadStore

    @State private var searchText = ""
    @State private var hoveredNoteID: UUID?
    @State private var deleteCandidate: ScratchpadDeleteCandidate?

    init(controller: ScratchpadController) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.store)
    }

    private var filteredNotes: [ScratchpadNote] {
        store.filteredNotes(query: searchText)
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

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    banner
                    libraryHeader
                    noteLibrary
                }
                .padding(28)
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
        .navigationTitle("Scratchpad")
        .searchable(text: $searchText, prompt: "Search Scratchpad")
        .alert(item: $deleteCandidate) { candidate in
            Alert(
                title: Text("Delete “\(candidate.title)”?"),
                message: Text("This note and its version history will be permanently deleted."),
                primaryButton: .destructive(Text("Delete")) {
                    do {
                        try store.deleteNote(id: candidate.id)
                    } catch {
                        store.message = error.localizedDescription
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var banner: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("For quick thoughts you want to come back to")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Drop a to-do list, polish a message before you send it, brain dump an idea. Scratchpad is your safe space to save, create, and explore.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Start new note") {
                    controller.createAndOpenNote()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("scratchpad.hub.startNewNote")
            }
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 86, height: 86)
                Image(systemName: "note.text")
                    .font(.system(size: 37, weight: .medium))
                    .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
            }
        }
        .padding(24)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.84, green: 0.78, blue: 1.0),
                    Color(red: 0.94, green: 0.90, blue: 1.0)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.55))
        )
        .accessibilityIdentifier("scratchpad.hub.banner")
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Recents")
                    .font(.title3.weight(.semibold))
                Text("Stored on this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh Scratchpad")
            .accessibilityLabel("Refresh Scratchpad")
            Button {
                controller.createAndOpenNote()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderedProminent)
            .help("New note")
            .accessibilityLabel("New note")
        }
    }

    @ViewBuilder
    private var noteLibrary: some View {
        if filteredNotes.isEmpty {
            EmptyStateView(
                systemImage: searchText.isEmpty ? "note.text" : "magnifyingglass",
                title: searchText.isEmpty ? "Your Scratchpad is empty" : "No notes found",
                message: searchText.isEmpty
                    ? "Start a note here or press ⌥S from anywhere."
                    : "Try a different title or phrase."
            )
        } else {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                ForEach(filteredNotes) { note in
                    noteCard(note)
                }
            }
        }
    }

    private func noteCard(_ note: ScratchpadNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if note.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption)
                        .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
                }
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if hoveredNoteID == note.id {
                    cardActions(note)
                }
            }
            Text(note.preview.isEmpty ? "Empty note" : note.preview)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
            HStack {
                Text(note.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                Spacer()
                if note.imageCount > 0 {
                    Label(note.imageCount.formatted(), systemImage: "photo")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 150, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    hoveredNoteID == note.id
                        ? Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.45)
                        : Color(nsColor: .separatorColor).opacity(0.30)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { controller.openNote(id: note.id) }
        .onHover { hovering in
            hoveredNoteID = hovering ? note.id : nil
        }
        .accessibilityIdentifier("scratchpad.hub.note.\(note.id.uuidString)")
    }

    private func cardActions(_ note: ScratchpadNote) -> some View {
        HStack(spacing: 4) {
            actionButton(
                systemImage: note.isPinned ? "pin.slash" : "pin",
                help: note.isPinned ? "Unpin note" : "Pin note"
            ) {
                store.togglePin(id: note.id)
            }
            actionButton(systemImage: "pencil", help: "Edit note") {
                controller.openNote(id: note.id)
            }
            actionButton(systemImage: "trash", help: "Delete note", role: .destructive) {
                deleteCandidate = .init(id: note.id, title: note.title)
            }
        }
    }

    private func actionButton(
        systemImage: String,
        help: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct ScratchpadView: View {
    @ObservedObject var controller: ScratchpadController
    @ObservedObject private var store: ScratchpadStore
    @ObservedObject private var editorBridge: ScratchpadEditorBridge

    @State private var searchText = ""
    @State private var customPrompt = ""
    @State private var suggestionOffset = 0
    @State private var deleteCandidate: ScratchpadDeleteCandidate?
    @State private var linkRequest: ScratchpadLinkRequest?

    init(controller: ScratchpadController) {
        self.controller = controller
        _store = ObservedObject(wrappedValue: controller.store)
        _editorBridge = ObservedObject(wrappedValue: controller.editorBridge)
    }

    private var filteredNotes: [ScratchpadNote] {
        store.filteredNotes(query: searchText)
    }

    private var transformSuggestions: [TransformDefinition] {
        let definitions = controller.availableTransforms
        guard !definitions.isEmpty else { return [] }
        return (0..<min(3, definitions.count)).map { index in
            definitions[(suggestionOffset + index) % definitions.count]
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            HStack(spacing: 0) {
                if store.isSidebarVisible {
                    noteSidebar
                    Divider()
                }
                editorArea
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert(item: $deleteCandidate) { candidate in
            Alert(
                title: Text("Delete “\(candidate.title)”?"),
                message: Text("This note and its version history will be permanently deleted."),
                primaryButton: .destructive(Text("Delete")) {
                    do {
                        try store.deleteNote(id: candidate.id)
                    } catch {
                        store.message = error.localizedDescription
                    }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: $linkRequest) { _ in
            ScratchpadLinkSheet { url in
                editorBridge.addLink(url)
            }
        }
        .onDisappear {
            store.flushAutosave()
        }
    }

    private var tabBar: some View {
        HStack(spacing: 6) {
            Button {
                store.isSidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(store.isSidebarVisible ? "Hide notes" : "Show notes")
            .accessibilityLabel(store.isSidebarVisible ? "Hide notes" : "Show notes")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(store.openTabs, id: \.self) { noteID in
                        if let note = store.notes.first(where: { $0.id == noteID }) {
                            tab(note)
                        }
                    }
                }
            }

            Spacer(minLength: 4)
            Button {
                controller.createAndOpenNote()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .disabled(store.openTabs.count >= ScratchpadStore.maximumOpenTabs)
            .help("New note")
            .accessibilityLabel("New note")
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.82))
    }

    private func tab(_ note: ScratchpadNote) -> some View {
        HStack(spacing: 6) {
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
            }
            Text(note.title)
                .font(.caption)
                .lineLimit(1)
                .frame(maxWidth: 112)
            Button {
                store.closeTab(id: note.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Close \(note.title)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .foregroundStyle(store.selectedNoteID == note.id ? .primary : .secondary)
        .background(
            store.selectedNoteID == note.id
                ? Color(nsColor: .windowBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .contentShape(Rectangle())
        .onTapGesture { store.selectTab(id: note.id) }
        .accessibilityIdentifier("scratchpad.tab.\(note.id.uuidString)")
    }

    private var noteSidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search notes", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(10)

            List(filteredNotes, selection: Binding(
                get: { store.selectedNoteID },
                set: { id in if let id { controller.openNote(id: id) } }
            )) { note in
                noteSidebarRow(note)
                    .tag(note.id)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .frame(minWidth: 205, idealWidth: 230, maxWidth: 260)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func noteSidebarRow(_ note: ScratchpadNote) -> some View {
        HStack(spacing: 8) {
            if note.isPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(note.preview.isEmpty ? "Empty note" : note.preview)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 2)
            Button {
                store.togglePin(id: note.id)
            } label: {
                Image(systemName: note.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.borderless)
            .help(note.isPinned ? "Unpin note" : "Pin note")
            Button {
                deleteCandidate = .init(id: note.id, title: note.title)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete note")
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var editorArea: some View {
        if let note = store.selectedNote {
            VStack(spacing: 0) {
                editorHeader(note)
                Divider()
                formattingBar
                Divider()
                ScratchpadRichTextEditor(
                    content: Binding(
                        get: { store.activeContent },
                        set: { store.updateActiveContent($0) }
                    ),
                    bridge: editorBridge,
                    onChange: { _ in },
                    onError: { store.message = $0 }
                )
                .accessibilityIdentifier("scratchpad.editor")
                if let message = store.message {
                    statusBanner(message)
                }
                Divider()
                transformBar
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "note.text")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
                Text("Open a note or start a new one")
                    .font(.headline)
                Button("Start new note") {
                    controller.createAndOpenNote()
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func editorHeader(_ note: ScratchpadNote) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(note.title)
                    .font(.headline)
                    .lineLimit(1)
                Text("Saved \(note.modifiedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                if store.selectedVersions.isEmpty {
                    Text("No versions yet")
                } else {
                    ForEach(store.selectedVersions) { version in
                        Button {
                            do {
                                try store.restore(versionID: version.id)
                            } catch {
                                store.message = error.localizedDescription
                            }
                        } label: {
                            Text("\(version.source.title) · \(version.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            } label: {
                Label("Version history", systemImage: "clock.arrow.circlepath")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                do { try editorBridge.copyAll() }
                catch { store.message = error.localizedDescription }
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .help("Copy note")
            .accessibilityLabel("Copy note")

            Button {
                store.togglePin(id: note.id)
            } label: {
                Image(systemName: note.isPinned ? "pin.fill" : "pin")
            }
            .help(note.isPinned ? "Unpin note" : "Pin note")
            .accessibilityLabel(note.isPinned ? "Unpin note" : "Pin note")

            Button {
                deleteCandidate = .init(id: note.id, title: note.title)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete note")
            .accessibilityLabel("Delete note")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var formattingBar: some View {
        HStack(spacing: 4) {
            formatButton("arrow.uturn.backward", "Undo", disabled: !editorBridge.canUndo) {
                editorBridge.undo()
            }
            formatButton("arrow.uturn.forward", "Redo", disabled: !editorBridge.canRedo) {
                editorBridge.redo()
            }
            Divider().frame(height: 18).padding(.horizontal, 4)
            formatButton("bold", "Bold") { editorBridge.toggleBold() }
            formatButton("italic", "Italic") { editorBridge.toggleItalic() }
            formatButton("underline", "Underline") { editorBridge.toggleUnderline() }
            formatButton("list.bullet", "Bulleted list") { editorBridge.toggleBulletList() }
            formatButton("link", "Add link", disabled: !editorBridge.hasSelection) {
                linkRequest = ScratchpadLinkRequest()
            }
            Spacer()
            Button {
                switch controller.state {
                case .listening(_), .starting(_):
                    controller.stopAndTranscribe()
                default:
                    controller.startRecording(mode: .handsFree)
                }
            } label: {
                Label(recordButtonTitle, systemImage: recordButtonImage)
            }
            .buttonStyle(.borderedProminent)
            .tint(recordButtonTint)
            .disabled(recordButtonIsDisabled)
            .accessibilityIdentifier("scratchpad.record")
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.42))
    }

    private var transformBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(transformSuggestions) { definition in
                    Button(definition.name) {
                        controller.applyTransform(definition: definition)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(controller.isActive)
                }
                if !transformSuggestions.isEmpty {
                    Button {
                        suggestionOffset += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh suggestions")
                    .accessibilityLabel("Refresh transform suggestions")
                }
                Spacer()
            }

            HStack(spacing: 8) {
                TextField("Follow up or ask a question", text: $customPrompt)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submitCustomTransform() }
                Button {
                    submitCustomTransform()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || controller.isActive
                )
                .accessibilityLabel("Apply custom transform")
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.60))
    }

    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: controllerStateIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(message)
                .lineLimit(2)
            Spacer()
            Button {
                store.message = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Dismiss status")
        }
        .font(.caption)
        .foregroundStyle(controllerStateIsError ? .orange : .secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.85))
    }

    private func formatButton(
        _ systemImage: String,
        _ help: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }

    private var recordButtonTitle: String {
        switch controller.state {
        case .starting, .listening: return "Stop"
        case .processing: return "Processing"
        default: return "Dictate"
        }
    }

    private var recordButtonImage: String {
        switch controller.state {
        case .starting, .listening: return "stop.fill"
        case .processing: return "ellipsis"
        default: return "mic.fill"
        }
    }

    private var recordButtonTint: Color {
        switch controller.state {
        case .starting, .listening: return .red
        default: return Color(red: 0.48, green: 0.29, blue: 0.96)
        }
    }

    private var recordButtonIsDisabled: Bool {
        switch controller.state {
        case .processing, .transforming:
            return true
        default:
            return false
        }
    }

    private var controllerStateIsError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private func submitCustomTransform() {
        let prompt = customPrompt
        controller.applyCustomTransform(prompt: prompt)
        customPrompt = ""
    }
}

private struct ScratchpadLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = "https://"
    let onApply: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add link")
                .font(.headline)
            TextField("https://example.com", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { apply() }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(URL(string: urlText)?.scheme == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func apply() {
        guard let url = URL(string: urlText), url.scheme != nil else { return }
        onApply(url)
        dismiss()
    }
}

struct ScratchpadSettingsCard: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var store: ScratchpadStore

    var body: some View {
        SettingsCard(
            title: "Scratchpad",
            subtitle: "A floating rich-text notepad that stays available from any app."
        ) {
            ShortcutDescriptionRow(title: "Open Scratchpad", shortcut: "⌥S")
            Text("Tap to show or hide, hold to dictate into the active note, or double-tap while visible for hands-free dictation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let warning = appState.scratchpadHotkeyWarning {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Divider()
            Picker("When opening Scratchpad", selection: $store.openBehavior) {
                ForEach(ScratchpadOpenBehavior.allCases) { behavior in
                    Text(behavior.title).tag(behavior)
                }
            }
            if let recoveryMessage = store.recoveryMessage {
                Text(recoveryMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }
}
