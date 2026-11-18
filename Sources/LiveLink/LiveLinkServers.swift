import CoreMedia
import Foundation
import Network

/// Mac side: accepts the paired iPad's stream and turns it into `CMSampleBuffer`s.
///
/// Only paired iPads, each with its own stream key, get past the TLS handshake. One stream at a
/// time: a new stream (e.g. the iPad restarted its broadcast) replaces the old one.
/// All callbacks arrive on `queue`.
public final class LiveLinkStreamServer: @unchecked Sendable {

    public let queue = DispatchQueue(label: "app.ipadlive.wireless.stream", qos: .userInteractive)

    public var onListening: ((NWEndpoint.Port) -> Void)?
    public var onListenerFailed: ((Error) -> Void)?
    public var onStreamStarted: ((_ deviceName: String) -> Void)?
    public var onStreamEnded: (() -> Void)?
    /// The encoded size and orientation, whenever either changes.
    public var onVideoInfo: ((_ width: Int, _ height: Int, _ orientation: UInt8) -> Void)?
    public var onFrame: ((CMSampleBuffer) -> Void)?

    private let parameters: NWParameters
    private let service: NWListener.Service?
    private let port: NWEndpoint.Port
    private var listener: NWListener?
    private var stream: LiveLinkConnection?
    private var assembler = SampleBufferAssembler()
    private var lastInfo: (width: Int, height: Int, orientation: UInt8)?

    /// - Parameter devices: the paired iPads; each authenticates with its own key.
    /// - Parameter macID: advertised over Bonjour so paired iPads can find this Mac; `nil` to not advertise.
    public init(devices: [PairedDevice], macID: String?, port: NWEndpoint.Port = .any) {
        parameters = LiveLinkSecurity.streamServerParameters(devices: devices)
        self.port = port
        service = macID.map {
            NWListener.Service(type: LiveLink.streamServiceType, txtRecord: NWTXTRecord([LiveLink.macIDKey: $0]))
        }
    }

    public func start() {
        queue.async { self.startListener() }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.stream?.cancel()
            self.stream = nil
        }
    }

    /// Sends a command to the streaming iPad, if one is connected.
    public func send(_ command: ControlCommand) {
        queue.async { self.stream?.send(.control(command)) }
    }

    private func startListener() {
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: parameters, on: port)
            listener.service = service
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let port = listener.port { self.onListening?(port) }
                case .failed(let error):
                    self.listener = nil
                    self.onListenerFailed?(error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onListenerFailed?(error)
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        let connection = LiveLinkConnection(connection: nwConnection, queue: queue)
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection else { return }
            self.handle(message, from: connection)
        }
        connection.onClose = { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.pendingConnections.removeAll { $0 === connection }
            guard connection === self.stream else { return }
            self.stream = nil
            self.onStreamEnded?()
        }
        // Not the current stream until it has authenticated (TLS) and said hello.
        pendingConnections.append(connection)
        connection.start()
    }

    /// Connections between TCP accept and their hello, held so they aren't deallocated mid-handshake.
    private var pendingConnections: [LiveLinkConnection] = []

    private func handle(_ message: LiveLinkMessage, from connection: LiveLinkConnection) {
        switch message {
        case .hello(let deviceName):
            pendingConnections.removeAll { $0 === connection }
            if let old = stream, old !== connection {
                old.onClose = nil
                old.cancel()
            }
            let replacing = stream != nil
            stream = connection
            assembler = SampleBufferAssembler()
            lastInfo = nil
            if !replacing { onStreamStarted?(deviceName) }
        case .videoFormat(let format):
            guard connection === stream else { return }
            do {
                try assembler.setFormat(format)
            } catch {
                connection.cancel()
            }
        case .videoFrame(let frame):
            guard connection === stream, let format = assembler.format else { return }
            if lastInfo == nil || lastInfo!.width != format.width || lastInfo!.height != format.height
                || lastInfo!.orientation != frame.orientation {
                lastInfo = (format.width, format.height, frame.orientation)
                onVideoInfo?(format.width, format.height, frame.orientation)
            }
            if let sampleBuffer = assembler.sampleBuffer(for: frame) {
                onFrame?(sampleBuffer)
            }
        default:
            break // control and pairing messages don't belong on a stream connection
        }
    }
}

/// Mac side: pairs one iPad at a time by numeric comparison (see `PairingCrypto`).
///
/// Runs only while the Mac's pairing window is open, and stops for good once an iPad is paired.
/// While one iPad is pairing, other connections are turned away. All callbacks arrive on `queue`;
/// `confirm()` and `decline()` may be called from any thread.
public final class LiveLinkPairingServer: @unchecked Sendable {

    public let queue = DispatchQueue(label: "app.ipadlive.wireless.pairing")

