import AppKit
import ApplicationServices
import Foundation
import NaturalLanguage

enum StyleAppCategory: String, CaseIterable, Codable, Identifiable {
    case personal
    case work
    case email
    case other

    var id: Self { self }

    var title: String {
        switch self {
        case .personal: return "Personal messages"
        case .work: return "Work messages"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var shortTitle: String {
        switch self {
        case .personal: return "Personal"
        case .work: return "Work"
        case .email: return "Email"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .personal: return "message.fill"
        case .work: return "bubble.left.and.bubble.right.fill"
        case .email: return "envelope.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }

    var detail: String {
        switch self {
        case .personal:
            return "Messages, WhatsApp, Telegram, and other personal conversations."
        case .work:
            return "Slack, Microsoft Teams, Discord, and other work chats."
        case .email:
            return "Mail, Outlook, Gmail, Superhuman, and other email clients."
        case .other:
            return "Documents, notes, browsers, and every app without another assignment."
        }
    }
}

enum WritingStyle: String, CaseIterable, Codable, Identifiable {
    case formal
    case casual
    case veryCasual
    case excited

    var id: Self { self }

    var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very Casual"
        case .excited: return "Excited"
        }
    }

    var summary: String {
        switch self {
        case .formal: return "Caps + more periods"
        case .casual: return "Caps + less punctuation"
        case .veryCasual: return "No caps + less punctuation"
        case .excited: return "Caps + more exclamation points"
        }
    }

    var systemImage: String {
        switch self {
        case .formal: return "textformat"
        case .casual: return "face.smiling"
        case .veryCasual: return "textformat.size.smaller"
        case .excited: return "party.popper.fill"
        }
    }

    static func available(for category: StyleAppCategory) -> [WritingStyle] {
        switch category {
        case .personal:
            return [.formal, .casual, .veryCasual]
        case .work, .email, .other:
            return [.formal, .casual, .excited]
        }
    }

    func example(for category: StyleAppCategory) -> String {
        let formalText: String
        switch category {
        case .personal:
            formalText = "Sounds good. I'll see you there."
        case .work:
            formalText = "I'll send the update this afternoon."
        case .email:
            formalText = "Thanks for reaching out. I'll follow up tomorrow."
        case .other:
            formalText = "Here are the next steps for the project."
        }
        return TranscriptStyleFormatter.format(formalText, as: self)
    }
}

struct StyleAppAssignment: Codable, Equatable, Identifiable {
    let bundleIdentifier: String
    let applicationName: String
    let category: StyleAppCategory

    var id: String { bundleIdentifier.lowercased() }
}

struct StylePreferences: Codable, Equatable {
    var hasCompletedSetup: Bool
    var selections: [StyleAppCategory: WritingStyle]
    var customAssignments: [StyleAppAssignment]

    static let `default` = StylePreferences(
        hasCompletedSetup: false,
        selections: defaultSelections,
        customAssignments: []
    )

    static var defaultSelections: [StyleAppCategory: WritingStyle] {
        Dictionary(uniqueKeysWithValues: StyleAppCategory.allCases.map { ($0, .formal) })
    }

    func style(for category: StyleAppCategory) -> WritingStyle {
        let candidate = selections[category] ?? .formal
        return WritingStyle.available(for: category).contains(candidate) ? candidate : .formal
    }
}

enum StyleStore {
    static let currentVersion = 2

    struct LoadResult {
        let preferences: StylePreferences
        let rejectedRecordCount: Int
        let needsMigration: Bool

        var shouldBackUpOriginal: Bool { rejectedRecordCount > 0 }
    }

    private struct StoredEnvelope: Encodable {
        let version: Int
        let preferences: StoredPreferences
    }

    private struct StoredPreferences: Encodable {
        let hasCompletedSetup: Bool
        let selections: [StoredSelection]
        let customAssignments: [StoredAssignment]
    }

    private struct StoredSelection: Encodable {
        let category: String
        let style: String
    }

    private struct StoredAssignment: Encodable {
        let bundleIdentifier: String
        let applicationName: String
        let category: String
    }

    static func encode(_ preferences: StylePreferences) throws -> Data {
        let normalizedPreferences = normalized(preferences).preferences
        return try JSONEncoder().encode(
            StoredEnvelope(
                version: currentVersion,
                preferences: StoredPreferences(
                    hasCompletedSetup: normalizedPreferences.hasCompletedSetup,
                    selections: StyleAppCategory.allCases.map { category in
                        StoredSelection(
                            category: category.rawValue,
                            style: normalizedPreferences.style(for: category).rawValue
                        )
                    },
                    customAssignments: normalizedPreferences.customAssignments.map {
                        StoredAssignment(
                            bundleIdentifier: $0.bundleIdentifier,
                            applicationName: $0.applicationName,
                            category: $0.category.rawValue
                        )
                    }
                )
            )
        )
    }

    static func decode(_ data: Data) -> LoadResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = root["version"] as? Int,
              (1...currentVersion).contains(version),
              let storedPreferences = root["preferences"] as? [String: Any] else {
            return LoadResult(
                preferences: .default,
                rejectedRecordCount: 1,
                needsMigration: false
            )
        }

        var rejectedRecordCount = 0
        let hasCompletedSetup: Bool
        if let storedSetup = storedPreferences["hasCompletedSetup"] as? Bool {
            hasCompletedSetup = storedSetup
        } else {
            hasCompletedSetup = false
            rejectedRecordCount += 1
        }

        var selections = StylePreferences.defaultSelections
        var seenCategories = Set<StyleAppCategory>()
        if let storedSelections = storedPreferences["selections"] as? [Any] {
            if version == 1 {
                for index in stride(from: 0, to: storedSelections.count, by: 2) {
                    guard index + 1 < storedSelections.count,
                          let categoryValue = storedSelections[index] as? String,
                          let styleValue = storedSelections[index + 1] as? String else {
                        rejectedRecordCount += 1
                        continue
                    }
                    decodeSelection(
                        categoryValue: categoryValue,
                        styleValue: styleValue,
                        selections: &selections,
                        seenCategories: &seenCategories,
                        rejectedRecordCount: &rejectedRecordCount
                    )
                }
            } else {
                for record in storedSelections {
                    guard let record = record as? [String: Any],
                          let categoryValue = record["category"] as? String,
                          let styleValue = record["style"] as? String else {
                        rejectedRecordCount += 1
                        continue
                    }
                    decodeSelection(
                        categoryValue: categoryValue,
                        styleValue: styleValue,
                        selections: &selections,
                        seenCategories: &seenCategories,
                        rejectedRecordCount: &rejectedRecordCount
                    )
                }
            }
        } else {
            rejectedRecordCount += 1
        }

        for category in StyleAppCategory.allCases where !seenCategories.contains(category) {
            rejectedRecordCount += 1
        }

        var assignmentsByIdentifier: [String: StyleAppAssignment] = [:]
        if let storedAssignments = storedPreferences["customAssignments"] as? [Any] {
            for record in storedAssignments {
                guard let record = record as? [String: Any],
                      let identifierValue = record["bundleIdentifier"] as? String,
                      let nameValue = record["applicationName"] as? String,
                      let categoryValue = record["category"] as? String,
                      let category = StyleAppCategory(rawValue: categoryValue) else {
                    rejectedRecordCount += 1
                    continue
                }
                let identifier = identifierValue
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                let name = nameValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !identifier.isEmpty, !name.isEmpty,
                      assignmentsByIdentifier[identifier] == nil else {
                    rejectedRecordCount += 1
                    continue
                }
                assignmentsByIdentifier[identifier] = StyleAppAssignment(
                    bundleIdentifier: identifier,
                    applicationName: name,
                    category: category
                )
            }
        } else {
            rejectedRecordCount += 1
        }

        return LoadResult(
            preferences: StylePreferences(
                hasCompletedSetup: hasCompletedSetup,
                selections: selections,
                customAssignments: assignmentsByIdentifier.values.sorted {
                    $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
                }
            ),
            rejectedRecordCount: rejectedRecordCount,
            needsMigration: version < currentVersion
        )
    }

    private static func decodeSelection(
        categoryValue: String,
        styleValue: String,
        selections: inout [StyleAppCategory: WritingStyle],
        seenCategories: inout Set<StyleAppCategory>,
        rejectedRecordCount: inout Int
    ) {
        guard let category = StyleAppCategory(rawValue: categoryValue),
              let style = WritingStyle(rawValue: styleValue),
              WritingStyle.available(for: category).contains(style),
              seenCategories.insert(category).inserted else {
            rejectedRecordCount += 1
            return
        }
        selections[category] = style
    }

    private static func normalized(
        _ preferences: StylePreferences
    ) -> (preferences: StylePreferences, rejectedRecordCount: Int) {
        var normalizedSelections = StylePreferences.defaultSelections
        var rejectedRecordCount = 0
        for category in StyleAppCategory.allCases {
            guard let style = preferences.selections[category],
                  WritingStyle.available(for: category).contains(style) else {
                rejectedRecordCount += 1
                continue
            }
            normalizedSelections[category] = style
        }

        var assignmentsByIdentifier: [String: StyleAppAssignment] = [:]
        for assignment in preferences.customAssignments {
            let identifier = assignment.bundleIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let name = assignment.applicationName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, !name.isEmpty,
                  assignmentsByIdentifier[identifier] == nil else {
                rejectedRecordCount += 1
                continue
            }
            assignmentsByIdentifier[identifier] = StyleAppAssignment(
                bundleIdentifier: identifier,
                applicationName: name,
                category: assignment.category
            )
        }

        return (
            StylePreferences(
                hasCompletedSetup: preferences.hasCompletedSetup,
                selections: normalizedSelections,
                customAssignments: assignmentsByIdentifier.values.sorted {
                    $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
                }
            ),
            rejectedRecordCount
        )
    }
}

struct StyleAppContext: Equatable {
    let bundleIdentifier: String?
    let applicationName: String?
    let documentURL: URL?
}

@MainActor
protocol StyleAppContextProviding {
    func currentContext() async -> StyleAppContext
}

@MainActor
final class SystemStyleAppContextProvider: StyleAppContextProviding {
    func currentContext() async -> StyleAppContext {
        let application = NSWorkspace.shared.frontmostApplication
        let documentURL: URL?
        if let processIdentifier = application?.processIdentifier {
            documentURL = await Self.boundedDocumentURL(
                processIdentifier: processIdentifier
            )
        } else {
            documentURL = nil
        }
        return StyleAppContext(
            bundleIdentifier: application?.bundleIdentifier,
            applicationName: application?.localizedName,
            documentURL: documentURL
        )
    }

