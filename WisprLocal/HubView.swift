import AppKit
import SwiftUI

enum HubDestination: String, CaseIterable, Identifiable {
    case home
    case dictionary
    case snippets
    case styles
    case transforms
    case scratchpad
    case settings

    var id: Self { self }

    var title: String {
        switch self {
        case .home: return "Home"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .styles: return "Styles"
        case .transforms: return "Transforms"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .styles: return "textformat.alt"
        case .transforms: return "wand.and.stars"
        case .scratchpad: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

@MainActor
final class HubNavigationModel: ObservableObject {
    @Published var selection: HubDestination = .home
}

struct HubView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var hotkeyManager: HotkeyManager
    @ObservedObject var historyController: HistoryController
    @ObservedObject var transformController: TransformController
    @ObservedObject var scratchpadController: ScratchpadController
    @ObservedObject var setupController: SetupController
    @ObservedObject var navigation: HubNavigationModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                brand
                List(HubDestination.allCases, selection: $navigation.selection) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                        .accessibilityIdentifier("hub.sidebar.\(destination.rawValue)")
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 204, max: 228)
            .background(Color(nsColor: .controlBackgroundColor))
        } detail: {
            destinationView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .tint(Color(red: 0.48, green: 0.29, blue: 0.96))
        .frame(minWidth: 780, minHeight: 540)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.40, green: 0.24, blue: 0.95),
                                Color(red: 0.72, green: 0.40, blue: 0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "waveform")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("WisprLocal")
                    .font(.system(size: 15, weight: .semibold))
                Text("Local AI dictation")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var destinationView: some View {
        switch navigation.selection {
        case .home:
            HomeView(controller: historyController)
        case .dictionary:
            DictionaryView()
        case .snippets:
            SnippetsView()
        case .styles:
            StyleView()
        case .transforms:
            TransformsView(transformController: transformController)
        case .scratchpad:
            ScratchpadHubView(controller: scratchpadController)
        case .settings:
            SettingsView(
                hotkeyManager: hotkeyManager,
                scratchpadStore: scratchpadController.store,
                setupController: setupController
            )
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var controller: HistoryController
    @State private var searchText = ""
    @State private var pendingDeletion: HistoryItem?

    private var statistics: HistoryStatistics {
        HistoryStatistics(items: appState.history)
    }

    private var sections: [HistoryDaySection] {
        HistoryTimeline.sections(from: appState.history, matching: searchText)
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
                LazyVStack(alignment: .leading, spacing: 22) {
                    header
                    if let message = appState.historyRecoveryMessage {
                        feedbackBanner(message, color: .orange, systemImage: "exclamationmark.triangle.fill")
                    }
                    if let message = appState.historyFeedbackMessage {
                        feedbackBanner(message, color: .purple, systemImage: "info.circle.fill")
                    }
                    if let message = controller.feedbackMessage {
                        feedbackBanner(message, color: .purple, systemImage: "checkmark.circle.fill")
                    }
                    statisticsCard
                    historyFeed
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
            }
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: "Search transcripts or apps"
        )
        .navigationTitle("Home")
        .accessibilityIdentifier("home.view")
        .alert(item: $pendingDeletion) { item in
            Alert(
                title: Text("Delete transcript?"),
                message: Text(
                    item.audioFilename == nil
                        ? "This permanently removes this transcript from this Mac."
                        : "This permanently removes this transcript and its saved recording from this Mac."
                ),
                primaryButton: .destructive(Text("Delete")) {
                    controller.delete(itemID: item.id)
                },
                secondaryButton: .cancel()
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Text("You've written \(statistics.totalWords.formatted()) words")
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                Text("Your complete dictation history stays on this Mac, alongside recordings kept for retry.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Label(appState.hotkeyDisplay, systemImage: "waveform")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.11),
                    in: Capsule()
                )
                .help("Hold \(appState.hotkeyDisplay) to dictate")
        }
    }

    private var statisticsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Your stats", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.headline)
                Spacer()
                Text("Based on retained history")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                HomeMetric(
                    value: statistics.currentStreak.formatted(),
                    label: "day streak"
                )
                Divider().frame(height: 42)
                HomeMetric(
                    value: statistics.averageWordsPerMinute?.formatted() ?? "—",
                    label: "average WPM"
                )
                Divider().frame(height: 42)
                HomeMetric(
                    value: statistics.totalWords.formatted(),
                    label: "total words"
                )
            }
        }
        .padding(18)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.90),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.32))
        )
    }

    private var historyFeed: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(searchText.isEmpty ? "Transcript history" : "Search results")
                    .font(.title3.weight(.semibold))
                Spacer()
                Text("\(sections.reduce(0) { $0 + $1.items.count }) shown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if sections.isEmpty {
                EmptyStateView(
                    systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
                    title: searchText.isEmpty ? "It's quiet here" : "No transcripts found",
                    message: searchText.isEmpty
                        ? "Hold \(appState.hotkeyDisplay) in any text field to create your first dictation."
                        : "Try another phrase or application name."
                )
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title())
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, 2)
                            VStack(spacing: 0) {
                                ForEach(section.items) { item in
                                    HistoryRow(
                                        item: item,
                                        canRetry: appState.historyAudioURL(for: item.id) != nil,
                                        copy: { controller.copy(itemID: item.id) },
                                        retry: { controller.retry(itemID: item.id) },
                                        delete: { pendingDeletion = item }
                                    )
                                    if item.id != section.items.last?.id {
                                        Divider().padding(.leading, 62)
                                    }
                                }
                            }
                            .background(
                                Color(nsColor: .controlBackgroundColor).opacity(0.90),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(nsColor: .separatorColor).opacity(0.32))
                            )
                        }
                    }
                }
            }
        }
    }

    private func feedbackBanner(
        _ message: String,
        color: Color,
        systemImage: String
    ) -> some View {
        Label(message, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(color)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct HomeMetric: View {
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let canRetry: Bool
    let copy: () -> Void
    let retry: () -> Void
    let delete: () -> Void

    @State private var isHovered = false
    @FocusState private var actionsFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HistoryApplicationIcon(bundleIdentifier: item.bundleIdentifier)
            VStack(alignment: .leading, spacing: 7) {
                content
                metadata
            }
            Spacer(minLength: 10)
            actions
                .opacity(isHovered || actionsFocused ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovered || actionsFocused)
        }
        .padding(14)
        .contentShape(Rectangle())
        .accessibilityIdentifier("home.history.row.\(item.id.uuidString.lowercased())")
        .accessibilityActions {
            if item.status == .succeeded, !item.text.isEmpty {
                Button("Copy transcript", action: copy)
            }
            if canRetry, item.status == .failed || item.status == .empty {
                Button("Retry transcript", action: retry)
            }
            Button("Delete transcript", role: .destructive, action: delete)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if item.status == .succeeded, !item.text.isEmpty {
                Button("Copy Transcript", action: copy)
            }
            if canRetry, item.status == .failed || item.status == .empty {
                Button("Retry Transcript", action: retry)
            }
            Divider()
            Button("Delete Transcript", role: .destructive, action: delete)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch item.status {
        case .transcribing, .retrying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(item.status == .retrying ? "Retrying transcript…" : "Transcribing…")
                    .foregroundStyle(.secondary)
            }
        case .failed:
            VStack(alignment: .leading, spacing: 4) {
                Label("Retry your transcript", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                if let message = item.errorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        case .empty:
            Text("Transcription is empty")
                .font(.callout)
                .foregroundStyle(.secondary)
        case .succeeded:
            Text(item.text)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
    }

    private var metadata: some View {
        HStack(spacing: 6) {
            Text(item.displayApplicationName)
            Text("·")
            Text(item.date.formatted(date: .omitted, time: .shortened))
            if let duration = durationText {
                Text("·")
                Text(duration)
            }
            if let wordsPerMinute = item.wordsPerMinute {
                Text("·")
                Text("\(wordsPerMinute) WPM")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if item.status == .succeeded, !item.text.isEmpty {
                rowButton(systemImage: "doc.on.doc", help: "Copy transcript", action: copy)
            }
            if canRetry, item.status == .failed || item.status == .empty {
                rowButton(systemImage: "arrow.clockwise", help: "Retry transcript", action: retry)
            }
            Menu {
                Button("Delete Transcript", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("More transcript actions")
            .accessibilityLabel("More transcript actions")
            .focused($actionsFocused)
        }
    }

    private var durationText: String? {
        guard let duration = item.durationSeconds else { return nil }
        let seconds = max(1, Int(duration.rounded()))
        if seconds < 60 { return "\(seconds)s" }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func rowButton(
        systemImage: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
        .focused($actionsFocused)
    }
}

private struct HistoryApplicationIcon: View {
    let bundleIdentifier: String?

    var body: some View {
        Group {
            if let image = applicationIcon {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "macwindow")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
                    .padding(8)
                    .background(
                        Color(red: 0.48, green: 0.29, blue: 0.96).opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }
        }
        .frame(width: 36, height: 36)
        .accessibilityHidden(true)
    }

    private var applicationIcon: NSImage? {
        guard let bundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(
                  withBundleIdentifier: bundleIdentifier
              ) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color(red: 0.48, green: 0.29, blue: 0.96))
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(nsColor: .separatorColor).opacity(0.30))
        )
    }
}
