import AppKit
import ApplicationServices
import Foundation

struct CapturedTextSelection: Equatable {
    let id: UUID
    let text: String
    let applicationProcessID: pid_t

    var wordCount: Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

struct CapturedTextInsertionTarget: Equatable {
    let id: UUID
    let applicationProcessID: pid_t
}

struct TextReplacementReceipt: Equatable {
    let id: UUID
    let originalText: String
    let replacementText: String
    let applicationProcessID: pid_t
}

@MainActor
protocol SelectedTextEditing: AnyObject {
    func captureSelection() async throws -> CapturedTextSelection
    func captureInsertionTarget() throws -> CapturedTextInsertionTarget
    func replaceSelection(
        _ selection: CapturedTextSelection,
        with replacement: String
    ) async throws -> TextReplacementReceipt?
    func insert(
        _ text: String,
        at target: CapturedTextInsertionTarget
    ) async throws
    func replaceAppliedText(
        _ receipt: TextReplacementReceipt,
        with replacement: String
    ) throws -> TextReplacementReceipt
    func undo(_ receipt: TextReplacementReceipt) throws
}

extension SelectedTextEditing {
    func captureInsertionTarget() throws -> CapturedTextInsertionTarget {
        throw AppError.commandFailed(
            "WisprLocal couldn’t safely retain this cursor. Nothing was inserted."
        )
    }

    func insert(
        _ text: String,
        at target: CapturedTextInsertionTarget
    ) async throws {
        throw AppError.commandFailed(
            "WisprLocal couldn’t safely retain this cursor. Nothing was inserted."
        )
    }
}

@MainActor
final class SystemSelectedTextEditor: SelectedTextEditing {
    typealias ClipboardDelay = @MainActor () async -> Void

    private struct SelectionContext {
        let element: AXUIElement
        let processID: pid_t
        let text: String
        let selectedRange: CFRange?
    }

    private struct ReplacementContext {
        let element: AXUIElement
        let processID: pid_t
        let originalText: String
        let replacementText: String
        let replacementRange: CFRange
    }

    private struct InsertionContext {
        let element: AXUIElement
        let processID: pid_t
        let caretRange: CFRange
    }

    private let pasteboard: PasteboardAccessing
    private let eventPoster: KeyboardEventPosting
    private let accessibilityAuthorizer: AccessibilityAuthorizing
    private let injector: TextInjecting
    private let clipboardDelay: ClipboardDelay
    private var selections: [UUID: SelectionContext] = [:]
    private var replacements: [UUID: ReplacementContext] = [:]
    private var insertionTargets: [UUID: InsertionContext] = [:]
    private var pendingInsertionTarget: CapturedTextInsertionTarget?

    convenience init() {
        self.init(injector: TextInjector())
    }

    convenience init(injector: TextInjecting) {
        self.init(
            pasteboard: SystemPasteboard(),
            eventPoster: SystemKeyboardEventPoster(),
            accessibilityAuthorizer: SystemAccessibilityAuthorizer(),
            injector: injector
        )
    }

    init(
        pasteboard: PasteboardAccessing,
        eventPoster: KeyboardEventPosting,
        accessibilityAuthorizer: AccessibilityAuthorizing,
        injector: TextInjecting,
        clipboardDelay: @escaping ClipboardDelay = {
            try? await Task.sleep(nanoseconds: 120_000_000)
        }
    ) {
        self.pasteboard = pasteboard
        self.eventPoster = eventPoster
        self.accessibilityAuthorizer = accessibilityAuthorizer
        self.injector = injector
        self.clipboardDelay = clipboardDelay
    }

    func captureSelection() async throws -> CapturedTextSelection {
        guard accessibilityAuthorizer.ensureAccessibility() else {
            throw AppError.accessibilityDenied
        }
        guard let element = focusedElement() else {
            throw AppError.noTextSelected
        }
        let processID = processID(of: element)
        if let caretRange = selectedRange(of: element), caretRange.length == 0 {
            pendingInsertionTarget = rememberInsertionTarget(
                element: element,
                processID: processID,
                caretRange: caretRange
            )
        } else {
            pendingInsertionTarget = nil
            insertionTargets.removeAll()
        }

        if let selectedText = selectedText(of: element),
           selectedText.trimmedOrNil != nil {
            pendingInsertionTarget = nil
            insertionTargets.removeAll()
            return rememberSelection(
                element: element,
                processID: processID,
                text: selectedText,
                selectedRange: selectedRange(of: element)
            )
        }

        guard let clipboardText = try await selectedTextUsingClipboard(),
              clipboardText.trimmedOrNil != nil else {
            throw AppError.noTextSelected
        }
        pendingInsertionTarget = nil
        insertionTargets.removeAll()
        return rememberSelection(
            element: element,
            processID: processID,
            text: clipboardText,
            selectedRange: selectedRange(of: element)
        )
    }

