import AppKit
import LiveLink
import SystemConfiguration

/// The Mac end of Wi-Fi streaming: listens for paired iPads (iPad Live Sender), runs pairing, and
/// feeds received frames to the same instant-display path the cable's Low-Latency Mode uses.
///
/// `MirrorSession` decides when Wi-Fi is the window's source (the cable always wins) via `setActive`.
@MainActor
final class WirelessController {

    enum PairingEvent: Sendable {
        /// An iPad asks to pair: show its name and code, and ask the person to compare with the iPad.
        /// Pass `id` to `confirmPairing(requestID:)`, so Pair only ever applies to the request on screen.
        case request(id: UUID, deviceName: String, code: String)
        /// The iPad asking to pair went away or cancelled; still waiting for one.
        case requestEnded
        case paired(deviceName: String)
        case failed(String)
    }

    // Always called on the main thread.
    var onStreamStarted: ((_ deviceName: String) -> Void)?
    var onStreamEnded: (() -> Void)?
    /// Displayed size (after rotation) and clockwise quarter turns.
    var onVideoInfo: ((CGSize, Int) -> Void)?

    /// The experimental Wi-Fi feature is switched on (see `Settings.wirelessFeature`).
    var isAvailable: Bool { Settings.wirelessFeature }
    var isEnabled: Bool { Settings.wirelessEnabled }
    var isPaired: Bool { !Settings.wirelessDevices.isEmpty }

    private let frameSink: FrameSink
    private var streamServer: LiveLinkStreamServer?
    private var pairingServer: LiveLinkPairingServer?
    private var pairingHandler: ((PairingEvent) -> Void)?
    private var isActive = false
    private var isStreaming = false

    init(frameSink: FrameSink) {
        self.frameSink = frameSink
        frameSink.onExternalNeedsKeyframe = { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.streamServer?.send(.requestKeyframe) }
            }
        }
    }

    func start() {
        restartStreamServer()
    }

    func stop() {
        streamServer?.stop()
        streamServer = nil
        cancelPairing()
    }

    func setEnabled(_ enabled: Bool) {
        Settings.wirelessEnabled = enabled
        restartStreamServer()
    }

    /// Wi-Fi frames are shown only while it's the window's source. Otherwise the iPad is told to
    /// pause, so it doesn't spend battery and Wi-Fi on frames nobody sees.
    func setActive(_ active: Bool) {
        isActive = active
        frameSink.setAcceptsExternal(active)
        guard isStreaming, let server = streamServer else { return }
        server.send(active ? .resume : .pause)
        if active { server.send(.requestKeyframe) }
    }

    /// Every paired iPad loses access; each must pair again.
    func forgetPairedDevices() {
        Settings.wirelessDevices = []
        restartStreamServer()
    }

    // MARK: - Pairing

    /// Opens pairing. `onEvent` reports requests and the outcome; it isn't called after `cancelPairing()`.
    func beginPairing(onEvent: @escaping (PairingEvent) -> Void) {
        cancelPairing()
        guard isAvailable else {
            onEvent(.failed("Wi-Fi streaming is turned off."))
            return
        }
        if !Settings.wirelessEnabled {
            Settings.wirelessEnabled = true
            restartStreamServer()
        }

        let server = LiveLinkPairingServer(macID: Settings.wirelessMacID, macName: Self.computerName, advertise: true)
        let serverID = ObjectIdentifier(server)
        server.onRequest = { @Sendable request in
            let event = PairingEvent.request(id: request.id, deviceName: request.deviceName, code: request.code)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.pairingEvent(serverID, event) }
            }
        }
        server.onRequestEnded = { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.pairingEvent(serverID, .requestEnded) }
            }
        }
        server.onPaired = { @Sendable device in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.paired(device, serverID: serverID) }
            }
        }
        server.onListenerFailed = { @Sendable error in
            let message = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.pairingEvent(serverID, .failed(message)) }
            }
        }
        pairingServer = server
        pairingHandler = onEvent
        server.start()
    }

    /// The person checked the codes match and clicked Pair, for the request with this ID.
    func confirmPairing(requestID: UUID) {
        pairingServer?.confirm(requestID: requestID)
    }

    func cancelPairing() {
        pairingServer?.stop()
        pairingServer = nil
        pairingHandler = nil
    }

    private func paired(_ device: PairedDevice, serverID: ObjectIdentifier) {
        guard let server = pairingServer, ObjectIdentifier(server) == serverID else { return }
        Settings.wirelessDevices.append(device)
        restartStreamServer() // the new iPad's key must be accepted
        let handler = pairingHandler
        pairingServer = nil
        pairingHandler = nil
        // Let the result reach the iPad before closing the connection.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { server.stop() }
        handler?(.paired(deviceName: device.name))
    }

    private func pairingEvent(_ serverID: ObjectIdentifier, _ event: PairingEvent) {
        guard let server = pairingServer, ObjectIdentifier(server) == serverID else { return }
        if case .failed = event { cancelPairing() }
        pairingHandler?(event)
    }

    // MARK: - Streaming

    private func restartStreamServer() {
        streamServer?.stop()
        streamServer = nil
        if isStreaming {
            isStreaming = false
            onStreamEnded?()
        }
        let devices = Settings.wirelessDevices
        // Cable-only unless the experimental Wi-Fi feature is on: no listener, no network use at all.
        guard isAvailable, Settings.wirelessEnabled, !devices.isEmpty else { return }

        let server = LiveLinkStreamServer(devices: devices, macID: Settings.wirelessMacID)
        let serverID = ObjectIdentifier(server)
        let sink = frameSink
        server.onFrame = { @Sendable sampleBuffer in
            sink.enqueueExternal(sampleBuffer) // straight to the display queue; no main-thread hop
        }
        server.onVideoInfo = { @Sendable width, height, orientation in
            let turns = VideoOrientation.clockwiseQuarterTurns(forOrientation: orientation)
            let size = turns % 2 == 1
                ? CGSize(width: height, height: width)
                : CGSize(width: width, height: height)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let current = self.streamServer, ObjectIdentifier(current) == serverID else { return }
                    self.onVideoInfo?(size, turns)
                }
            }
        }
        server.onStreamStarted = { @Sendable name in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.streamStarted(name, serverID: serverID) }
            }
        }
        server.onStreamEnded = { @Sendable in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.streamEnded(serverID: serverID) }
            }
        }
        server.onListenerFailed = { @Sendable error in
            NSLog("iPad Live: the Wi-Fi listener stopped: %@", String(describing: error))
        }
        streamServer = server
        server.start()
    }

    private func streamStarted(_ deviceName: String, serverID: ObjectIdentifier) {
        guard let server = streamServer, ObjectIdentifier(server) == serverID else { return }
        isStreaming = true
        server.send(isActive ? .resume : .pause)
        if isActive { server.send(.requestKeyframe) }
        onStreamStarted?(deviceName)
    }

    private func streamEnded(serverID: ObjectIdentifier) {
        guard let server = streamServer, ObjectIdentifier(server) == serverID, isStreaming else { return }
        isStreaming = false
        onStreamEnded?()
    }

    /// The name people gave this Mac (System Settings → General → Sharing), shown on the iPad.
    private static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}