    nonisolated private static func boundedDocumentURL(
        processIdentifier: pid_t
    ) async -> URL? {
        await withCheckedContinuation { continuation in
            let gate = StyleDocumentURLContinuation(continuation: continuation)
            DispatchQueue.global(qos: .userInitiated).async {
                gate.resume(with: documentURL(processIdentifier: processIdentifier))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .milliseconds(150)
            ) {
                gate.resume(with: nil)
            }
        }
    }

    nonisolated private static func documentURL(processIdentifier: pid_t) -> URL? {
        let application = AXUIElementCreateApplication(processIdentifier)
        guard let focusedElement = copyElementAttribute(
            kAXFocusedUIElementAttribute as CFString,
            from: application
        ) else {
            return nil
        }

        var element = focusedElement
        for _ in 0..<10 {
            if let document = copyAttribute(
                kAXDocumentAttribute as CFString,
                from: element
            ) as? String,
               let url = URL(string: document),
               url.scheme != nil {
                return url
            }
            guard let parent = copyElementAttribute(
                kAXParentAttribute as CFString,
                from: element
            ) else {
                break
            }
            element = parent
        }
        return nil
    }

    nonisolated private static func copyElementAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> AXUIElement? {
        guard let value = copyAttribute(attribute, from: element),
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    nonisolated private static func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }
}

private final class StyleDocumentURLContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL?, Never>?

