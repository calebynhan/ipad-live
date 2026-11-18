import Foundation
import Network
import Security

/// One LiveLink connection: frames messages over an `NWConnection`.
///
/// Everything happens on `queue`: callbacks are delivered there, and `send` must be called there.
public final class LiveLinkConnection: @unchecked Sendable {

    public let queue: DispatchQueue
    private let connection: NWConnection

    public var onReady: (() -> Void)?
    public var onMessage: ((LiveLinkMessage) -> Void)?
    /// Called once, when the connection ends for any reason. `nil` means a clean close.
    public var onClose: ((Error?) -> Void)?
    /// Called after each sent message has been handed to the network.
    public var onSendCompleted: (() -> Void)?

    /// Bytes handed to `send` that the network hasn't taken yet. Senders use this to drop
    /// frames instead of building a backlog (a backlog is delay).
    public private(set) var pendingBytes = 0
    public private(set) var isReady = false
    private var isClosed = false

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public var endpoint: NWEndpoint { connection.endpoint }

    /// The TLS cipher suite in use once connected, for diagnostics.
    public var negotiatedCipherSuite: UInt16? {
        guard let metadata = connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }
        return sec_protocol_metadata_get_negotiated_tls_ciphersuite(metadata.securityProtocolMetadata).rawValue
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in self?.handle(state) }
        connection.start(queue: queue)
    }

    public func send(_ message: LiveLinkMessage) {
        guard !isClosed else { return }
        let data = message.encoded()
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.pendingBytes -= data.count
            if let error {
                self.close(error)
            } else {
                self.onSendCompleted?()
            }
        })
    }

    public func cancel() {
        queue.async { self.close(nil) }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isReady = true
            onReady?()
            receiveHeader()
        case .failed(let error), .waiting(let error):
            // `.waiting` covers TLS failures (wrong key) and unreachable hosts. Callers retry if they want.
            close(error)
        case .cancelled:
            close(nil)
        default:
            break
        }
    }

    private func close(_ error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        connection.stateUpdateHandler = nil
        connection.cancel()
        let onClose = self.onClose
        self.onReady = nil
        self.onMessage = nil
        self.onClose = nil
        self.onSendCompleted = nil
        onClose?(error)
    }

    private func receiveHeader() {
        let length = LiveLinkMessage.headerLength
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] content, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let error {
                self.close(error)
                return
            }
            guard let content, content.count == length else {
                self.close(isComplete ? nil : LiveLinkError.malformedMessage)
                return
            }
            do {
                let header = try LiveLinkMessage.Header(content)
                if header.payloadLength == 0 {
                    try self.deliver(type: header.type, payload: Data())
                    self.receiveHeader()
                } else {
                    self.receivePayload(header)
                }
            } catch {
                self.close(error)
            }
        }
    }

    private func receivePayload(_ header: LiveLinkMessage.Header) {
        let length = header.payloadLength
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] content, _, _, error in
            guard let self, !self.isClosed else { return }
            if let error {
                self.close(error)
                return
            }
            guard let content, content.count == length else {
                self.close(LiveLinkError.malformedMessage)
                return
            }
            do {
                try self.deliver(type: header.type, payload: content)
                self.receiveHeader()
            } catch {
                self.close(error)
            }
        }
    }

    private func deliver(type: UInt8, payload: Data) throws {
        if let message = try LiveLinkMessage.decode(type: type, payload: payload) {
            onMessage?(message)
        }
    }
}
