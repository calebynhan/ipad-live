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

    public init(deviceID: String, streamKey: Data, deviceName: String, target: Target, queue: DispatchQueue) {
        parameters = LiveLinkSecurity.streamClientParameters(deviceID: deviceID, streamKey: streamKey)
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

/// iPad side: one pairing attempt with a Mac whose pairing window is open, by numeric comparison
/// (see `PairingCrypto`). Callbacks arrive on `queue`; call `confirm()` and `cancel()` from any thread.
public final class LiveLinkPairingSession: @unchecked Sendable {

    /// Show this code and ask the person to check the Mac shows the same one, then call `confirm()`.
    public var onCode: ((String) -> Void)?
    /// Paired. Save the result (it holds this iPad's stream key) somewhere safe.
    public var onPaired: ((PairingCrypto.Result) -> Void)?
    /// Pairing ended without pairing. Called at most once, and never after `onPaired`.
    public var onFailed: ((Error) -> Void)?

    private let queue: DispatchQueue
    private let deviceName: String
    private let connection: LiveLinkConnection
    private var initiator = PairingInitiator()
    private var confirmed = false
    private var done = false

    public init(endpoint: NWEndpoint, deviceName: String, queue: DispatchQueue, timeout: TimeInterval = 120) {
        self.queue = queue
        self.deviceName = deviceName
        connection = LiveLinkConnection(
            connection: NWConnection(to: endpoint, using: LiveLinkSecurity.pairingParameters()),
            queue: queue
        )
        connection.onReady = { [weak self] in
            guard let self else { return }
            self.connection.send(.pairStart(deviceName: self.deviceName, publicKey: self.initiator.publicKey))
        }
        connection.onMessage = { [weak self] message in self?.handle(message) }
        connection.onClose = { [weak self] _ in
            // A closed connection before the result means the Mac declined, or went away.
            self?.fail(LiveLinkError.pairingDeclined)
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.fail(LiveLinkError.timedOut)
        }
    }

    public func start() {
        connection.start()
    }

    /// The person checked the codes match and tapped Pair on the iPad.
    public func confirm() {
        queue.async {
            guard !self.done, !self.confirmed, self.initiator.code != nil,
                  let sealed = try? self.initiator.sealConfirmation() else { return }
            self.confirmed = true
            self.connection.send(.pairConfirm(sealed: sealed))
        }
    }

    public func cancel() {
        queue.async {
            self.fail(LiveLinkError.pairingDeclined)
        }
    }

    private func handle(_ message: LiveLinkMessage) {
        guard !done else { return }
        do {
            switch message {
            case .pairCommit(let publicKey, let commitment):
                let nonce = try initiator.receiveCommit(responderKey: publicKey, commitment: commitment)
                connection.send(.pairNonce(nonce))
            case .pairNonce(let responderNonce):
                let code = try initiator.receiveNonce(responderNonce)
                onCode?(code)
            case .pairResult(let sealed):
                // Only accepted after this iPad's person confirmed.
                guard confirmed else { throw LiveLinkError.pairingFailed }
                let result = try initiator.openResult(sealed)
                done = true
                connection.cancel()
                onPaired?(result)
            default:
                throw LiveLinkError.pairingFailed
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        guard !done else { return }
        done = true
        connection.cancel()
        onFailed?(error)
    }
}