    init(continuation: CheckedContinuation<URL?, Never>) {
        self.continuation = continuation
    }

    func resume(with value: URL?) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        lock.unlock()
        continuation.resume(returning: value)
    }
}

struct StyleKnownApplication: Identifiable, Equatable {
    let name: String
    let bundleIdentifier: String
    let category: StyleAppCategory

    var id: String { bundleIdentifier.lowercased() }
}

enum StyleAppCatalog {
    static let applications: [StyleKnownApplication] = [
        .init(name: "Messages", bundleIdentifier: "com.apple.MobileSMS", category: .personal),
        .init(name: "WhatsApp", bundleIdentifier: "net.whatsapp.WhatsApp", category: .personal),
        .init(name: "Telegram", bundleIdentifier: "ru.keepcoder.Telegram", category: .personal),
        .init(name: "WeChat", bundleIdentifier: "com.tencent.xinWeChat", category: .personal),
        .init(name: "Messenger", bundleIdentifier: "com.facebook.archon", category: .personal),
        .init(name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap", category: .work),
        .init(name: "Microsoft Teams", bundleIdentifier: "com.microsoft.teams2", category: .work),
        .init(name: "Discord", bundleIdentifier: "com.hnc.Discord", category: .work),
        .init(name: "Mail", bundleIdentifier: "com.apple.mail", category: .email),
        .init(name: "Microsoft Outlook", bundleIdentifier: "com.microsoft.Outlook", category: .email),
        .init(name: "Superhuman", bundleIdentifier: "com.superhuman.electron", category: .email),
        .init(name: "Spark", bundleIdentifier: "com.readdle.smartemail-Mac", category: .email)
    ]

    static func applications(for category: StyleAppCategory) -> [StyleKnownApplication] {
        applications.filter { $0.category == category }
    }

    static func visibleApplications(
        for category: StyleAppCategory,
        preferences: StylePreferences
    ) -> [StyleKnownApplication] {
        let overriddenIdentifiers = Set(
            preferences.customAssignments.map { $0.bundleIdentifier.lowercased() }
        )
        return applications(for: category).filter {
            !overriddenIdentifiers.contains($0.id)
        }
    }
}

enum StyleAppClassifier {
    private static let personalDomains = [
        "web.whatsapp.com", "messages.google.com", "messenger.com", "web.telegram.org", "web.wechat.com"
    ]
    private static let workDomains = [
        "app.slack.com", "slack.com", "teams.microsoft.com", "discord.com"
    ]
    private static let emailDomains = [
        "mail.google.com", "outlook.office.com", "outlook.live.com", "mail.yahoo.com", "app.superhuman.com"
    ]

