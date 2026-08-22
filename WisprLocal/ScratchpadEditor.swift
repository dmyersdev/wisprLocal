import AppKit
import SwiftUI

struct ScratchpadTransformTarget {
    struct AttachmentToken {
        let marker: String
        let content: NSAttributedString
    }

    let noteID: UUID
    let range: NSRange
    let originalContent: NSAttributedString
    let promptText: String
    let attachments: [AttachmentToken]
}

@MainActor
final class ScratchpadEditorBridge: ObservableObject {
    @Published private(set) var selectionRange = NSRange(location: 0, length: 0)
    @Published private(set) var hasSelection = false
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private weak var textView: NSTextView?

    func attach(_ textView: NSTextView) {
        self.textView = textView
        scheduleStateUpdate(from: textView)
    }

    func detach(_ textView: NSTextView) {
        guard self.textView === textView else { return }
        self.textView = nil
        Task { [weak self] in
            await Task.yield()
            guard let self, self.textView == nil else { return }
            self.selectionRange = NSRange(location: 0, length: 0)
            self.hasSelection = false
            self.canUndo = false
            self.canRedo = false
        }
    }

    func focus() {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
    }

    func updateState(from textView: NSTextView) {
        selectionRange = textView.selectedRange()
        hasSelection = selectionRange.length > 0
        canUndo = textView.undoManager?.canUndo ?? false
        canRedo = textView.undoManager?.canRedo ?? false
    }

    func scheduleStateUpdate(from textView: NSTextView) {
        Task { [weak self, weak textView] in
            await Task.yield()
            guard let self, let textView, self.textView === textView else { return }
            self.updateState(from: textView)
        }
    }

    func undo() {
        textView?.undoManager?.undo()
        if let textView { updateState(from: textView) }
    }

    func redo() {
        textView?.undoManager?.redo()
        if let textView { updateState(from: textView) }
    }

    func toggleBold() {
        toggleFontTrait(.boldFontMask)
    }

    func toggleItalic() {
        toggleFontTrait(.italicFontMask)
    }

    func toggleUnderline() {
        guard let textView else { return }
        let range = effectiveFormattingRange(in: textView)
        let storage = textView.textStorage
        var shouldUnderline = true
        if range.length > 0,
           let value = storage?.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int {
            shouldUnderline = value == 0
        }
        if range.length == 0 {
            var attributes = textView.typingAttributes
            attributes[.underlineStyle] = shouldUnderline ? NSUnderlineStyle.single.rawValue : 0
            textView.typingAttributes = attributes
        } else {
            storage?.addAttribute(
                .underlineStyle,
                value: shouldUnderline ? NSUnderlineStyle.single.rawValue : 0,
                range: range
            )
            textView.didChangeText()
        }
    }

    func toggleBulletList() {
        guard let textView else { return }
        let string = textView.string as NSString
        let selected = textView.selectedRange()
        let lineRange = string.lineRange(for: selected)
        let lines = string.substring(with: lineRange)
            .components(separatedBy: .newlines)
        let nonTrailingLines = lines.last == "" ? Array(lines.dropLast()) : lines
        let allBulleted = !nonTrailingLines.isEmpty && nonTrailingLines.allSatisfy {
            $0.hasPrefix("• ")
        }
        let replacement = nonTrailingLines.map { line in
            if allBulleted {
                return line.hasPrefix("• ") ? String(line.dropFirst(2)) : line
            }
            return line.hasPrefix("• ") ? line : "• \(line)"
        }.joined(separator: "\n") + (lines.last == "" ? "\n" : "")
        textView.insertText(replacement, replacementRange: lineRange)
    }

    func addLink(_ url: URL) {
        guard let textView, textView.selectedRange().length > 0 else { return }
        textView.textStorage?.addAttribute(
            .link,
            value: url,
            range: textView.selectedRange()
        )
        textView.didChangeText()
    }

    func insertPlainText(_ text: String) throws {
        guard let textView else { throw ScratchpadError.noActiveNote }
        textView.insertText(text, replacementRange: textView.selectedRange())
        textView.scrollRangeToVisible(textView.selectedRange())
        updateState(from: textView)
    }

