import AppKit
import Combine

@MainActor
final class HUDWindowController {
    private struct ObserverToken {
        let center: NotificationCenter
        let token: NSObjectProtocol
    }

    private let window: NSPanel
    private let contentView = HUDContentView(frame: .zero)
    private var cancellables = Set<AnyCancellable>()
    private var observers: [ObserverToken] = []
    private let idleWindowSize = NSSize(width: 60, height: 15)
    private let activeWindowSize = NSSize(width: 76, height: 20)
    private let bottomPadding: CGFloat = 10
    private let mouseBottomProximity: CGFloat = 6
    private let positionAnimationDuration: TimeInterval = 0.18
    private let positionDeltaThreshold: CGFloat = 0.5
    private let appState: AppState
    private let dictationController: DictationController

    init(appState: AppState, dictationController: DictationController) {
        self.appState = appState
        self.dictationController = dictationController
        window = NSPanel(contentRect: NSRect(origin: .zero, size: idleWindowSize),
                         styleMask: [.nonactivatingPanel, .borderless],
                         backing: .buffered,
                         defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = contentView
        window.setContentSize(idleWindowSize)
        window.contentMinSize = idleWindowSize
        window.contentMaxSize = idleWindowSize

        contentView.onPillClick = { [weak self] in
            self?.handlePillClick()
        }
        contentView.onStopClick = { [weak self] in
            self?.handleStopClick()
        }

        appState.$state
            .sink { [weak self] state in
                self?.update(for: state)
            }
            .store(in: &cancellables)

        appState.$hotkeyDisplay
            .sink { [weak self] value in
                self?.contentView.setHotkeyDisplay(value)
            }
            .store(in: &cancellables)

        let appCenter = NotificationCenter.default
        let screenToken = appCenter.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            print("[HUD] didChangeScreenParametersNotification fired")
            Task { @MainActor in self?.handleScreenChange() }
        }
        observers.append(ObserverToken(center: appCenter, token: screenToken))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let spaceToken = workspaceCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            print("[HUD] activeSpaceDidChangeNotification fired")
            Task { @MainActor in self?.handleScreenChange() }
        }
        observers.append(ObserverToken(center: workspaceCenter, token: spaceToken))