    static func category(
        for context: StyleAppContext,
        preferences: StylePreferences
    ) -> StyleAppCategory {
        if let identifier = context.bundleIdentifier?.lowercased(),
           let assignment = preferences.customAssignments.first(where: {
               $0.bundleIdentifier.caseInsensitiveCompare(identifier) == .orderedSame
           }) {
            return assignment.category
        }

        if let host = context.documentURL?.host?.lowercased() {
            if matches(host, domains: personalDomains) { return .personal }
            if matches(host, domains: workDomains) { return .work }
            if matches(host, domains: emailDomains) { return .email }
        }

        if let identifier = context.bundleIdentifier?.lowercased(),
           let known = StyleAppCatalog.applications.first(where: {
               $0.bundleIdentifier.lowercased() == identifier
           }) {
            return known.category
        }
        return .other
    }

    private static func matches(_ host: String, domains: [String]) -> Bool {
        domains.contains { domain in
            host == domain || host.hasSuffix(".\(domain)")
        }
    }
}

enum WritingStyleLanguagePolicy {
    private static let minimumEnglishConfidence = 0.6

    static func shouldApply(
        configuredLanguage: String,
        to text: String
    ) -> Bool {
        let configuredLanguage = configuredLanguage
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !configuredLanguage.isEmpty {
            return configuredLanguage == "en"
                || configuredLanguage.hasPrefix("en-")
                || configuredLanguage.hasPrefix("english")
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 3)
        return recognizer.dominantLanguage == .english
            && hypotheses[.english, default: 0] >= minimumEnglishConfidence
    }
}

enum TranscriptStyleFormatter {
    private static let nonTerminalAbbreviations: Set<String> = [
        "a.m.", "dr.", "e.g.", "i.e.", "jr.", "mr.", "mrs.", "ms.",
        "mt.", "p.m.", "prof.", "sr.", "st.", "u.k.", "u.s."
    ]

    static func format(_ text: String, as style: WritingStyle) -> String {
        guard !text.isEmpty else { return text }
        return text
            .components(separatedBy: "\n")
            .map { formatLine($0, as: style) }
            .joined(separator: "\n")
    }

    private static func formatLine(_ line: String, as style: WritingStyle) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isCodeLike(trimmed) else { return line }

        let leadingWhitespace = String(line.prefix { $0.isWhitespace })
        var content = trimmed.replacingOccurrences(
            of: #"[\t ]+([,.!?;:])"#,
            with: "$1",
            options: .regularExpression
        )

        if style == .veryCasual {
            content = content.replacingOccurrences(
                of: #"[,;](?=\s)"#,
                with: "",
                options: .regularExpression
            )
            content = content.replacingOccurrences(
                of: #"[\t ]{2,}"#,
                with: " ",
                options: .regularExpression
            )
        }