    func copyAll() throws {
        guard let textView else { throw ScratchpadError.noActiveNote }
        let content = NSAttributedString(attributedString: textView.attributedString())
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.string]
        if let rtfd = try? ScratchpadDocumentCodec.encode(content) {
            types.append(.rtfd)
            pasteboard.declareTypes(types, owner: nil)
            pasteboard.setData(rtfd, forType: .rtfd)
        } else {
            pasteboard.declareTypes(types, owner: nil)
        }
        pasteboard.setString(content.string, forType: .string)
    }

    func captureTransformTarget(noteID: UUID) throws -> ScratchpadTransformTarget {
        guard let textView else { throw ScratchpadError.noActiveNote }
        let selected = textView.selectedRange()
        let targetRange = selected.length > 0
            ? selected
            : NSRange(location: 0, length: textView.attributedString().length)
        let content = textView.attributedString().attributedSubstring(from: targetRange)
        var promptText = ""
        var attachments: [ScratchpadTransformTarget.AttachmentToken] = []
        var cursor = 0
        content.enumerateAttributes(
            in: NSRange(location: 0, length: content.length)
        ) { attributes, range, _ in
            if attributes[.attachment] != nil {
                let marker = "[[WISPRLOCAL_IMAGE_\(attachments.count + 1)]]"
                promptText.append(marker)
                attachments.append(
                    .init(
                        marker: marker,
                        content: content.attributedSubstring(from: range)
                    )
                )
            } else {
                promptText.append((content.string as NSString).substring(with: range))
            }
            cursor = NSMaxRange(range)
        }
        if cursor < content.length {
            promptText.append(
                (content.string as NSString).substring(
                    from: cursor
                )
            )
        }
        return ScratchpadTransformTarget(
            noteID: noteID,
            range: targetRange,
            originalContent: content,
            promptText: promptText,
            attachments: attachments
        )
    }

    func applyTransform(
        _ transformedText: String,
        target: ScratchpadTransformTarget,
        currentNoteID: UUID
    ) throws {
        guard let textView, currentNoteID == target.noteID else {
            throw AppError.selectedTextChanged
        }
        let fullContent = textView.attributedString()
        guard NSMaxRange(target.range) <= fullContent.length,
              fullContent.attributedSubstring(from: target.range).isEqual(
                to: target.originalContent
              ) else {
            throw AppError.selectedTextChanged
        }

        let replacement = try attributedReplacement(
            from: transformedText,
            attachments: target.attachments,
            typingAttributes: textView.typingAttributes
        )
        textView.textStorage?.replaceCharacters(in: target.range, with: replacement)
        let newRange = NSRange(
            location: target.range.location + replacement.length,
            length: 0
        )
        textView.setSelectedRange(newRange)
        textView.didChangeText()
        updateState(from: textView)
    }

    private func attributedReplacement(
        from transformedText: String,
        attachments: [ScratchpadTransformTarget.AttachmentToken],
        typingAttributes: [NSAttributedString.Key: Any]
    ) throws -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        var remaining = transformedText[...]
        for attachment in attachments {
            guard let markerRange = remaining.range(of: attachment.marker) else {
                throw AppError.transformFailed("The transform did not preserve note images.")
            }
            let prefix = String(remaining[..<markerRange.lowerBound])
            result.append(NSAttributedString(string: prefix, attributes: typingAttributes))
            result.append(attachment.content)
            remaining = remaining[markerRange.upperBound...]
        }
        result.append(NSAttributedString(string: String(remaining), attributes: typingAttributes))
        return result
    }

    private func toggleFontTrait(_ trait: NSFontTraitMask) {
        guard let textView else { return }
        let range = effectiveFormattingRange(in: textView)
        let fontManager = NSFontManager.shared
        if range.length == 0 {
            var attributes = textView.typingAttributes
            let font = attributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 16)
            let hasTrait = fontManager.traits(of: font).contains(trait)
            attributes[.font] = hasTrait
                ? fontManager.convert(font, toNotHaveTrait: trait)
                : fontManager.convert(font, toHaveTrait: trait)
            textView.typingAttributes = attributes
            return
        }
        textView.textStorage?.enumerateAttribute(.font, in: range) { value, subrange, _ in
            let font = value as? NSFont ?? NSFont.systemFont(ofSize: 16)
            let hasTrait = fontManager.traits(of: font).contains(trait)
            let converted = hasTrait
                ? fontManager.convert(font, toNotHaveTrait: trait)
                : fontManager.convert(font, toHaveTrait: trait)
            textView.textStorage?.addAttribute(.font, value: converted, range: subrange)
        }
        textView.didChangeText()
    }

    private func effectiveFormattingRange(in textView: NSTextView) -> NSRange {
        let selected = textView.selectedRange()
        guard selected.length == 0 else { return selected }
        return NSRange(location: selected.location, length: 0)
    }
}

struct ScratchpadRichTextEditor: NSViewRepresentable {
    @Binding var content: NSAttributedString
    @ObservedObject var bridge: ScratchpadEditorBridge
    let onChange: (NSAttributedString) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isRichText = true
        textView.importsGraphics = true
        textView.allowsImageEditing = true
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.usesFindPanel = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 28, height: 24)
        textView.typingAttributes = [
            .font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor.labelColor
        ]
        textView.textStorage?.setAttributedString(content)

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = textView
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = context.coordinator
        bridge.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        guard !context.coordinator.isApplyingTextChange,
              !textView.attributedString().isEqual(to: content) else { return }
        context.coordinator.isApplyingExternalContent = true
        let selection = textView.selectedRange()
        textView.textStorage?.setAttributedString(content)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(
            NSRange(
                location: min(selection.location, content.length),
                length: 0
            )
        )
        context.coordinator.isApplyingExternalContent = false
        bridge.scheduleStateUpdate(from: textView)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        coordinator.parent.bridge.detach(textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ScratchpadRichTextEditor
        var isApplyingExternalContent = false
        var isApplyingTextChange = false
        private var isRevertingInvalidEdit = false

        init(parent: ScratchpadRichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingExternalContent,
                  !isRevertingInvalidEdit,
                  let textView = notification.object as? NSTextView else { return }
            let value = NSAttributedString(attributedString: textView.attributedString())
            do {
                try ScratchpadDocumentCodec.validateAttachments(in: value)
            } catch {
                isRevertingInvalidEdit = true
                textView.undoManager?.undo()
                isRevertingInvalidEdit = false
                parent.onError(error.localizedDescription)
                return
            }
            isApplyingTextChange = true
            parent.content = value
            parent.onChange(value)
            isApplyingTextChange = false
            parent.bridge.updateState(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingExternalContent,
                  let textView = notification.object as? NSTextView else { return }
            parent.bridge.updateState(from: textView)
        }
    }
}
