import AppKit
import Combine

@MainActor
final class TransformStatusWindowController {
    private let panel: NSPanel
    private let messageLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView(frame: .zero)
    private let spinner = NSProgressIndicator(frame: .zero)
    private let transformController: TransformController
    private var cancellables = Set<AnyCancellable>()
    private var hideTask: Task<Void, Never>?

    init(appState: AppState, transformController: TransformController) {
        self.transformController = transformController
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 54),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        configurePanel()

        appState.$transformFeedbackMessage
            .sink { [weak self] message in
                self?.present(message)
            }
            .store(in: &cancellables)
    }

    deinit {
        hideTask?.cancel()
    }

    private func configurePanel() {
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let effect = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.borderWidth = 1
        effect.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = .labelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: 13, weight: .medium)
        messageLabel.textColor = .labelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [spinner, iconView, messageLabel])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)

        NSLayoutConstraint.activate([
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: effect.centerYAnchor)
        ])

        panel.contentView = effect
    }

    private func present(_ message: String?) {
        hideTask?.cancel()
        guard let message, !message.isEmpty else {
            panel.orderOut(nil)
            return
        }

        messageLabel.stringValue = message
        let isProcessing: Bool
        switch transformController.state {
        case .processing:
            isProcessing = true
            iconView.isHidden = true
            spinner.startAnimation(nil)
        case .error:
            isProcessing = false
            setIcon("exclamationmark.circle.fill", color: .systemRed)
        case .success:
            isProcessing = false
            setIcon("checkmark.circle.fill", color: .systemGreen)
        case .unchanged:
            isProcessing = false
            setIcon("checkmark.circle", color: .systemGreen)
        case .idle:
            isProcessing = false
            setIcon("info.circle.fill", color: .secondaryLabelColor)
        }

        positionPanel()
        panel.orderFrontRegardless()

        if !isProcessing {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        }
    }

    private func setIcon(_ symbol: String, color: NSColor) {
        spinner.stopAnimation(nil)
        iconView.isHidden = false
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iconView.contentTintColor = color
    }

    private func positionPanel() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first {
            NSMouseInRect(mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        guard let visibleFrame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + 76
        ))
    }
}