        content = applyingCapitalization(to: content, style: style)
        content = applyingTerminalPunctuation(to: content, style: style)
        return leadingWhitespace + content
    }

    private static func applyingCapitalization(
        to text: String,
        style: WritingStyle
    ) -> String {
        let sentenceBoundaries = sentenceBoundaryIndices(in: text)
        var result = ""
        var isAtSentenceStart = true

        for index in text.indices {
            let character = text[index]
            if isAtSentenceStart, character.isLetter {
                if style == .veryCasual {
                    let nextIndex = text.index(after: index)
                    let nextIsUppercase = nextIndex < text.endIndex
                        && text[nextIndex].isUppercase
                    result.append(
                        contentsOf: character.isUppercase && nextIsUppercase
                            ? String(character)
                            : String(character).lowercased()
                    )
                } else {
                    result.append(contentsOf: String(character).uppercased())
                }
                isAtSentenceStart = false
            } else {
                result.append(character)
            }

            if sentenceBoundaries.contains(index) {
                isAtSentenceStart = true
            }
        }
        return result
    }

    private static func applyingTerminalPunctuation(
        to text: String,
        style: WritingStyle
    ) -> String {
        let closingCharacters = CharacterSet(charactersIn: "\"'”’)]}")
        var body = text
        var closingSuffix = ""
        while let last = body.unicodeScalars.last,
              closingCharacters.contains(last) {
            closingSuffix.insert(Character(String(last)), at: closingSuffix.startIndex)
            body.removeLast()
        }
        guard let last = body.last else { return text }

        let punctuatedBody: String
        switch style {
        case .formal:
            punctuatedBody = ".!?".contains(last) ? body : body + "."
        case .casual, .veryCasual:
            punctuatedBody = last == "." ? String(body.dropLast()) : body
        case .excited:
            let excitedBody = replacingSentencePeriodsWithExclamations(in: body)
            punctuatedBody = "!?".contains(excitedBody.last ?? " ")
                ? excitedBody
                : excitedBody + "!"
        }
        return punctuatedBody + closingSuffix
    }

    private static func replacingSentencePeriodsWithExclamations(in text: String) -> String {
        let boundaries = sentenceBoundaryIndices(in: text)
        var result = ""
        for index in text.indices {
            let character = text[index]
            result.append(character == "." && boundaries.contains(index) ? "!" : character)
        }
        return result
    }

    private static func sentenceBoundaryIndices(in text: String) -> Set<String.Index> {
        var boundaries = Set<String.Index>()
        for index in text.indices {
            let character = text[index]
            if character == "?" || character == "!" {
                boundaries.insert(index)
            } else if character == ".", !isProtectedPeriod(at: index, in: text) {
                boundaries.insert(index)
            }
        }
        return boundaries
    }

    private static func isProtectedPeriod(
        at index: String.Index,
        in text: String
    ) -> Bool {
        let previousIndex = index > text.startIndex ? text.index(before: index) : nil
        let nextIndex = text.index(after: index)
        let previousCharacter = previousIndex.map { text[$0] }
        let nextCharacter = nextIndex < text.endIndex ? text[nextIndex] : nil

        if previousCharacter == "." || nextCharacter == "." {
            return true
        }
        if previousCharacter?.isNumber == true, nextCharacter?.isNumber == true {
            return true
        }
        if nextCharacter?.isLetter == true || nextCharacter?.isNumber == true {
            return true
        }

        var tokenStart = index
        while tokenStart > text.startIndex {
            let candidate = text.index(before: tokenStart)
            let character = text[candidate]
            guard character.isLetter || character == "." else { break }
            tokenStart = candidate
        }
        let token = String(text[tokenStart...index]).lowercased()
        return nonTerminalAbbreviations.contains(token)
            || token.range(of: #"^(?:[a-z]\.)+$"#, options: .regularExpression) != nil
    }

    private static func isCodeLike(_ text: String) -> Bool {
        if text.hasPrefix("```") || text.hasPrefix("$") || text.hasPrefix(">") {
            return true
        }
        if text.range(of: #"^(?:[-*•]|\d+[.)])\s"#, options: .regularExpression) != nil {
            return true
        }
        if text.contains("://") || text.contains("{") || text.contains("}")
            || text.contains("=>") || text.contains("::") {
            return true
        }
        return false
    }
}
