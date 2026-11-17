@preconcurrency import AVFoundation
import CoreMedia

/// Owns the capture session that pulls the iPad's screen over USB, and keeps it connected:
/// it waits for an iPad, connects as soon as one appears, notices when it's unplugged,
/// and retries after errors. All UI-facing state lives on the main thread; the capture
/// session itself is configured on a background queue so the window never stutters.
@MainActor
final class MirrorSession {

    enum State: Equatable {
        case starting
        case needsCameraPermission(denied: Bool)
        case waitingForDevice
        case connecting(deviceName: String)
        case live(deviceName: String)
        case failed(message: String)
    }

    // UI callbacks. Always called on the main thread.
    var onStateChange: ((State) -> Void)?
    var onVideoSizeChange: ((CGSize?) -> Void)?
    var onDevicesChange: (() -> Void)?
    var onAudioPermissionDenied: (() -> Void)?
    /// Which picture path the window should show: `previewAttached` connects Apple's standard
    /// preview layer; `lowLatencyLayerVisible` shows Low-Latency Mode's layer (drawn on top).
    var onRenderStateChange: ((_ previewAttached: Bool, _ lowLatencyLayerVisible: Bool) -> Void)?

    private(set) var state: State = .starting {
        didSet { if state != oldValue { onStateChange?(state) } }
    }

    /// Pixel size of the picture the iPad is sending. Changes when the iPad rotates.
    private(set) var videoSize: CGSize? {
        didSet { if videoSize != oldValue { onVideoSizeChange?(videoSize) } }
    }

    private(set) var devices: [AVCaptureDevice] = []
    private(set) var activeDevice: AVCaptureDevice?

    let session = AVCaptureSession()
    /// Draws frames for Low-Latency Mode. Its layer lives in the window.
    let frameSink = FrameSink()

    private let sessionQueue = DispatchQueue(label: "app.ipadlive.capture-session", qos: .userInteractive)
    /// Created on first use, which is after `ScreenCaptureDevices.enable()` has run in `start()`.
    private lazy var discovery = ScreenCaptureDevices.makeDiscoverySession()
    private var currentInput: AVCaptureDeviceInput?
    /// A frame size that arrived while still connecting; applied once the connection is live.
    private var pendingFrameSize: CGSize?
    /// Bumped on every connect/disconnect so results from an older attempt are ignored.
    private var generation = 0
    /// After a failure, keep the error on screen for a moment before retrying automatically.
    private var retryNotBefore: Date?
    private var requestedCameraAccess = false
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?

    // MARK: - Lifecycle

