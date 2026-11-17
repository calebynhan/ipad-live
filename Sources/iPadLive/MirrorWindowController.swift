import AppKit
import iPadLiveCore

/// The main window: a chrome-free window that is just the iPad picture, so it looks clean when
/// shared in Zoom, Google Meet or FaceTime.
///
/// - The close/minimise/zoom buttons fade out unless the pointer is over the window.
/// - Drag anywhere to move it; double-click to go full screen.
/// - The window keeps the iPad's shape and reshapes itself when the iPad rotates.
@MainActor
final class MirrorWindowController: NSWindowController, NSWindowDelegate {

    private let mirror: MirrorSession
    private let rootView = RootView(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
    private let mirrorView: MirrorView
    private let overlay = StatusOverlayView(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
    private let hintView = HintView(frame: .zero)
    private var hintTimer: Timer?
    private var cursorTimer: Timer?
    private var isHovering = false
    private(set) var isFullScreen = false

    private static let frameAutosaveName = "iPadLiveMirrorWindow"

    init(mirror: MirrorSession) {
        self.mirror = mirror
        self.mirrorView = MirrorView(session: mirror.session)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)

        setUpViews()
        setUpWindow(window)
        applyAppearanceSettings()

        mirror.onStateChange = { [weak self] state in self?.render(state) }
        mirror.onVideoSizeChange = { [weak self] size in self?.videoSizeChanged(size) }
        render(mirror.state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: - Setup

    private func setUpWindow(_ window: NSWindow) {
        window.title = "iPad Live" // what Zoom/Meet/FaceTime list in their window pickers
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 240, height: 240)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.tabbingMode = .disallowed
        window.isRestorable = false
        window.delegate = self
        window.contentView = rootView
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        _ = window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    private func setUpViews() {
        mirrorView.frame = rootView.bounds
        mirrorView.autoresizingMask = [.width, .height]
        rootView.addSubview(mirrorView)

        overlay.frame = rootView.bounds
        overlay.autoresizingMask = [.width, .height]
        rootView.addSubview(overlay)

        hintView.translatesAutoresizingMaskIntoConstraints = false
        hintView.isHidden = true
        rootView.addSubview(hintView)
        let hintInset = hintView.leadingAnchor.constraint(greaterThanOrEqualTo: rootView.leadingAnchor, constant: 12)
        hintInset.priority = .init(490) // never let the hint force the window to grow
        NSLayoutConstraint.activate([
            hintView.centerXAnchor.constraint(equalTo: rootView.centerXAnchor),
            hintView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -20),
            hintInset,
        ])

        rootView.onHoverChange = { [weak self] hovering in self?.hoverChanged(hovering) }
        rootView.onMouseMoved = { [weak self] in self?.pointerMoved() }
        rootView.onDoubleClick = { [weak self] in self?.window?.toggleFullScreen(nil) }
    }

    // MARK: - Reacting to the capture session

    private func render(_ state: MirrorSession.State) {
        hintTimer?.invalidate()
        hintView.isHidden = true

        switch state {
        case .starting:
            overlay.show(.init(symbolName: "ipad.landscape", title: "Starting…", message: "", showsSpinner: true))

        case .needsCameraPermission(denied: false):
            overlay.show(.init(
                symbolName: "lock.shield",
                title: "Allow Camera Access",
                message: "macOS treats a plugged-in iPad's screen like a camera, so it will ask for Camera permission. "
                    + "Click Allow. Your Mac's own camera is never turned on.",
                showsSpinner: true
            ))

        case .needsCameraPermission(denied: true):
            overlay.show(.init(
                symbolName: "lock.shield",
                title: "Camera Access Is Off",
                message: "macOS treats a plugged-in iPad's screen like a camera. Turn on iPad Live in "
                    + "System Settings → Privacy & Security → Camera. Your Mac's own camera is never turned on.",
                buttonTitle: "Open Privacy Settings",
                buttonAction: { MirrorWindowController.openCameraPrivacySettings() }
            ))

        case .waitingForDevice:
            overlay.show(.init(
                symbolName: "cable.connector",
                title: "Connect Your iPad",
                message: "Plug your iPad into this Mac with a USB cable and unlock it.\n"
                    + "If your iPad asks “Trust This Computer?”, tap Trust.",
                showsSpinner: true
            ))

        case .connecting(let name):
            overlay.show(.init(
                symbolName: "ipad.landscape",
                title: "Connecting to \(name)…",
                message: "Keep your iPad unlocked.",
                showsSpinner: true
            ))

        case .live:
            overlay.hide()
            scheduleBlackScreenHint()

        case .failed(let message):
            overlay.show(.init(
                symbolName: "exclamationmark.triangle",
                title: "Couldn't Show Your iPad",
                message: message + "\n\nIt will try again in a moment. Unplugging and replugging the cable often helps.",
                buttonTitle: "Try Again",
                buttonAction: { [weak self] in self?.mirror.reconnect() }
            ))
        }
        updateTitlebarButtons()
    }

    private func videoSizeChanged(_ size: CGSize?) {
        mirrorView.videoSize = size
        guard size != nil else { return }
        hintView.isHidden = true
        applyAspectRatio()
        if Settings.lockAspectRatio {
            fitWindowToVideo(animated: true)
        }
    }

    /// If the session is running but no picture format has arrived after a few seconds,
    /// the iPad is most likely locked.
    private func scheduleBlackScreenHint() {
        hintTimer?.invalidate()
        hintTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard case .live = self.mirror.state, self.mirror.videoSize == nil else { return }
                self.hintView.text = "Waiting for the picture… make sure your iPad is unlocked."
                self.hintView.isHidden = false
            }
        }
    }