    func captureInsertionTarget() throws -> CapturedTextInsertionTarget {
        if let pendingInsertionTarget {
            self.pendingInsertionTarget = nil
            return pendingInsertionTarget
        }
        guard accessibilityAuthorizer.ensureAccessibility() else {
            throw AppError.accessibilityDenied
        }
        guard let element = focusedElement(),
              let caretRange = selectedRange(of: element),
              caretRange.length == 0 else {
            throw AppError.commandFailed(
                "WisprLocal couldn’t safely retain this cursor. Nothing was inserted."
            )
        }

        return rememberInsertionTarget(
            element: element,
            processID: processID(of: element),
            caretRange: caretRange
        )
    }

    func replaceSelection(
        _ selection: CapturedTextSelection,
        with replacement: String
    ) async throws -> TextReplacementReceipt? {
        guard let context = selections.removeValue(forKey: selection.id),
              context.processID == selection.applicationProcessID,
              context.text == selection.text else {
            throw AppError.selectedTextChanged
        }
        try validateFocusedTarget(
            context.element,
            processID: context.processID,
            error: .selectedTextChanged
        )

        let currentSelection: String?
        if let directText = selectedText(of: context.element),
           directText.trimmedOrNil != nil {
            currentSelection = directText
        } else {
            currentSelection = try await selectedTextUsingClipboard()
        }
        guard currentSelection == context.text,
              selectionRangeMatches(context.selectedRange, on: context.element) else {
            throw AppError.selectedTextChanged
        }

        let replacedDirectly = isAttributeSettable(
            kAXSelectedTextAttribute as CFString,
            on: context.element
        ) && AXUIElementSetAttributeValue(
            context.element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFTypeRef
        ) == .success

        if !replacedDirectly {
            try await injector.insert(
                text: replacement,
                pressEnter: false,
                validatingTarget: { [weak self] in
                    guard let self else { throw AppError.selectedTextChanged }
                    try self.validateFocusedTarget(
                        context.element,
                        processID: context.processID,
                        error: .selectedTextChanged
                    )
                    guard self.selectionRangeMatches(
                        context.selectedRange,
                        on: context.element
                    ) else {
                        throw AppError.selectedTextChanged
                    }
                }
            )
        }

        guard let originalRange = context.selectedRange else { return nil }
        let replacementRange = CFRange(
            location: originalRange.location,
            length: (replacement as NSString).length
        )
        guard value(at: replacementRange, in: context.element) == replacement else {
            return nil
        }
        return rememberReplacement(
            element: context.element,
            processID: context.processID,
            originalText: context.text,
            replacementText: replacement,
            replacementRange: replacementRange
        )
    }

    func insert(
        _ text: String,
        at target: CapturedTextInsertionTarget
    ) async throws {
        guard let context = insertionTargets.removeValue(forKey: target.id),
              context.processID == target.applicationProcessID else {
            throw AppError.commandTargetChanged
        }
        if pendingInsertionTarget?.id == target.id {
            pendingInsertionTarget = nil
        }

        let validateTarget = { [weak self] in
            guard let self else { throw AppError.commandTargetChanged }
            try self.validateFocusedTarget(
                context.element,
                processID: context.processID,
                error: .commandTargetChanged
            )
            guard let currentRange = self.selectedRange(of: context.element),
                  currentRange.location == context.caretRange.location,
                  currentRange.length == context.caretRange.length else {
                throw AppError.commandTargetChanged
            }
        }
        try validateTarget()

        let insertedDirectly = isAttributeSettable(
            kAXSelectedTextAttribute as CFString,
            on: context.element
        ) && AXUIElementSetAttributeValue(
            context.element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success

        if !insertedDirectly {
            try await injector.insert(
                text: text,
                pressEnter: false,
                validatingTarget: validateTarget
            )
        }
    }

    func replaceAppliedText(
        _ receipt: TextReplacementReceipt,
        with replacement: String
    ) throws -> TextReplacementReceipt {
        guard let context = replacements[receipt.id] else {
            throw AppError.transformUndoUnavailable
        }
        try validateRetainedTarget(context.element, processID: context.processID)
        guard value(at: context.replacementRange, in: context.element) == context.replacementText else {
            throw AppError.selectedTextChanged
        }

        try replaceText(
            in: context.element,
            range: context.replacementRange,
            with: replacement
        )
        replacements.removeValue(forKey: receipt.id)
        let newRange = CFRange(
            location: context.replacementRange.location,
            length: (replacement as NSString).length
        )
        return rememberReplacement(
            element: context.element,
            processID: context.processID,
            originalText: context.originalText,
            replacementText: replacement,
            replacementRange: newRange
        )
    }

    func undo(_ receipt: TextReplacementReceipt) throws {
        guard let context = replacements[receipt.id] else {
            throw AppError.transformUndoUnavailable
        }
        try validateRetainedTarget(context.element, processID: context.processID)
        guard value(at: context.replacementRange, in: context.element) == context.replacementText else {
            throw AppError.selectedTextChanged
        }
        try replaceText(
            in: context.element,
            range: context.replacementRange,
            with: context.originalText
        )
        replacements.removeValue(forKey: receipt.id)
    }

    private func rememberSelection(
        element: AXUIElement,
        processID: pid_t,
        text: String,
        selectedRange: CFRange?
    ) -> CapturedTextSelection {
        let id = UUID()
        selections = [
            id: SelectionContext(
                element: element,
                processID: processID,
                text: text,
                selectedRange: selectedRange
            )
        ]
        return CapturedTextSelection(
            id: id,
            text: text,
            applicationProcessID: processID
        )
    }

    private func rememberInsertionTarget(
        element: AXUIElement,
        processID: pid_t,
        caretRange: CFRange
    ) -> CapturedTextInsertionTarget {
        let id = UUID()
        insertionTargets = [
            id: InsertionContext(
                element: element,
                processID: processID,
                caretRange: caretRange
            )
        ]
        return CapturedTextInsertionTarget(
            id: id,
            applicationProcessID: processID
        )
    }

    private func rememberReplacement(
        element: AXUIElement,
        processID: pid_t,
        originalText: String,
        replacementText: String,
        replacementRange: CFRange
    ) -> TextReplacementReceipt {
        let id = UUID()
        let context = ReplacementContext(
            element: element,
            processID: processID,
            originalText: originalText,
            replacementText: replacementText,
            replacementRange: replacementRange
        )
        replacements = [id: context]
        return TextReplacementReceipt(
            id: id,
            originalText: originalText,
            replacementText: replacementText,
            applicationProcessID: processID
        )
    }

    private func selectedTextUsingClipboard() async throws -> String? {
        guard let snapshot = pasteboard.snapshot() else {
            throw AppError.selectionCaptureUnavailable
        }
        let previousChangeCount = pasteboard.changeCount
        eventPoster.postCopy()
        await clipboardDelay()
        guard pasteboard.changeCount != previousChangeCount else { return nil }

        let copiedChangeCount = pasteboard.changeCount
        let text = pasteboard.readString()
        _ = pasteboard.restore(snapshot, ifChangeCountMatches: copiedChangeCount)
        return text
    }

    private func validateFocusedTarget(
        _ expectedElement: AXUIElement,
        processID: pid_t,
        error: AppError
    ) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID,
              let currentElement = focusedElement(),
              CFEqual(currentElement, expectedElement) else {
            throw error
        }
    }

