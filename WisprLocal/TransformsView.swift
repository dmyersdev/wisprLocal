import Carbon
import SwiftUI

struct TransformsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var transformController: TransformController

    @State private var editorContext: TransformEditorContext?
    @State private var transformPendingDeletion: TransformDefinition?

    private let accent = Color(red: 0.48, green: 0.29, blue: 0.96)

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
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let message = appState.transformRecoveryMessage {
                        warning(message, identifier: "transforms.recovery-warning")
                    }
                    if let message = appState.transformHotkeyWarning {
                        warning(message, identifier: "transforms.hotkey-warning")
                    }
                    setupCard
                    transformGrid
                    latestResultCard
                }
                .padding(28)
                .frame(maxWidth: 920, alignment: .leading)
            }
        }
        .navigationTitle("Transforms")
        .sheet(item: $editorContext) { context in
            TransformEditorView(
                definition: context.definition,
                suggestedHotkey: context.suggestedHotkey
            )
            .environmentObject(appState)
        }
        .sheet(isPresented: $appState.isTransformResultPresented) {
            TransformResultView(transformController: transformController)
                .environmentObject(appState)
        }
        .alert(
            "Delete transform?",
            isPresented: deletionAlertIsPresented,
            presenting: transformPendingDeletion
        ) { definition in
            Button("Delete", role: .destructive) {
                appState.deleteTransform(id: definition.id)
                transformPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                transformPendingDeletion = nil
            }
        } message: { definition in
            Text("“\(definition.name)” and its writing samples will be removed. This can’t be undone.")
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Transforms")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Select text in any app, then use a shortcut to rewrite it in place.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable transforms",
                isOn: Binding(
                    get: { appState.transformSettings.isEnabled },
                    set: appState.setTransformsEnabled
                )
            )
            .toggleStyle(.switch)
            .accessibilityIdentifier("transforms.enabled")
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 38, height: 38)
                    .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.transformSettings.isEnabled ? "Shortcuts are active" : "Turn on transforms when you’re ready")
                        .font(.headline)
                    Text("WisprLocal registers transform shortcuts only while this feature is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Automatically transform dictation")
                        .font(.callout.weight(.medium))
                    Text("Runs after personalization and before text is saved or pasted. The original is used if rewriting fails.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Picker(
                    "Automatic transform",
                    selection: Binding<UUID?>(
                        get: { appState.transformSettings.autoApplyTransformID },
                        set: appState.setAutoApplyTransformID
                    )
                ) {
                    Text("None").tag(UUID?.none)
                    ForEach(appState.transformSettings.definitions) { definition in
                        Text(definition.name).tag(Optional(definition.id))
                    }
                }
                .labelsHidden()
                .frame(width: 190)
                .disabled(!appState.transformSettings.isEnabled)
                .accessibilityLabel("Automatically transform dictation")
                .accessibilityIdentifier("transforms.auto-apply")
            }

            if let message = appState.transformFeedbackMessage {
                Label(message, systemImage: feedbackIcon)
                    .font(.callout)
                    .foregroundStyle(feedbackColor)
                    .accessibilityIdentifier("transforms.feedback")
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32))
        )
    }

    private var transformGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your transforms")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(appState.transformSettings.customDefinitions.count) of \(TransformDefinition.customTransformLimit) custom")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 14),
                    GridItem(.flexible(), spacing: 14)
                ],
                spacing: 14
            ) {
                ForEach(appState.transformSettings.definitions) { definition in
                    TransformCard(
                        definition: definition,
                        onEdit: { editorContext = .edit(definition) },
                        onDelete: definition.kind == .custom
                            ? { transformPendingDeletion = definition }
                            : nil
                    )
                }

                if appState.transformSettings.customDefinitions.count < TransformDefinition.customTransformLimit {
                    Button {
                        editorContext = .new(suggestedHotkey: nextAvailableHotkey)
                    } label: {
                        VStack(spacing: 9) {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 24))
                            Text("Create a transform")
                                .font(.headline)
                            Text("Add your own rewrite rule and style samples")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 122)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(accent)
                    .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(accent.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5]))
                    )
                    .accessibilityIdentifier("transforms.add")
                }
            }
        }
    }

    @ViewBuilder
    private var latestResultCard: some View {
        if let result = appState.lastTransformResult {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Latest: \(result.invocation.name)")
                        .font(.headline)
                    Text(result.transformedText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button("View changes") {
                    transformController.showLatestResult()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func warning(_ message: String, identifier: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .accessibilityIdentifier(identifier)
    }

    private var feedbackIcon: String {
        switch transformController.state {
        case .processing: return "wand.and.stars"
        case .error: return "exclamationmark.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .unchanged: return "checkmark.circle"
        case .idle: return "info.circle"
        }
    }

    private var feedbackColor: Color {
        if case .error = transformController.state { return .red }
        return .secondary
    }

    private var nextAvailableHotkey: Hotkey {
        let used = appState.transformSettings.definitions.compactMap(\.hotkey)
        let keyCodes: [Int] = [
            kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6,
            kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9, kVK_ANSI_0
        ]
        return keyCodes
            .map { Hotkey(kind: .carbon, keyCode: UInt16($0), modifiers: [.option]) }
            .first { !used.contains($0) }
            ?? Hotkey(kind: .carbon, keyCode: UInt16(kVK_ANSI_T), modifiers: [.option, .shift])
    }

    private var deletionAlertIsPresented: Binding<Bool> {
        Binding(
            get: { transformPendingDeletion != nil },
            set: { isPresented in
                if !isPresented { transformPendingDeletion = nil }
            }
        )
    }
}

private struct TransformEditorContext: Identifiable {
    let id: UUID
    let definition: TransformDefinition?
    let suggestedHotkey: Hotkey

    static func new(suggestedHotkey: Hotkey) -> Self {
        Self(id: UUID(), definition: nil, suggestedHotkey: suggestedHotkey)
    }

    static func edit(_ definition: TransformDefinition) -> Self {
        Self(
            id: definition.id,
            definition: definition,
            suggestedHotkey: definition.hotkey ?? .defaultCarbon
        )
    }
}

private struct TransformCard: View {
    let definition: TransformDefinition
    let onEdit: () -> Void
    let onDelete: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.name)
                        .font(.headline)
                    Text(definition.isBuiltIn ? "Built in" : "Custom")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let hotkey = definition.hotkey {
                    Text(hotkey.displayString())
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(nsColor: .quaternaryLabelColor).opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
                }
            }

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                if !definition.writingSamples.isEmpty {
                    Label("\(definition.writingSamples.count) samples", systemImage: "doc.text")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onDelete {
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Delete \(definition.name)")
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
            }
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 152, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.90), in: RoundedRectangle(cornerRadius: 15))
        .overlay(
            RoundedRectangle(cornerRadius: 15)
                .stroke(Color(nsColor: .separatorColor).opacity(0.30))
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transforms.card.\(definition.id.uuidString)")
    }

    private var icon: String {
        switch definition.kind {
        case .polish: return "sparkles"
        case .promptEngineer: return "terminal"
        case .custom: return "wand.and.stars"
        }
    }

    private var tint: Color {
        switch definition.kind {
        case .polish: return .purple
        case .promptEngineer: return .blue
        case .custom: return .indigo
        }
    }

    private var description: String {
        switch definition.kind {
        case .polish:
            return "Improve clarity, structure, and correctness while keeping your voice."
        case .promptEngineer:
            return "Turn rough instructions into a precise, structured AI prompt."
        case .custom:
            return definition.prompt
        }
    }
}