    public var onListening: ((NWEndpoint.Port) -> Void)?
    public var onListenerFailed: ((Error) -> Void)?
    /// An iPad wants to pair: show its name and the code, and ask the person to check the iPad shows
    /// the same code before calling `confirm()`.
    public var onRequest: ((_ deviceName: String, _ code: String) -> Void)?
    /// Both sides confirmed. The device (with its new stream key) should be remembered.
    public var onPaired: ((PairedDevice) -> Void)?
    /// The pairing in progress ended without pairing (the iPad cancelled or left). The listener
    /// keeps running so the iPad can try again.
    public var onRequestEnded: (() -> Void)?

    private let service: NWListener.Service?
    private let port: NWEndpoint.Port
    private let macID: String
    private let macName: String
    private var listener: NWListener?
    private var session: Session?
    private var finished = false

    private final class Session {
        let connection: LiveLinkConnection
        var deviceName = ""
        var responder: PairingResponder?
        var macConfirmed = false
        var iPadConfirmed = false
        var announced = false

        init(connection: LiveLinkConnection) {
            self.connection = connection
        }
    }

    public init(macID: String, macName: String, advertise: Bool, port: NWEndpoint.Port = .any) {
        self.port = port
        self.macID = macID
        self.macName = macName
        service = advertise ? NWListener.Service(type: LiveLink.pairingServiceType) : nil
    }

    public func start() {
        queue.async {
            guard self.listener == nil, !self.finished else { return }
            do {
                let listener = try NWListener(using: LiveLinkSecurity.pairingParameters(), on: self.port)
                listener.service = self.service
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if let port = listener.port { self.onListening?(port) }
                    case .failed(let error):
                        self.onListenerFailed?(error)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                self.onListenerFailed?(error)
            }
        }
    }

    public func stop() {
        queue.async {
            self.finished = true
            self.listener?.cancel()
            self.listener = nil
            self.session?.connection.cancel()
            self.session = nil
        }
    }

    /// The person checked the codes match and clicked Pair on the Mac.
    public func confirm() {
        queue.async {
            guard let session = self.session, session.announced else { return }
            session.macConfirmed = true
            self.finishIfConfirmed(session)
        }
    }

    /// Turn down the iPad currently asking to pair. The listener keeps running.
    public func decline() {
        queue.async {
            self.session?.connection.cancel()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard !finished, session == nil else {
            nwConnection.cancel() // one pairing at a time
            return
        }
        let connection = LiveLinkConnection(connection: nwConnection, queue: queue)
        let session = Session(connection: connection)
        connection.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            self.handle(message, in: session)
        }
        connection.onClose = { [weak self, weak session] _ in
            guard let self, let session, self.session === session else { return }
            self.session = nil
            if session.announced, !self.finished { self.onRequestEnded?() }
        }
        self.session = session
        connection.start()
    }

    private func handle(_ message: LiveLinkMessage, in session: Session) {
        guard self.session === session, !finished else { return }
        do {
            switch message {
            case .pairStart(let deviceName, let publicKey):
                guard session.responder == nil else { throw LiveLinkError.pairingFailed }
                let responder = try PairingResponder(initiatorKey: publicKey)
                session.deviceName = String(deviceName.prefix(100))
                session.responder = responder
                session.connection.send(.pairCommit(publicKey: responder.publicKey, commitment: responder.commitment))
            case .pairNonce(let initiatorNonce):
                guard var responder = session.responder, responder.code == nil else { throw LiveLinkError.pairingFailed }
                let (nonce, code) = try responder.receiveNonce(initiatorNonce)
                session.responder = responder
                session.connection.send(.pairNonce(nonce))
                session.announced = true
                onRequest?(session.deviceName, code)
            case .pairConfirm(let sealed):
                guard let responder = session.responder, responder.code != nil,
                      responder.openConfirmation(sealed) else { throw LiveLinkError.pairingFailed }
                session.iPadConfirmed = true
                finishIfConfirmed(session)
            default:
                throw LiveLinkError.pairingFailed
            }
        } catch {
            session.connection.cancel()
        }
    }

    /// Hands over the stream key only once the person confirmed on both the Mac and the iPad.
    private func finishIfConfirmed(_ session: Session) {
        guard session.macConfirmed, session.iPadConfirmed, !finished, let responder = session.responder else { return }
        let device = PairedDevice(
            deviceID: LiveLinkSecurity.makeDeviceID(),
            name: session.deviceName,
            streamKey: LiveLinkSecurity.makeStreamKey()
        )
        let result = PairingCrypto.Result(macID: macID, macName: macName, deviceID: device.deviceID, streamKey: device.streamKey)
        guard let sealed = try? responder.sealResult(result) else {
            session.connection.cancel()
            return
        }
        finished = true
        listener?.cancel() // paired: no more pairing on this window
        listener = nil
        session.connection.send(.pairResult(sealed: sealed))
        onPaired?(device)
        // The iPad closes the connection once it has the result.
    }
}