        handleScreenChange(size: idleWindowSize)
        window.orderFrontRegardless()
    }

    deinit {
        observers.forEach { $0.center.removeObserver($0.token) }
    }

    private func update(for state: AppState.State) {
        updateWindowSize(for: state)
        switch state {
        case .idle:
            contentView.setStyle(.idle)
            contentView.setText("")
        case .listening:
            contentView.setStyle(.listening)
            contentView.setText("")
        case .transcribing:
            contentView.setStyle(.transcribing)
            contentView.setText("Transcribing…")
        case .error(let message):
            contentView.setStyle(.error)
            contentView.setText("Error: \(message)")
        }
        contentView.setStopButtonVisible(state == .listening && appState.listeningStartedFromHUD)
    }

    private func updateWindowSize(for state: AppState.State) {
        let targetSize: NSSize
        switch state {
        case .idle, .error:
            targetSize = idleWindowSize
        case .listening, .transcribing:
            targetSize = activeWindowSize
        }
        if window.contentView?.frame.size != targetSize {
            window.setContentSize(targetSize)
            window.contentMinSize = targetSize
            window.contentMaxSize = targetSize
            positionWindow(for: targetSize)
        }
    }

    private func positionWindow(for size: NSSize? = nil) {
        // Determine the active screen based on mouse location first, then fall back to the window's screen, then main.
        let mousePoint = NSEvent.mouseLocation
        print("[HUD] mousePoint=\(mousePoint)")
        let screenUnderMouse = NSScreen.screens.first { NSMouseInRect(mousePoint, $0.frame, false) }
        let activeScreen = screenUnderMouse ?? window.screen ?? NSScreen.main
        guard let screen = activeScreen else { return }
        print("[HUD] activeScreen.frame=\(screen.frame) visibleFrame=\(screen.visibleFrame)")

        let visibleFrame = screen.visibleFrame
        let fullFrame = screen.frame
        let insets = screen.safeAreaInsets
        let safeFrame = NSRect(
            x: fullFrame.minX + insets.left,
            y: fullFrame.minY + insets.bottom,
            width: fullFrame.width - (insets.left + insets.right),
            height: fullFrame.height - (insets.top + insets.bottom)
        )
        let target = size ?? window.frame.size
        print("[HUD] targetSize=\(target) x=\(safeFrame.midX - (target.width / 2))")

        let x = safeFrame.midX - (target.width / 2)

        let dockPosition = DockUtils.shared.getDockPosition(screen: screen)
        print("[HUD] dockPosition=\(dockPosition)")

        // Default position is relative to the screen's full frame bottom with padding
        var y = safeFrame.minY + bottomPadding
        var lifted = false

        let isFullscreenSpace = (visibleFrame.minY == fullFrame.minY)
        print("[HUD] isFullscreenSpace=\(isFullscreenSpace)")

        if !isFullscreenSpace {
            // Not fullscreen: anchor above the Dock/menu area using visibleFrame bottom
            y = max(visibleFrame.minY, safeFrame.minY) + bottomPadding
            lifted = true
            print("[HUD] non-fullscreen: anchoring to visibleFrame.minY -> y=\(y)")
        } else if dockPosition == .bottom {
            // Fullscreen space: lift when mouse is near the bottom edge to avoid temporary Dock overlay
            let inScreen = NSMouseInRect(mousePoint, fullFrame, false)
            let nearBottom = mousePoint.y <= fullFrame.minY + mouseBottomProximity
            print("[HUD] fullscreen: inScreen=\(inScreen) nearBottom=\(nearBottom) threshold=\(fullFrame.minY + mouseBottomProximity)")
            if inScreen && nearBottom {
                y = max(visibleFrame.minY, safeFrame.minY) + bottomPadding + 2
                lifted = true
            }
        }

        let rect = NSRect(x: x, y: y, width: target.width, height: target.height)
        print("[HUD] computed rect=\(rect) lifted=\(lifted)")

        let current = window.frame
        let deltaX = abs(current.origin.x - rect.origin.x)
        let deltaY = abs(current.origin.y - rect.origin.y)
        let deltaW = abs(current.size.width - rect.size.width)
        let deltaH = abs(current.size.height - rect.size.height)
        let moved = deltaX > positionDeltaThreshold || deltaY > positionDeltaThreshold
        let resized = deltaW > positionDeltaThreshold || deltaH > positionDeltaThreshold
        print("[HUD] deltas dx=\(deltaX) dy=\(deltaY) dw=\(deltaW) dh=\(deltaH) moved=\(moved) resized=\(resized)")
        guard moved || resized else {
            print("[HUD] skip animation: below threshold")
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = positionAnimationDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            print("[HUD] animating to rect=\(rect) duration=\(context.duration)")
            window.animator().setFrame(rect, display: false)
        }
    }

    private func handleScreenChange(size: NSSize? = nil) {
        positionWindow(for: size)
    }

    private func handlePillClick() {
        switch appState.state {
        case .idle, .error:
            dictationController.startRecording(source: .hud)
        default:
            break
        }
    }

    private func handleStopClick() {
        if appState.state == .listening {
            dictationController.stopAndTranscribe()
        }
    }
}

private final class HUDContentView: NSView {
    enum Style {
        case idle
        case listening
        case transcribing
        case error
    }

    private let dotView = NSView(frame: .zero)
    private let textField = NSTextField(labelWithString: "")
    private let hoverTextField = NSTextField(labelWithString: "Start Dictating?")
    private let spinner = NSProgressIndicator()
    private let waveView = WaveformBarsView(frame: .zero)
    private let stopButton = NSButton(frame: .zero)
    private let tooltipView = TooltipBubbleView(frame: .zero)
    private let tooltipPanel: NSPanel
    private var tooltipSize = NSSize(width: 200, height: 26)

    private var style: Style = .idle
    private var hotkeyDisplay: String = "fn"
    private var isHovering = false
    private var isInLayout = false
    private var showsStopButton = false
    private let backgroundLayer = CALayer()
    var onPillClick: (() -> Void)?
    var onStopClick: (() -> Void)?
    private let contentPadding: CGFloat = 6
    private let elementSpacing: CGFloat = 4
    private let maxWaveWidth: CGFloat = 40