    private func validateRetainedTarget(
        _ element: AXUIElement,
        processID expectedProcessID: pid_t
    ) throws {
        guard processID(of: element) == expectedProcessID,
              NSRunningApplication(processIdentifier: expectedProcessID) != nil else {
            throw AppError.transformUndoUnavailable
        }
    }

    private func replaceText(
        in element: AXUIElement,
        range: CFRange,
        with replacement: String
    ) throws {
        guard isAttributeSettable(kAXSelectedTextRangeAttribute as CFString, on: element),
              isAttributeSettable(kAXSelectedTextAttribute as CFString, on: element) else {
            throw AppError.transformUndoUnavailable
        }
        var mutableRange = range
        guard let rangeValue = AXValueCreate(.cfRange, &mutableRange),
              AXUIElementSetAttributeValue(
                  element,
                  kAXSelectedTextRangeAttribute as CFString,
                  rangeValue
              ) == .success,
              AXUIElementSetAttributeValue(
                  element,
                  kAXSelectedTextAttribute as CFString,
                  replacement as CFTypeRef
              ) == .success else {
            throw AppError.transformUndoUnavailable
        }
    }

    private func focusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func processID(of element: AXUIElement) -> pid_t {
        var processID: pid_t = 0
        AXUIElementGetPid(element, &processID)
        return processID
    }

    private func selectedText(of element: AXUIElement) -> String? {
        copyAttribute(kAXSelectedTextAttribute as CFString, from: element) as? String
    }

    private func selectedRange(of element: AXUIElement) -> CFRange? {
        guard let rawValue = copyAttribute(
            kAXSelectedTextRangeAttribute as CFString,
            from: element
        ), CFGetTypeID(rawValue) == AXValueGetTypeID() else {
            return nil
        }
        let value = rawValue as! AXValue
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return range
    }

    private func selectionRangeMatches(
        _ expectedRange: CFRange?,
        on element: AXUIElement
    ) -> Bool {
        guard let expectedRange else { return true }
        guard let currentRange = selectedRange(of: element) else { return false }
        return currentRange.location == expectedRange.location
            && currentRange.length == expectedRange.length
    }

    private func value(at range: CFRange, in element: AXUIElement) -> String? {
        guard let text = copyAttribute(kAXValueAttribute as CFString, from: element) as? String,
              range.location >= 0,
              range.length >= 0,
              range.location + range.length <= (text as NSString).length else {
            return nil
        }
        return (text as NSString).substring(
            with: NSRange(location: range.location, length: range.length)
        )
    }

    private func copyAttribute(
        _ attribute: CFString,
        from element: AXUIElement
    ) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value
    }

    private func isAttributeSettable(
        _ attribute: CFString,
        on element: AXUIElement
    ) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute, &settable) == .success
            && settable.boolValue
    }
}