private struct TransformEditorView: View {
    private struct SampleDraft: Identifiable {
        let id: UUID
        var text: String
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState

    let definition: TransformDefinition?
    @State private var name: String
    @State private var prompt: String
    @State private var hotkey: Hotkey
    @State private var sampleDrafts: [SampleDraft]
    @State private var polishConfiguration: PolishConfiguration
    @State private var validationMessage: String?

    private var kind: TransformKind { definition?.kind ?? .custom }

    init(definition: TransformDefinition?, suggestedHotkey: Hotkey) {
        self.definition = definition
        _name = State(initialValue: definition?.name ?? "")
        _prompt = State(initialValue: definition?.prompt ?? "")
        _hotkey = State(initialValue: definition?.hotkey ?? suggestedHotkey)
        _sampleDrafts = State(initialValue: (definition?.writingSamples ?? []).map {
            SampleDraft(id: $0.id, text: $0.text)
        })
        _polishConfiguration = State(initialValue: .default)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text("Transforms rewrite only the text you select.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(22)

            Divider()

            Form {
                Section("Transform") {
                    if kind == .custom {
                        TextField("Name", text: $name, prompt: Text("For example: Make friendlier"))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("transform.editor.name")
                    } else {
                        LabeledContent("Name", value: definition?.name ?? name)
                    }

                    if kind == .polish {
                        polishRules
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Instructions")
                                .font(.callout.weight(.medium))
                            TextEditor(text: $prompt)
                                .font(.body)
                                .frame(minHeight: 108)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.45))
                                )
                                .accessibilityIdentifier("transform.editor.prompt")
                            Text("\(prompt.count.formatted()) / \(TransformDefinition.promptCharacterLimit.formatted())")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(prompt.count > TransformDefinition.promptCharacterLimit ? Color.red : Color.secondary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }

                Section("Keyboard shortcut") {
                    HStack {
                        Text("Run on selected text")
                        Spacer()
                        HotkeyRecorder(hotkey: $hotkey) { captured in
                            hotkey = captured
                            validationMessage = nil
                        }
                    }
                    Text("Use at least one modifier. Shortcuts become global only after transforms are enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !TransformShortcutValidator.isAllowed(hotkey) {
                        Text(TransformValidationError.invalidShortcut.localizedDescription)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("transform.editor.shortcut-validation")
                    }
                }

                Section("Writing samples") {
                    Text("Add up to five examples of your writing. Each sample must contain 50–500 words and is used only for this transform.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach($sampleDrafts) { $sample in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Sample")
                                    .font(.callout.weight(.medium))
                                Spacer()
                                Text("\(wordCount(sample.text)) words")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(sampleWordCountColor(sample.text))
                                Button(role: .destructive) {
                                    sampleDrafts.removeAll { $0.id == sample.id }
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove writing sample")
                            }
                            TextEditor(text: $sample.text)
                                .frame(minHeight: 92)
                                .scrollContentBackground(.hidden)
                                .padding(4)
                                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7)
                                        .stroke(Color(nsColor: .separatorColor).opacity(0.45))
                                )
                        }
                    }