    override init(frame frameRect: NSRect) {
        tooltipPanel = NSPanel(contentRect: NSRect(origin: .zero, size: tooltipSize),
                               styleMask: [.nonactivatingPanel, .borderless],
                               backing: .buffered,
                               defer: false)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(backgroundLayer)
        backgroundLayer.cornerRadius = frameRect.height / 2
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        backgroundLayer.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        backgroundLayer.borderWidth = 1

        dotView.wantsLayer = true
        dotView.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
        dotView.layer?.cornerRadius = 4
        dotView.layer?.shadowColor = NSColor.systemBlue.withAlphaComponent(0.6).cgColor
        dotView.layer?.shadowRadius = 6
        dotView.layer?.shadowOpacity = 1
        dotView.layer?.shadowOffset = .zero

        textField.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        textField.textColor = .white
        textField.lineBreakMode = .byTruncatingTail

        hoverTextField.font = NSFont.systemFont(ofSize: 11, weight: .regular)
        hoverTextField.textColor = NSColor.white.withAlphaComponent(0.9)
        hoverTextField.isHidden = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        stopButton.isBordered = false
        stopButton.title = ""
        if let baseImage = NSImage(systemSymbolName: "stop.fill", accessibilityDescription: "Stop Dictation") {
            let config = NSImage.SymbolConfiguration(pointSize: 6, weight: .bold, scale: .small)
            stopButton.image = baseImage.withSymbolConfiguration(config)
        }
        stopButton.imageScaling = .scaleProportionallyDown
        stopButton.contentTintColor = .white
        stopButton.focusRingType = .none
        stopButton.imagePosition = .imageOnly
        stopButton.wantsLayer = true
        stopButton.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.95).cgColor
        stopButton.layer?.cornerRadius = 6
        stopButton.layer?.shadowColor = NSColor.black.withAlphaComponent(0.4).cgColor
        stopButton.layer?.shadowOpacity = 1
        stopButton.layer?.shadowRadius = 3
        stopButton.layer?.shadowOffset = .zero
        stopButton.target = self
        stopButton.action = #selector(stopButtonClicked)
        stopButton.isHidden = true

        addSubview(dotView)
        addSubview(textField)
        addSubview(spinner)
        addSubview(waveView)
        addSubview(stopButton)
        tooltipPanel.isOpaque = false
        tooltipPanel.backgroundColor = .clear
        tooltipPanel.hasShadow = true
        tooltipPanel.level = .statusBar
        tooltipPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        tooltipPanel.contentView = tooltipView
        tooltipPanel.setContentSize(tooltipSize)

        waveView.isHidden = true
        spinner.stopAnimation(nil)
        tooltipView.isHidden = false
        tooltipPanel.orderOut(nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverState()
    }

    override func mouseDown(with event: NSEvent) {
        onPillClick?()
    }

    override func layout() {
        isInLayout = true
        super.layout()
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = bounds.height / 2

        let dotSize: CGFloat = isHovering ? 5 : 4
        let dotX = contentPadding
        dotView.frame = NSRect(x: dotX, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
        dotView.layer?.cornerRadius = dotSize / 2

        let leadingX = dotX + dotSize + elementSpacing
        spinner.frame = NSRect(x: leadingX, y: (bounds.height - 10) / 2, width: 10, height: 10)

        let stopSize: CGFloat = 10
        let rightInset = contentPadding
        let stopX = bounds.width - rightInset - stopSize
        let waveAvailable: CGFloat
        if showsStopButton {
            waveAvailable = max(0, stopX - elementSpacing - leadingX)
        } else {
            waveAvailable = max(0, bounds.width - rightInset - leadingX)
        }
        let waveWidth = min(maxWaveWidth, waveAvailable)
        waveView.frame = NSRect(x: leadingX, y: (bounds.height - 10) / 2, width: waveWidth, height: 10)
        stopButton.frame = NSRect(x: stopX, y: (bounds.height - stopSize) / 2, width: stopSize, height: stopSize)
        stopButton.layer?.cornerRadius = stopSize / 2

        let textX: CGFloat = 22
        let textWidth = max(0, bounds.width - textX - 4)
        textField.frame = NSRect(x: textX, y: (bounds.height - 10) / 2, width: textWidth, height: 10)
        hoverTextField.frame = NSRect(x: 0, y: 0, width: 0, height: 0)
        isInLayout = false
    }

    func setStyle(_ newStyle: Style) {
        style = newStyle
        switch newStyle {
        case .idle:
            backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            waveView.isHidden = true
            waveView.stop()
        case .listening:
            backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            waveView.isHidden = false
            waveView.start()
        case .transcribing:
            backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.85).cgColor
            spinner.isHidden = false
            spinner.startAnimation(nil)
            waveView.isHidden = true
            waveView.stop()
        case .error:
            backgroundLayer.backgroundColor = NSColor.systemRed.withAlphaComponent(0.85).cgColor
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            waveView.isHidden = true
            waveView.stop()
        }
        updateHoverState()
    }

