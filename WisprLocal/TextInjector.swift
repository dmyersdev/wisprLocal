import AppKit
import ApplicationServices
import Carbon
import Foundation

struct PasteboardSnapshot: Equatable {
    struct Item: Equatable {
        struct Representation: Equatable {
            let typeIdentifier: String
            let data: Data
        }

        let representations: [Representation]
    }

    let items: [Item]
}

@MainActor
protocol PasteboardAccessing: AnyObject {
    var changeCount: Int { get }

    func snapshot() -> PasteboardSnapshot?
    func readString() -> String?
    func writeTemporaryText(_ text: String) -> Int?
    func copyText(_ text: String) -> Bool
    func restore(_ snapshot: PasteboardSnapshot, ifChangeCountMatches expectedChangeCount: Int) -> Bool
}

@MainActor
final class SystemPasteboard: PasteboardAccessing {
    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    static let maximumSnapshotSize = 8 * 1_024 * 1_024

    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int {
        pasteboard.changeCount
    }

    func snapshot() -> PasteboardSnapshot? {
        guard let pasteboardItems = pasteboard.pasteboardItems, !pasteboardItems.isEmpty else {
            return PasteboardSnapshot(items: [])
        }

        var byteCount = 0
        var snapshotItems: [PasteboardSnapshot.Item] = []
        for pasteboardItem in pasteboardItems {
            if pasteboardItem.types.contains(where: Self.isExcludedType) {
                return nil
            }

            var representations: [PasteboardSnapshot.Item.Representation] = []
            for type in pasteboardItem.types {
                guard let data = pasteboardItem.data(forType: type) else { continue }
                byteCount += data.count
                guard byteCount <= Self.maximumSnapshotSize else { return nil }
                representations.append(
                    .init(typeIdentifier: type.rawValue, data: data)
                )
            }
            guard !representations.isEmpty else { return nil }
            snapshotItems.append(.init(representations: representations))
        }
        return PasteboardSnapshot(items: snapshotItems)
    }

    func readString() -> String? {
        pasteboard.string(forType: .string)
    }

    func writeTemporaryText(_ text: String) -> Int? {
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return nil }
        return pasteboard.changeCount
    }

    func copyText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    func restore(
        _ snapshot: PasteboardSnapshot,
        ifChangeCountMatches expectedChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == expectedChangeCount else { return false }

        let restoredItems = snapshot.items.map { snapshotItem -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for representation in snapshotItem.representations {
                item.setData(
                    representation.data,
                    forType: NSPasteboard.PasteboardType(representation.typeIdentifier)
                )
            }
            return item
        }

        pasteboard.clearContents()
        if restoredItems.isEmpty {
            return true
        }
        return pasteboard.writeObjects(restoredItems)
    }

    private static func isExcludedType(_ type: NSPasteboard.PasteboardType) -> Bool {
        let identifier = type.rawValue.lowercased()
        return type == .fileURL
            || type == .pdf
            || type == .rtfd
            || identifier.contains("flat-rtfd")
            || identifier.contains("audio")
    }
}

@MainActor
protocol KeyboardEventPosting: AnyObject {
    func postCopy()
    func postPaste()
    func postReturn()
}

@MainActor
final class SystemKeyboardEventPoster: KeyboardEventPosting {
    func postCopy() {
        postKey(keyCode: CGKeyCode(kVK_ANSI_C), flags: .maskCommand)
    }

    func postPaste() {
        postKey(keyCode: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)
    }

    func postReturn() {
        postKey(keyCode: CGKeyCode(kVK_Return), flags: [])
    }

    private func postKey(keyCode: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = flags
        keyUp?.flags = flags
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}

@MainActor
protocol AccessibilityAuthorizing: AnyObject {
    func ensureAccessibility() -> Bool
}

@MainActor
final class SystemAccessibilityAuthorizer: AccessibilityAuthorizing {
    func ensureAccessibility() -> Bool {
        AccessibilityTrust.isProcessTrusted(prompt: true)
    }
}

@MainActor
protocol TextInjecting: AnyObject {
    func insert(text: String, pressEnter: Bool) async throws
    func insert(
        text: String,
        pressEnter: Bool,
        validatingTarget: @escaping @MainActor () throws -> Void
    ) async throws
    func copy(text: String) throws
}

extension TextInjecting {
    func insert(text: String) async throws {
        try await insert(text: text, pressEnter: false)
    }

    func insert(
        text: String,
        pressEnter: Bool,
        validatingTarget: @escaping @MainActor () throws -> Void
    ) async throws {
        try validatingTarget()
        try await insert(text: text, pressEnter: pressEnter)
    }
}

@MainActor
final class TextInjector: TextInjecting {
    typealias PasteConsumptionDelay = @MainActor () async -> Void

    private let pasteboard: PasteboardAccessing
    private let eventPoster: KeyboardEventPosting
    private let accessibilityAuthorizer: AccessibilityAuthorizing
    private let pasteConsumptionDelay: PasteConsumptionDelay

    convenience init() {
        self.init(
            pasteboard: SystemPasteboard(),
            eventPoster: SystemKeyboardEventPoster(),
            accessibilityAuthorizer: SystemAccessibilityAuthorizer()
        )
    }

    init(
        pasteboard: PasteboardAccessing,
        eventPoster: KeyboardEventPosting,
        accessibilityAuthorizer: AccessibilityAuthorizing,
        pasteConsumptionDelay: @escaping PasteConsumptionDelay = {
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    ) {
        self.pasteboard = pasteboard
        self.eventPoster = eventPoster
        self.accessibilityAuthorizer = accessibilityAuthorizer
        self.pasteConsumptionDelay = pasteConsumptionDelay
    }

    func insert(text: String, pressEnter: Bool) async throws {
        try await insert(
            text: text,
            pressEnter: pressEnter,
            validatingTarget: {}
        )
    }

    func insert(
        text: String,
        pressEnter: Bool,
        validatingTarget: @escaping @MainActor () throws -> Void
    ) async throws {
        guard !text.isEmpty || pressEnter else { return }
        guard accessibilityAuthorizer.ensureAccessibility() else {
            throw AppError.accessibilityDenied
        }

        guard !text.isEmpty else {
            eventPoster.postReturn()
            return
        }

        guard let originalClipboard = pasteboard.snapshot() else {
            throw AppError.clipboardCannotBePreserved
        }
        guard let temporaryChangeCount = pasteboard.writeTemporaryText(text) else {
            throw AppError.pasteboardUnavailable
        }

        do {
            try validatingTarget()
            eventPoster.postPaste()
            await pasteConsumptionDelay()
            if pressEnter, !Task.isCancelled {
                eventPoster.postReturn()
            }
        } catch {
            _ = pasteboard.restore(
                originalClipboard,
                ifChangeCountMatches: temporaryChangeCount
            )
            throw error
        }

        _ = pasteboard.restore(
            originalClipboard,
            ifChangeCountMatches: temporaryChangeCount
        )
    }

    func copy(text: String) throws {
        guard pasteboard.copyText(text) else {
            throw AppError.pasteboardUnavailable
        }
    }
}
