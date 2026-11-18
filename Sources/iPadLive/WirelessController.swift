import AppKit
import LiveLink
import SystemConfiguration

/// The Mac end of Wi-Fi streaming: listens for the paired iPad (iPad Live Sender), runs pairing,
/// and feeds received frames to the same instant-display path the cable's Low-Latency Mode uses.
///
/// `MirrorSession` decides when Wi-Fi is the window's source (the cable always wins) via `setActive`.
@MainActor
final class WirelessController {

    enum PairingOutcome: Sendable {
        case paired(deviceName: String)
        case tooManyAttempts
        case failed(String)
    }

    // Always called on the main thread.
    var onStreamStarted: ((_ deviceName: String) -> Void)?
    var onStreamEnded: (() -> Void)?
    /// Displayed size (after rotation) and clockwise quarter turns.
    var onVideoInfo: ((CGSize, Int) -> Void)?

    var isEnabled: Bool { Settings.wirelessEnabled }
    var isPaired: Bool { Settings.wirelessStreamKey != nil }

    private let frameSink: FrameSink
    private var streamServer: LiveLinkStreamServer?
    private var pairingServer: LiveLinkPairingServer?
    private var pairingHandler: ((PairingOutcome) -> Void)?
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

    func forgetPairedDevices() {
        Settings.wirelessStreamKey = nil
        restartStreamServer()
    }

    // MARK: - Pairing

    /// Opens pairing and returns the code to show. `onFinished` is called once on success, or if
    /// pairing gives up; not if `cancelPairing()` is called first.
    func beginPairing(onFinished: @escaping (PairingOutcome) -> Void) -> String {
        cancelPairing()
        if !Settings.wirelessEnabled { Settings.wirelessEnabled = true }
        let streamKey: Data
        if let existing = Settings.wirelessStreamKey {
            streamKey = existing
        } else {
            streamKey = LiveLinkSecurity.makeStreamKey()
            Settings.wirelessStreamKey = streamKey
        }
        restartStreamServerIfNeeded()

        let code = LiveLinkSecurity.makePairingCode()
        let server = LiveLinkPairingServer(
            code: code,
            macID: Settings.wirelessMacID,
            macName: Self.computerName,
            streamKey: streamKey,
            advertise: true
        )
        let serverID = ObjectIdentifier(server)
        server.onPaired = { @Sendable name in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishPairing(serverID, .paired(deviceName: name)) }
            }
        }
        server.onFailedAttempt = { @Sendable count in
            guard count >= 5 else { return } // a few typos are fine; guessing isn't
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishPairing(serverID, .tooManyAttempts) }
            }
        }
        server.onListenerFailed = { @Sendable error in
            let message = error.localizedDescription
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishPairing(serverID, .failed(message)) }
            }
        }
        pairingServer = server
        pairingHandler = onFinished
        server.start()
        return code
    }

    func cancelPairing() {
        pairingServer?.stop()
        pairingServer = nil
        pairingHandler = nil
    }

    private func finishPairing(_ serverID: ObjectIdentifier, _ outcome: PairingOutcome) {
        guard let server = pairingServer, ObjectIdentifier(server) == serverID else { return }
        pairingServer = nil
        let handler = pairingHandler
        pairingHandler = nil
        // Give the pairing reply a moment to reach the iPad before closing everything.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { server.stop() }
        handler?(outcome)
    }

    // MARK: - Streaming

    private func restartStreamServerIfNeeded() {
        if streamServer == nil { restartStreamServer() }
    }

    private func restartStreamServer() {
        streamServer?.stop()
        streamServer = nil
        if isStreaming {
            isStreaming = false
            onStreamEnded?()
        }
        guard Settings.wirelessEnabled, let streamKey = Settings.wirelessStreamKey else { return }

        let server = LiveLinkStreamServer(streamKey: streamKey, macID: Settings.wirelessMacID)
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
