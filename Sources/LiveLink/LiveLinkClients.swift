import Foundation
import Network

/// iPad side: finds the paired Mac and keeps a stream connection to it open, reconnecting
/// whenever it drops. All callbacks arrive on `queue`; call `send` on `queue` too.
public final class LiveLinkStreamClient: @unchecked Sendable {

    public enum Target {
        /// Find the Mac on the local network by the ID it advertises over Bonjour.
        case bonjour(macID: String)
        /// Connect to a known address (used by tests).
        case endpoint(NWEndpoint)
    }

    public let queue: DispatchQueue
    public var onReady: (() -> Void)?
    public var onControl: ((ControlCommand) -> Void)?
    public var onDisconnected: ((Error?) -> Void)?
    public var onSendCompleted: (() -> Void)?

    public var isReady: Bool { connection?.isReady ?? false }
    public var pendingBytes: Int { connection?.pendingBytes ?? 0 }
    public var negotiatedCipherSuite: UInt16? { connection?.negotiatedCipherSuite }

    private let parameters: NWParameters
    private let deviceName: String
    private let target: Target
    private var browser: NWBrowser?
    private var connection: LiveLinkConnection?
    private var running = false

    public init(streamKey: Data, deviceName: String, target: Target, queue: DispatchQueue) {
        parameters = LiveLinkSecurity.streamParameters(streamKey: streamKey)
        self.deviceName = deviceName
        self.target = target
        self.queue = queue
    }

    public func start() {
        queue.async {
            guard !self.running else { return }
            self.running = true
            self.connectOrBrowse()
        }
    }

    public func stop() {
        queue.async {
            self.running = false
            self.browser?.cancel()
            self.browser = nil
            self.connection?.cancel()
            self.connection = nil
        }
    }

    public func send(_ message: LiveLinkMessage) {
        connection?.send(message)
    }

    private func connectOrBrowse() {
        guard running, connection == nil, browser == nil else { return }
        switch target {
        case .endpoint(let endpoint):
            connect(to: endpoint)
        case .bonjour(let macID):
            browse(for: macID)
        }
    }

    private func browse(for macID: String) {
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: LiveLink.streamServiceType, domain: nil),
            using: NWParameters()
        )
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            let match = results.first { result in
                if case .bonjour(let txt) = result.metadata { return txt[LiveLink.macIDKey] == macID }
                return false
            }
            guard let match else { return }
            browser.cancel()
            self.browser = nil
            self.connect(to: match.endpoint)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            if case .failed = state {
                browser.cancel()
                self.browser = nil
                self.retrySoon()
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    private func connect(to endpoint: NWEndpoint) {
        let connection = LiveLinkConnection(connection: NWConnection(to: endpoint, using: parameters), queue: queue)
        connection.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.send(.hello(deviceName: self.deviceName))
            self.onReady?()
        }
        connection.onMessage = { [weak self] message in
            if case .control(let command) = message { self?.onControl?(command) }
        }
        connection.onSendCompleted = { [weak self] in self?.onSendCompleted?() }
        connection.onClose = { [weak self, weak connection] error in
            guard let self, let connection, connection === self.connection else { return }
            self.connection = nil
            self.onDisconnected?(error)
            self.retrySoon()
        }
        self.connection = connection
        connection.start()
    }

    private func retrySoon() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connectOrBrowse() }
    }
}

/// iPad side: lists Macs that currently have their "Pair iPad" window open.
/// Callbacks arrive on `queue`.
public final class LiveLinkPairingBrowser: @unchecked Sendable {

    public struct Mac: Hashable, Identifiable {
        public let name: String
        public let endpoint: NWEndpoint
        public var id: String { name }
    }

    public var onChange: (([Mac]) -> Void)?
    private let queue: DispatchQueue
    private var browser: NWBrowser?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: LiveLink.pairingServiceType, domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let macs = results.compactMap { result -> Mac? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Mac(name: name, endpoint: result.endpoint)
            }
            self?.onChange?(macs.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    public func stop() {
        browser?.cancel()
        browser = nil
    }
}

/// iPad side: one pairing attempt with a Mac whose pairing window is open.
public enum LiveLinkPairing {

    public struct Result: Equatable, Sendable {
        public var macID: String
        public var macName: String
        public var streamKey: Data
    }

    /// Calls `completion` exactly once, on `queue`.
    public static func pair(
        with endpoint: NWEndpoint,
        code: String,
        deviceName: String,
        queue: DispatchQueue,
        timeout: TimeInterval = 15,
        completion: @escaping (Swift.Result<Result, Error>) -> Void
    ) {
        let connection = LiveLinkConnection(
            connection: NWConnection(to: endpoint, using: LiveLinkSecurity.pairingParameters(code: code)),
            queue: queue
        )
        var finished = false
        func finish(_ result: Swift.Result<Result, Error>) {
            guard !finished else { return }
            finished = true
            connection.cancel()
            completion(result)
        }
        connection.onReady = { [weak connection] in
            connection?.send(.hello(deviceName: deviceName))
        }
        connection.onMessage = { message in
            if case .pairAccepted(let macID, let macName, let streamKey) = message, streamKey.count == 32 {
                finish(.success(Result(macID: macID, macName: macName, streamKey: streamKey)))
            }
        }
        connection.onClose = { _ in
            // A wrong code fails the TLS handshake, which lands here.
            finish(.failure(LiveLinkError.pairingFailed))
        }
        queue.asyncAfter(deadline: .now() + timeout) {
            finish(.failure(LiveLinkError.timedOut))
        }
        connection.start()
    }
}