    init() {
        frameSink.onSizeChange = { size in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.frameSizeChanged(size) }
            }
        }
    }

    func start() {
        ScreenCaptureDevices.enable()
        observeNotifications()

        // Device and rotation notifications do the real work; this light poll is a safety net
        // so nothing gets stuck if a notification is missed.
        let timer = Timer(timeInterval: 1.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        evaluate()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        generation += 1
        let session = self.session
        sessionQueue.sync { Self.teardown(session) }
    }

    // MARK: - User actions

    func select(deviceID: String) {
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) else { return }
        Settings.lastDeviceID = deviceID
        if activeDevice?.uniqueID == deviceID, case .live = state { return }
        retryNotBefore = nil
        connect(to: device)
    }

    func reconnect() {
        retryNotBefore = nil
        if activeDevice != nil { disconnect() }
        evaluate()
    }

    var lowLatency: Bool { Settings.lowLatency }

    /// Low-Latency Mode: frames go through `FrameSink` and are shown the instant they arrive.
    /// Off: the standard `AVCaptureVideoPreviewLayer`, kept so the two can be compared.
    func setLowLatency(_ on: Bool) {
        guard on != Settings.lowLatency else { return }
        Settings.lowLatency = on
        guard currentInput != nil else {
            publishRenderState() // nothing on screen yet; the next connection uses the new mode
            return
        }
        // Switch without a blank moment: keep the current picture up until the other path
        // has a fresh frame. (The iPad only sends frames when its screen changes.)
        let attempt = generation
        if on {
            frameSink.notifyOnNextFrame {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if attempt == self.generation, Settings.lowLatency { self.publishRenderState() }
                    }
                }
            }
            applyVideoOutput()
        } else {
            onRenderStateChange?(true, true) // standard preview attached underneath, low-latency still on top
            refreshVideoSize()
            frameSink.notifyOnNextFrame(after: 0.3) { // give the preview time to connect
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if attempt == self.generation, !Settings.lowLatency {
                            self.publishRenderState()
                            self.applyVideoOutput() // now remove the low-latency output
                        }
                    }
                }
            }
        }
    }

    /// Tells the window to show the picture path for the current setting.
    private func publishRenderState() {
        onRenderStateChange?(!Settings.lowLatency, Settings.lowLatency)
    }

    var playsAudio: Bool { Settings.playsAudio }

    func setPlaysAudio(_ on: Bool) {
        Settings.playsAudio = on
        guard on else {
            applyAudioSetting()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            applyAudioSetting()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if granted {
                            self.applyAudioSetting()
                        } else {
                            Settings.playsAudio = false
                            self.onAudioPermissionDenied?()
                        }
                    }
                }
            }
        default:
            Settings.playsAudio = false
            onAudioPermissionDenied?()
        }
    }

    // MARK: - Deciding what to do

    /// Works out what should be happening right now and makes it so. Safe to call at any time.
    private func evaluate() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            state = .needsCameraPermission(denied: false)
            requestCameraAccess()
            return
        default:
            if activeDevice != nil { disconnect() }
            state = .needsCameraPermission(denied: true)
            return
        }

        let found = ScreenCaptureDevices.connectedDevices(using: discovery)
        if found.map(\.uniqueID) != devices.map(\.uniqueID) {
            devices = found
            retryNotBefore = nil // something was plugged in or out: worth trying again straight away
            onDevicesChange?()
        }

        if let active = activeDevice {
            if found.contains(where: { $0.uniqueID == active.uniqueID }) { return }
            disconnect() // unplugged
        }

        if let notBefore = retryNotBefore, Date() < notBefore { return }
        retryNotBefore = nil

        if let device = preferredDevice(in: found) {
            connect(to: device)
        } else {
            state = .waitingForDevice
        }
    }

    private func tick() {
        evaluate()
        refreshVideoSize()
        if case .live = state, !session.isRunning {
            fail(with: "The connection to your iPad was interrupted.")
        }
    }

    private func preferredDevice(in devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if let id = Settings.lastDeviceID, let device = devices.first(where: { $0.uniqueID == id }) {
            return device
        }
        return devices.first { $0.localizedName.localizedCaseInsensitiveContains("iPad") } ?? devices.first
    }

    private func requestCameraAccess() {
        guard !requestedCameraAccess else { return }
        requestedCameraAccess = true
        AVCaptureDevice.requestAccess(for: .video) { _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.evaluate() }
            }
        }
    }

    // MARK: - Connecting

    private func connect(to device: AVCaptureDevice) {
        generation += 1
        let attempt = generation
        activeDevice = device
        currentInput = nil
        pendingFrameSize = nil
        videoSize = nil
        Settings.lastDeviceID = device.uniqueID
        state = .connecting(deviceName: device.localizedName)

        let session = self.session
        let withAudio = wantsAudio
        let sink = Settings.lowLatency ? frameSink : nil
        sessionQueue.async {
            let (result, videoOutputAdded) = Self.configure(session, with: device, audio: withAudio, frameSink: sink)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.finishConnecting(
                        attempt: attempt,
                        device: device,
                        result: result,
                        usedFrameSink: sink != nil,
                        videoOutputAdded: videoOutputAdded
                    )
                }
            }
        }
    }

    private func finishConnecting(
        attempt: Int,
        device: AVCaptureDevice,
        result: Result<AVCaptureDeviceInput, Error>,
        usedFrameSink: Bool,
        videoOutputAdded: Bool
    ) {
        guard attempt == generation else { return } // a newer connect/disconnect happened meanwhile
        switch result {
        case .success(let input):
            currentInput = input
            state = .live(deviceName: device.localizedName)
            if usedFrameSink && !videoOutputAdded {
                lowLatencyUnavailable()
            } else if usedFrameSink != Settings.lowLatency {
                applyVideoOutput() // Low-Latency Mode was toggled while connecting
            }
            if Settings.lowLatency, let size = pendingFrameSize {
                videoSize = size
            }
            pendingFrameSize = nil
            refreshVideoSize()
        case .failure(let error):
            fail(with: error.localizedDescription)
        }
    }

    private func fail(with message: String) {
        disconnect()
        retryNotBefore = Date().addingTimeInterval(4)
        state = .failed(message: message)
    }

    private func disconnect() {
        generation += 1
        activeDevice = nil
        currentInput = nil
        pendingFrameSize = nil
        videoSize = nil
        frameSink.reset()
        publishRenderState() // drop any half-finished mode switch
        let session = self.session
        sessionQueue.async { Self.teardown(session) }
    }

    /// Adds the low-latency video output if Low-Latency Mode is on, removes it if it's off.
    private func applyVideoOutput() {
        guard currentInput != nil else { return } // applied on the next connect instead
        let session = self.session
        let on = Settings.lowLatency
        let sink = on ? frameSink : nil
        let attempt = generation
        sessionQueue.async {
            let added = Self.setVideoOutput(sink, in: session)
            if on && !added {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        if attempt == self.generation { self.lowLatencyUnavailable() }
                    }
                }
            }
        }
    }

    /// If the session refuses the video data output, fall back to the standard picture path.
    private func lowLatencyUnavailable() {
        NSLog("iPad Live: Low-Latency Mode isn't available for this device; using the standard picture path.")
        guard Settings.lowLatency else { return }
        Settings.lowLatency = false
        publishRenderState()
        refreshVideoSize()
    }

    // MARK: - Video size (changes when the iPad rotates)

    /// Low-Latency Mode reads the size from the frames themselves (see `frameSizeChanged`).
    private func refreshVideoSize() {
        guard !Settings.lowLatency, let input = currentInput else { return }
        if let size = Self.videoSize(of: input) {
            videoSize = size
        }
    }

    private func frameSizeChanged(_ size: CGSize) {
        guard Settings.lowLatency, activeDevice != nil else { return } // stale frame after unplugging
        if currentInput == nil {
            pendingFrameSize = size // first frames can beat the "connected" callback
        } else {
            videoSize = size
        }
    }

    nonisolated private static func videoSize(of input: AVCaptureDeviceInput) -> CGSize? {
        for port in input.ports where port.mediaType == .video {
            if let description = port.formatDescription {
                let dims = CMVideoFormatDescriptionGetDimensions(description)
                if dims.width > 0, dims.height > 0 {
                    return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
                }
            }
        }
        let description = input.device.activeFormat.formatDescription
        if CMFormatDescriptionGetMediaType(description) == kCMMediaType_Video {
            let dims = CMVideoFormatDescriptionGetDimensions(description)
            if dims.width > 0, dims.height > 0 {
                return CGSize(width: CGFloat(dims.width), height: CGFloat(dims.height))
            }
        }
        return nil
    }

    // MARK: - Audio

    private var wantsAudio: Bool {
        Settings.playsAudio && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    private func applyAudioSetting() {
        guard currentInput != nil else { return }
        let session = self.session
        let on = wantsAudio
        sessionQueue.async { Self.setAudio(on, in: session) }
    }

    // MARK: - Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default
        // Names are spelled out so they work across SDKs that renamed the Swift constants.
        for name in ["AVCaptureDeviceWasConnectedNotification", "AVCaptureDeviceWasDisconnectedNotification"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.evaluate() }
            })
        }
        observers.append(center.addObserver(
            forName: Notification.Name("AVCaptureInputPortFormatDescriptionDidChangeNotification"),
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { self.refreshVideoSize() }
        })
        observers.append(center.addObserver(
            forName: Notification.Name("AVCaptureSessionRuntimeErrorNotification"),
            object: session,
            queue: .main
        ) { note in
            let error = note.userInfo?["AVCaptureSessionErrorKey"] as? NSError
            let message = error?.localizedDescription ?? "The connection to your iPad was interrupted."
            MainActor.assumeIsolated {
                if self.activeDevice != nil { self.fail(with: message) }
            }
        })
    }

    // MARK: - Capture session work (runs on sessionQueue)

    /// Returns the connection result, and whether the low-latency video output was added.
    nonisolated private static func configure(
        _ session: AVCaptureSession,
        with device: AVCaptureDevice,
        audio: Bool,
        frameSink: FrameSink?
    ) -> (Result<AVCaptureDeviceInput, Error>, Bool) {
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        let result: Result<AVCaptureDeviceInput, Error>
        var videoOutputAdded = false
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw MirrorSetupError(
                    errorDescription: "Couldn't open \(device.localizedName). If another app is showing it, quit that app and try again."
                )
            }
            session.addInput(input)
            if let frameSink { videoOutputAdded = addVideoOutput(to: session, sink: frameSink) }
            if audio { addAudioOutput(to: session) }
            result = .success(input)
        } catch {
            result = .failure(error)
        }
        session.commitConfiguration()

        if case .success = result, !session.isRunning {
            session.startRunning() // blocks until frames start flowing, hence the background queue
        }
        return (result, videoOutputAdded)
    }

    nonisolated private static func teardown(_ session: AVCaptureSession) {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()
    }

    nonisolated private static func setAudio(_ on: Bool, in session: AVCaptureSession) {
        let existing = session.outputs.compactMap { $0 as? AVCaptureAudioPreviewOutput }
        session.beginConfiguration()
        if on {
            if existing.isEmpty { addAudioOutput(to: session) }
        } else {
            existing.forEach { session.removeOutput($0) }
        }
        session.commitConfiguration()
    }

    /// Adds or removes the low-latency video output on a running session.
    nonisolated private static func setVideoOutput(_ sink: FrameSink?, in session: AVCaptureSession) -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for output in session.outputs where output is AVCaptureVideoDataOutput {
            session.removeOutput(output)
        }
        guard let sink else { return true }
        return addVideoOutput(to: session, sink: sink)
    }

    nonisolated private static func addVideoOutput(to session: AVCaptureSession, sink: FrameSink) -> Bool {
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true // newest frame wins; never build up a backlog
        output.setSampleBufferDelegate(sink, queue: sink.queue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        return true
    }

    /// Plays the iPad's sound through the Mac's current output device.
    nonisolated private static func addAudioOutput(to session: AVCaptureSession) {
        let output = AVCaptureAudioPreviewOutput()
        output.volume = 1
        if session.canAddOutput(output) { session.addOutput(output) }
    }
}

struct MirrorSetupError: LocalizedError {
    let errorDescription: String?
}