                    Button {
                        sampleDrafts.append(SampleDraft(id: UUID(), text: ""))
                    } label: {
                        Label("Add writing sample", systemImage: "plus")
                    }
                    .disabled(sampleDrafts.count >= TransformDefinition.writingSampleLimit)
                }

                if let validationMessage {
                    Text(validationMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("transform.editor.validation")
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()

            HStack {
                Text(kind == .polish ? "Polish rules apply to selected text and automatic dictation." : "Selected text and samples are sent to your OpenAI account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(definition == nil ? "Create transform" : "Save changes") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canSave)
                    .accessibilityIdentifier("transform.editor.save")
            }
            .padding(16)
        }
        .frame(width: 650, height: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            polishConfiguration = appState.transformSettings.polishConfiguration
        }
        .onChange(of: name) { _ in validationMessage = nil }
        .onChange(of: prompt) { _ in validationMessage = nil }
    }

    @ViewBuilder
    private var polishRules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Make concise", isOn: $polishConfiguration.makeConcise)
            Toggle("Reword for clarity", isOn: $polishConfiguration.rewordForClarity)
            Toggle("Reorder for readability", isOn: $polishConfiguration.reorderForReadability)
            Toggle("Add useful structure", isOn: $polishConfiguration.addStructure)
            Toggle("Maintain my tone", isOn: $polishConfiguration.maintainTone)
        }

        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Custom rules")
                    .font(.callout.weight(.medium))
                Spacer()
                Text("\(polishConfiguration.customInstructions.count) / \(PolishConfiguration.customInstructionLimit)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(polishConfiguration.customInstructions.indices, id: \.self) { index in
                HStack {
                    TextField(
                        "For example: Avoid semicolons",
                        text: $polishConfiguration.customInstructions[index]
                    )
                    .textFieldStyle(.roundedBorder)
                    Button(role: .destructive) {
                        polishConfiguration.customInstructions.remove(at: index)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove Polish rule")
                }
            }
            Button {
                polishConfiguration.customInstructions.append("")
            } label: {
                Label("Add custom rule", systemImage: "plus")
            }
            .disabled(polishConfiguration.customInstructions.count >= PolishConfiguration.customInstructionLimit)
        }
    }

    private var title: String {
        if let definition { return "Edit \(definition.name)" }
        return "Create a transform"
    }

    private var canSave: Bool {
        let samplesAreComplete = sampleDrafts.allSatisfy {
            (TransformWritingSample.minimumWordCount...TransformWritingSample.maximumWordCount)
                .contains(wordCount($0.text))
        }
        guard samplesAreComplete, TransformShortcutValidator.isAllowed(hotkey) else { return false }
        if kind == .custom {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && name.count <= TransformDefinition.nameCharacterLimit
                && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && prompt.count <= TransformDefinition.promptCharacterLimit
        }
        if kind == .polish {
            return polishConfiguration.customInstructions.allSatisfy {
                let count = wordCount($0)
                return count > 0 && count <= PolishConfiguration.customInstructionWordLimit
            }
        }
        return !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && prompt.count <= TransformDefinition.promptCharacterLimit
    }

    private func save() {
        do {
            let samples = sampleDrafts.map {
                TransformWritingSample(id: $0.id, text: $0.text)
            }
            if kind == .polish {
                _ = try appState.savePolishTransform(
                    configuration: polishConfiguration,
                    hotkey: hotkey,
                    writingSamples: samples
                )
            } else {
                _ = try appState.saveTransform(
                    id: definition?.id,
                    kind: kind,
                    name: kind == .custom ? name : (definition?.name ?? name),
                    prompt: prompt,
                    hotkey: hotkey,
                    writingSamples: samples
                )
            }
            dismiss()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func sampleWordCountColor(_ text: String) -> Color {
        let count = wordCount(text)
        return (TransformWritingSample.minimumWordCount...TransformWritingSample.maximumWordCount).contains(count)
            ? .secondary
            : .red
    }
}

private struct TransformResultView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject var transformController: TransformController

    var body: some View {
        Group {
            if let result {
                resultContent(
                    result: result,
                    diff: TransformDiff(
                        original: result.originalText,
                        transformed: result.transformedText
                    )
                )
            } else {
                emptyContent
            }
        }
        .frame(width: 680, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func resultContent(
        result: TransformResult,
        diff: TransformDiff
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(result.invocation.name)
                        .font(.title2.weight(.semibold))
                    Text("\(diff.changeCount) \(diff.changeCount == 1 ? "change" : "changes")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(20)

            Divider()

            ScrollView {
                Text(diff.attributedText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(22)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.55))

            Divider()

            HStack {
                Text("Added text is green. Removed text is red and struck through.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo") {
                    transformController.undoLastTransform()
                }
                .disabled(!result.canUndo || transformController.canCancel)
                Button("Copy") {
                    transformController.copyLastTransform()
                }
                Button("Retry") {
                    transformController.retryLastTransform()
                }
                .buttonStyle(.borderedProminent)
                .disabled(transformController.canCancel)
            }
            .padding(16)
        }
    }

    private var emptyContent: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Transform result")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
            .padding(20)
            Divider()
            EmptyStateView(
                systemImage: "wand.and.stars",
                title: "No transform result",
                message: "Run a transform on selected text first."
            )
        }
    }

    private var result: TransformResult? {
        appState.lastTransformResult
    }
}