    // MARK: - Window shape

    var canFitWindow: Bool { mirror.videoSize != nil && !isFullScreen }

    /// Reshape the window to the iPad's shape, keeping about the same size and position.
    func fitWindowToVideo(animated: Bool) {
        guard let window, !isFullScreen, let size = mirror.videoSize else { return }
        let visible = MirrorGeometry.visibleVideoSize(videoSize: size, hideStatusBar: Settings.hideStatusBar)
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
        let maxSize = CGSize(width: screenFrame.width * 0.95, height: screenFrame.height * 0.95)
        let newSize = MirrorGeometry.fittedSize(
            aspect: visible,
            preservingAreaOf: window.frame.size,
            maxSize: maxSize,
            minSize: window.minSize
        )
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let newFrame = MirrorGeometry.centeredFrame(size: newSize, around: center, within: screenFrame)

        let current = window.frame
        let unchanged = abs(newFrame.minX - current.minX) < 1 && abs(newFrame.minY - current.minY) < 1
            && abs(newFrame.width - current.width) < 1 && abs(newFrame.height - current.height) < 1
        if !unchanged {
            window.setFrame(newFrame, display: true, animate: animated && window.isVisible)
        }
    }

    private func applyAspectRatio() {
        guard let window else { return }
        if Settings.lockAspectRatio, !isFullScreen, let size = mirror.videoSize {
            let visible = MirrorGeometry.visibleVideoSize(videoSize: size, hideStatusBar: Settings.hideStatusBar)
            window.aspectRatio = NSSize(width: visible.width, height: visible.height)
        } else {
            window.resizeIncrements = NSSize(width: 1, height: 1) // clears any aspect-ratio lock
        }
    }

    // MARK: - Menu commands (called by AppDelegate)

    func toggleLockAspectRatio() {
        Settings.lockAspectRatio.toggle()
        applyAspectRatio()
        if Settings.lockAspectRatio { fitWindowToVideo(animated: true) }
    }

    func toggleHideStatusBar() {
        Settings.hideStatusBar.toggle()
        mirrorView.hideStatusBar = Settings.hideStatusBar
        applyAspectRatio()
        if Settings.lockAspectRatio { fitWindowToVideo(animated: true) }
    }

    func toggleFloatOnTop() {
        Settings.floatOnTop.toggle()
        applyAppearanceSettings()
    }

    func setBackground(_ style: BackgroundStyle) {
        Settings.background = style
        applyAppearanceSettings()
    }

    private func applyAppearanceSettings() {
        window?.level = Settings.floatOnTop ? .floating : .normal
        window?.backgroundColor = Settings.background.color
        mirrorView.fillColor = Settings.background.color
        mirrorView.hideStatusBar = Settings.hideStatusBar
    }

    static func openCameraPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Pointer and title bar buttons

    private func hoverChanged(_ hovering: Bool) {
        isHovering = hovering
        if !hovering { cursorTimer?.invalidate() }
        updateTitlebarButtons()
    }

    /// Hide the Mac pointer when it rests over the iPad picture, so it doesn't sit in the shared screen.
    private func pointerMoved() {
        cursorTimer?.invalidate()
        guard case .live = mirror.state else { return }
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                if self.isHovering { NSCursor.setHiddenUntilMouseMoves(true) }
            }
        }
    }

    private func updateTitlebarButtons() {
        let isLive: Bool
        if case .live = mirror.state { isLive = true } else { isLive = false }
        let visible = !isLive || isHovering || isFullScreen
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window?.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillEnterFullScreen(_ notification: Notification) {
        isFullScreen = true
        window?.resizeIncrements = NSSize(width: 1, height: 1)
        updateTitlebarButtons()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
        applyAspectRatio()
        if Settings.lockAspectRatio { fitWindowToVideo(animated: false) }
        updateTitlebarButtons()
    }
}

/// The window's content view. Reports hover and lets you drag the window from anywhere.
final class RootView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    var onMouseMoved: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}
