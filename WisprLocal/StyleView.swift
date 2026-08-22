import AppKit
import SwiftUI

struct StyleView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedCategory: StyleAppCategory = .personal
    @State private var isSetupPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 14)
    ]

    var body: some View {
        ZStack {
            background
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    categoryPicker
                    if appState.stylePreferences.hasCompletedSetup {
                        styleCards
                        applicationAssignments
                    } else {
                        setupCard
                    }
                    if let recoveryMessage = appState.styleRecoveryMessage {
                        recoveryCard(recoveryMessage)
                    }
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
            }
        }
        .navigationTitle("Styles")
        .sheet(isPresented: $isSetupPresented) {
            StyleSetupView()
                .environmentObject(appState)
        }
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color(red: 0.97, green: 0.94, blue: 1.0).opacity(0.60)
            ],
            startPoint: .top,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Make WisprLocal sound like you")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Pick a writing style for each kind of app. WisprLocal adjusts capitalization, punctuation, and spacing without changing your words.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Image(systemName: "textformat.alt")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
                .frame(width: 52, height: 52)
                .background(
                    Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
        }
    }

    private var categoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Where are you writing?")
                .font(.headline)
            Picker("App category", selection: $selectedCategory) {
                ForEach(StyleAppCategory.allCases) { category in
                    Text(category.shortTitle).tag(category)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("styles.categoryPicker")

            Label(selectedCategory.detail, systemImage: selectedCategory.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 46, height: 46)
                    .background(
                        LinearGradient(
                            colors: [
                                Color(red: 0.43, green: 0.25, blue: 0.95),
                                Color(red: 0.73, green: 0.39, blue: 0.97)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Personalize your writing style")
                        .font(.title3.weight(.semibold))
                    Text("Choose a default for Personal, Work, Email, and Other. Setup takes about a minute and applies only to new English dictations.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button("Start now") { isSetupPresented = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("styles.startSetup")
                Button("Use formal defaults") {
                    appState.completeStyleSetup(selections: StylePreferences.defaultSelections)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
        .padding(20)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.92),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.22))
        )
    }

    private var styleCards: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Choose a style")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("Applies to new dictations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(WritingStyle.available(for: selectedCategory)) { style in
                    StyleCard(
                        style: style,
                        category: selectedCategory,
                        isSelected: appState.stylePreferences.style(for: selectedCategory) == style
                    ) {
                        appState.setWritingStyle(style, for: selectedCategory)
                    }
                }
            }
        }
    }

    private var applicationAssignments: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Apps in this category")
                        .font(.title3.weight(.semibold))
                    Text("WisprLocal detects these apps automatically. Add any running app to override its category.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                addApplicationMenu
            }

            PillFlowLayout(spacing: 8) {
                ForEach(knownApplications) { application in
                    ApplicationPill(name: application.name, isCustom: false, remove: nil)
                }
                ForEach(customAssignments) { assignment in
                    ApplicationPill(name: assignment.applicationName, isCustom: true) {
                        appState.removeStyleAssignment(bundleIdentifier: assignment.bundleIdentifier)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.86),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.34))
            )
        }
    }

    private var customAssignments: [StyleAppAssignment] {
        appState.stylePreferences.customAssignments.filter { $0.category == selectedCategory }
    }

    private var knownApplications: [StyleKnownApplication] {
        StyleAppCatalog.visibleApplications(
            for: selectedCategory,
            preferences: appState.stylePreferences
        )
    }

    private var addApplicationMenu: some View {
        Menu {
            if runningApplicationCandidates.isEmpty {
                Text("No other apps are running")
            } else {
                ForEach(runningApplicationCandidates) { application in
                    Button(application.name) {
                        appState.assignStyleApplication(
                            bundleIdentifier: application.bundleIdentifier,
                            applicationName: application.name,
                            to: selectedCategory
                        )
                    }
                }
            }
        } label: {
            Label("Add app", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityIdentifier("styles.addApplication")
    }

    private var runningApplicationCandidates: [RunningApplicationCandidate] {
        let ownIdentifier = Bundle.main.bundleIdentifier?.lowercased()
        let assignedIdentifiers = Set(
            appState.stylePreferences.customAssignments.map {
                $0.bundleIdentifier.lowercased()
            }
        )
        let representedIdentifiers = Set(knownApplications.map(\.id))
        var candidatesByIdentifier: [String: RunningApplicationCandidate] = [:]
        for application in NSWorkspace.shared.runningApplications {
            guard application.activationPolicy == .regular,
                  let identifier = application.bundleIdentifier?.lowercased(),
                  identifier != ownIdentifier,
                  !assignedIdentifiers.contains(identifier),
                  !representedIdentifiers.contains(identifier),
                  let name = application.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else {
                continue
            }
            candidatesByIdentifier[identifier] = RunningApplicationCandidate(
                name: name,
                bundleIdentifier: identifier
            )
        }
        return candidatesByIdentifier.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func recoveryCard(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct StyleCard: View {
    let style: WritingStyle
    let category: StyleAppCategory
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Image(systemName: style.systemImage)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(accent)
                        .frame(width: 34, height: 34)
                        .background(accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(style.title)
                            .font(.headline)
                        Text(style.summary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? accent : Color.secondary.opacity(0.45))
                }

                Text(style.example(for: category))
                    .font(.system(size: 14))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 38, alignment: .topLeading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.90),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? accent : Color(nsColor: .separatorColor).opacity(0.35), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.title), \(style.summary)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityIdentifier("styles.card.\(category.rawValue).\(style.rawValue)")
    }

    private var accent: Color {
        Color(red: 0.48, green: 0.29, blue: 0.96)
    }
}

private struct StyleSetupView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selections = StylePreferences.defaultSelections

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Make WisprLocal sound like you")
                        .font(.title2.weight(.bold))
                    Text("Choose how each kind of dictation should look. You can change these anytime.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 0) {
                ForEach(StyleAppCategory.allCases) { category in
                    VStack(alignment: .leading, spacing: 8) {
                        Label(category.title, systemImage: category.systemImage)
                            .font(.headline)
                        Picker(category.title, selection: selection(for: category)) {
                            ForEach(WritingStyle.available(for: category)) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(14)

                    if category != StyleAppCategory.allCases.last {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.40))
            )

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save styles") {
                    appState.completeStyleSetup(selections: selections)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("styles.saveSetup")
            }
        }
        .padding(24)
        .frame(width: 590)
    }

    private func selection(for category: StyleAppCategory) -> Binding<WritingStyle> {
        Binding(
            get: { selections[category] ?? .formal },
            set: { selections[category] = $0 }
        )
    }
}

private struct ApplicationPill: View {
    let name: String
    let isCustom: Bool
    let remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isCustom ? "app.badge" : "app.fill")
                .font(.caption)
            Text(name)
                .font(.caption.weight(.medium))
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isCustom
                ? Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.11)
                : Color(nsColor: .quaternaryLabelColor).opacity(0.16),
            in: Capsule()
        )
    }
}

private struct RunningApplicationCandidate: Identifiable {
    let name: String
    let bundleIdentifier: String

    var id: String { bundleIdentifier }
}

private struct PillFlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maximumWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maximumWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth == 0 ? 0 : spacing) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
