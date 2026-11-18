import CoreMedia
import Foundation
import Network

/// Mac side: accepts the paired iPad's stream and turns it into `CMSampleBuffer`s.
///
/// Only devices that know the stream key get past the TLS handshake. One stream at a time: a new
/// stream (e.g. the iPad restarted its broadcast) replaces the old one.
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

    /// - Parameter macID: advertised over Bonjour so paired iPads can find this Mac; `nil` to not advertise.
    public init(streamKey: Data, macID: String?, port: NWEndpoint.Port = .any) {
        parameters = LiveLinkSecurity.streamParameters(streamKey: streamKey)
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
        case .pairAccepted, .control:
            break // not sent by iPads
        }
    }
}

/// Mac side: hands the stream key to an iPad that knows the pairing code.
///
/// Runs only while the Mac's pairing window is open. All callbacks arrive on `queue`.
public final class LiveLinkPairingServer: @unchecked Sendable {

    public let queue = DispatchQueue(label: "app.ipadlive.wireless.pairing")

    public var onListening: ((NWEndpoint.Port) -> Void)?
    public var onListenerFailed: ((Error) -> Void)?
    public var onPaired: ((_ deviceName: String) -> Void)?
    /// A connection failed before pairing, almost always a wrong code. Includes the running count.
    public var onFailedAttempt: ((_ count: Int) -> Void)?

    private let parameters: NWParameters
    private let service: NWListener.Service?
    private let port: NWEndpoint.Port
    private let macID: String
    private let macName: String
    private let streamKey: Data
    private var listener: NWListener?
    private var connections: [LiveLinkConnection] = []
    private var failedAttempts = 0
    private var paired = false

    public init(code: String, macID: String, macName: String, streamKey: Data, advertise: Bool, port: NWEndpoint.Port = .any) {
        parameters = LiveLinkSecurity.pairingParameters(code: code)
        self.port = port
        self.macID = macID
        self.macName = macName
        self.streamKey = streamKey
        service = advertise ? NWListener.Service(type: LiveLink.pairingServiceType) : nil
    }

    public func start() {
        queue.async {
            guard self.listener == nil else { return }
            do {
                let listener = try NWListener(using: self.parameters, on: self.port)
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
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
        }
    }

    private func accept(_ nwConnection: NWConnection) {
        guard !paired else {
            nwConnection.cancel()
            return
        }
        let connection = LiveLinkConnection(connection: nwConnection, queue: queue)
        var greeted = false
        connection.onMessage = { [weak self, weak connection] message in
            guard let self, let connection, case .hello(let deviceName) = message, !self.paired else { return }
            greeted = true
            self.paired = true
            connection.send(.pairAccepted(macID: self.macID, macName: self.macName, streamKey: self.streamKey))
            self.listener?.cancel() // the code is single-use
            self.listener = nil
            self.onPaired?(deviceName)
        }
        connection.onClose = { [weak self, weak connection] error in
            guard let self else { return }
            self.connections.removeAll { $0 === connection }
            if !greeted, error != nil, !self.paired {
                self.failedAttempts += 1
                self.onFailedAttempt?(self.failedAttempts)
            }
        }
        connections.append(connection)
        connection.start()
    }
}