    func setText(_ text: String) {
        textField.stringValue = text
        textField.alignment = .center
    }

    func setHotkeyDisplay(_ value: String) {
        hotkeyDisplay = value
        if isHovering && style == .idle {
            hoverTextField.stringValue = "Click or hold \(hotkeyDisplay) to start dictating"
            tooltipView.setLabel(hoverTextField.stringValue, highlight: hotkeyDisplay)
            tooltipSize = tooltipView.preferredSize()
            showTooltip()
        }
    }

    private func updateHoverState() {
        if style == .idle && isHovering {
            hoverTextField.stringValue = "Click or hold \(hotkeyDisplay) to start dictating"
            tooltipView.setLabel(hoverTextField.stringValue, highlight: hotkeyDisplay)
            showTooltip()
        } else {
            tooltipPanel.orderOut(nil)
        }
        if !isInLayout {
            needsLayout = true
        }
    }

    private func showTooltip() {
        guard let window = self.window else { return }
        let base = window.frame
        let x = base.midX - (tooltipSize.width / 2)
        let y = base.maxY + 6
        tooltipPanel.setContentSize(tooltipSize)
        tooltipPanel.setFrame(NSRect(x: x, y: y, width: tooltipSize.width, height: tooltipSize.height), display: false)
        tooltipPanel.orderFrontRegardless()
    }

    func setStopButtonVisible(_ visible: Bool) {
        showsStopButton = visible
        stopButton.isHidden = !visible
        if !isInLayout {
            needsLayout = true
        }
    }


    @objc private func stopButtonClicked() {
        onStopClick?()
    }
}

private final class TooltipBubbleView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let backgroundLayer = CALayer()
    private let horizontalPadding: CGFloat = 6
    private let verticalPadding: CGFloat = 3
    private var isInLayout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(backgroundLayer)
        backgroundLayer.cornerRadius = 14
        backgroundLayer.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
        backgroundLayer.borderColor = NSColor.white.withAlphaComponent(0.2).cgColor
        backgroundLayer.borderWidth = 1

        label.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        label.textColor = NSColor.white.withAlphaComponent(0.9)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        isInLayout = true
        super.layout()
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: horizontalPadding, dy: verticalPadding)
        isInLayout = false
    }

    func setLabel(_ text: String, highlight: String) {
        let baseFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let highlightFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraph
        ])
        let range = (text as NSString).range(of: highlight)
        if range.location != NSNotFound {
            attributed.addAttributes([
                .foregroundColor: NSColor(calibratedRed: 0.98, green: 0.52, blue: 0.93, alpha: 1.0),
                .font: highlightFont,
                .paragraphStyle: paragraph
            ], range: range)
        }
        label.attributedStringValue = attributed
        if !isInLayout {
            needsLayout = true
        }
    }

    func preferredSize() -> NSSize {
        let textSize = label.attributedStringValue.size()
        return NSSize(width: textSize.width + horizontalPadding * 2,
                      height: textSize.height + verticalPadding * 2)
    }
}

private final class WaveformBarsView: NSView {
    private var timer: Timer?
    private let barCount = 9
    private var heights: [CGFloat] = []
    private var phase: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        heights = Array(repeating: 4, count: barCount)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.white.setFill()
        let spacing: CGFloat = 2
        let totalSpacing = CGFloat(barCount - 1) * spacing
        let barWidth = (bounds.width - totalSpacing) / CGFloat(barCount)
        for index in 0..<barCount {
            let x = CGFloat(index) * (barWidth + spacing)
            let height = heights[index]
            let y = (bounds.height - height) / 2
            let rect = NSRect(x: x, y: y, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            path.fill()
        }
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        heights = Array(repeating: 4, count: barCount)
        needsDisplay = true
    }

    private func step() {
        phase += 0.28
        for i in 0..<barCount {
            let offset = CGFloat(i) * 0.6
            let value = (sin(phase + offset) + 1) / 2
            heights[i] = 4 + value * 8
        }
        needsDisplay = true
    }
}

