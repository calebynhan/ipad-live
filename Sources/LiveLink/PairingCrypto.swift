import CryptoKit
import Foundation

/// Pairing by numeric comparison, the scheme Bluetooth uses ("Numeric Comparison", Bluetooth
/// Core Spec Vol 3 Part H §2.3.5.6.2). It has no password an attacker could crack offline.
///
/// 1. iPad → Mac: one-time X25519 public key `A`.
/// 2. Mac → iPad: one-time public key `B`, and `commit = SHA256(A ‖ B ‖ Nb)` for a random nonce `Nb`.
/// 3. iPad → Mac: random nonce `Na`.
/// 4. Mac → iPad: reveals `Nb`; the iPad checks it against the commitment.
/// 5. Both show the 6-digit code `SHA256(A ‖ B ‖ Na ‖ Nb) mod 10⁶`, and the person confirms on
///    both devices that the codes match.
/// 6. Encrypted with keys from `X25519(A, B)`: the iPad confirms, then the Mac sends its ID and
///    a fresh 256-bit stream key for this iPad.
///
/// Why someone in the middle loses: they run a separate exchange with each device, so each screen
/// shows a code from a different exchange. The Mac commits to `Nb` before seeing `Na`, and the
/// attacker (playing the Mac to the iPad) must commit before seeing the iPad's `Na`. So neither code
/// can be steered: the two codes match only by chance, 1 in a million, and the attempt is visible.
/// Nothing in the exchange lets anyone test code guesses offline.
public enum PairingCrypto {

    /// Everything the iPad receives at the end of pairing.
    public struct Result: Equatable, Sendable {
        public var macID: String
        public var macName: String
        /// This iPad's ID on that Mac (the TLS PSK identity when streaming).
        public var deviceID: String
        /// This iPad's own 256-bit key for streaming to that Mac.
        public var streamKey: Data

        public init(macID: String, macName: String, deviceID: String, streamKey: Data) {
            self.macID = macID
            self.macName = macName
            self.deviceID = deviceID
            self.streamKey = streamKey
        }
    }

    static let keyLength = 32
    static let nonceLength = 32
    private static let confirmation = Data("ipad-live-pairing-confirm-v1".utf8)

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: SymmetricKeySize(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }

    // All inputs are fixed-length, so plain concatenation after a domain label is unambiguous.
    static func commitment(initiatorKey: Data, responderKey: Data, responderNonce: Data) -> Data {
        hash("ipad-live-pairing-commit-v1", initiatorKey, responderKey, responderNonce)
    }

    static func code(initiatorKey: Data, responderKey: Data, initiatorNonce: Data, responderNonce: Data) -> String {
        let digest = hash("ipad-live-pairing-code-v1", initiatorKey, responderKey, initiatorNonce, responderNonce)
        let value = digest.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return String(format: "%06u", value % 1_000_000)
    }

    struct SessionKeys {
        var initiatorToResponder: SymmetricKey
        var responderToInitiator: SymmetricKey
    }

    static func sessionKeys(
        sharedSecret: SharedSecret,
        initiatorKey: Data,
        responderKey: Data,
        initiatorNonce: Data,
        responderNonce: Data
    ) throws -> SessionKeys {
        // A small-order public key gives an all-zero secret; refuse it.
        let isZero = sharedSecret.withUnsafeBytes { $0.allSatisfy { $0 == 0 } }
        guard !isZero else { throw LiveLinkError.pairingFailed }
        let salt = hash("ipad-live-pairing-salt-v1", initiatorKey, responderKey, initiatorNonce, responderNonce)
        let material = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("ipad-live-pairing-keys-v1".utf8),
            outputByteCount: 64
        )
        let bytes = material.withUnsafeBytes { Data($0) }
        return SessionKeys(
            initiatorToResponder: SymmetricKey(data: bytes.prefix(32)),
            responderToInitiator: SymmetricKey(data: bytes.suffix(32))
        )
    }

    private static func hash(_ label: String, _ parts: Data...) -> Data {
        var hasher = SHA256()
        hasher.update(data: Data(label.utf8))
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(plaintext, using: key).combined
    }

    static func open(_ sealed: Data, using key: SymmetricKey) throws -> Data {
        do {
            return try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: sealed), using: key)
        } catch {
            throw LiveLinkError.pairingFailed
        }
    }

    static func isConfirmation(_ data: Data) -> Bool { data == confirmation }
    static var confirmationMessage: Data { confirmation }
}

/// The iPad's side of pairing. Call the steps in order; any out-of-order call or bad input throws.
public struct PairingInitiator {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = PairingCrypto.randomBytes(PairingCrypto.nonceLength)
    private var responderKey: Data?
    private var commitment: Data?
    private var keys: PairingCrypto.SessionKeys?
    /// The 6-digit code to show, once known.
    public private(set) var code: String?

    public init() {}

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Step 2 → 3: remember the Mac's key and commitment; returns the nonce to send.
    public mutating func receiveCommit(responderKey: Data, commitment: Data) throws -> Data {
        guard self.responderKey == nil,
              responderKey.count == PairingCrypto.keyLength,
              commitment.count == 32 else { throw LiveLinkError.pairingFailed }
        self.responderKey = responderKey
        self.commitment = commitment
        return nonce
    }

    /// Step 4 → 5: check the revealed nonce against the commitment; returns the code to show.
    public mutating func receiveNonce(_ responderNonce: Data) throws -> String {
        guard keys == nil, let responderKey, let commitment,
              responderNonce.count == PairingCrypto.nonceLength else { throw LiveLinkError.pairingFailed }
        let expected = PairingCrypto.commitment(
            initiatorKey: publicKey,
            responderKey: responderKey,
            responderNonce: responderNonce
        )
        guard expected == commitment else { throw LiveLinkError.pairingFailed }

        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: responderKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        keys = try PairingCrypto.sessionKeys(
            sharedSecret: shared,
            initiatorKey: publicKey,
            responderKey: responderKey,
            initiatorNonce: nonce,
            responderNonce: responderNonce
        )
        let code = PairingCrypto.code(
            initiatorKey: publicKey,
            responderKey: responderKey,
            initiatorNonce: nonce,
            responderNonce: responderNonce
        )
        self.code = code
        return code
    }

    /// Step 6: sent only after the person confirms the codes match.
    public func sealConfirmation() throws -> Data {
        guard let keys else { throw LiveLinkError.pairingFailed }
        return try PairingCrypto.seal(PairingCrypto.confirmationMessage, using: keys.initiatorToResponder)
    }

    /// Step 6: the Mac's encrypted reply.
    public func openResult(_ sealed: Data) throws -> PairingCrypto.Result {
        guard let keys else { throw LiveLinkError.pairingFailed }
        var reader = BinaryReader(try PairingCrypto.open(sealed, using: keys.responderToInitiator))
        let result = PairingCrypto.Result(
            macID: try reader.string(),
            macName: try reader.string(),
            deviceID: try reader.string(),
            streamKey: try reader.bytes()
        )
        guard reader.isAtEnd, result.streamKey.count == 32 else { throw LiveLinkError.pairingFailed }
        return result
    }
}

/// The Mac's side of pairing.
public struct PairingResponder {
    private let privateKey = Curve25519.KeyAgreement.PrivateKey()
    private let nonce = PairingCrypto.randomBytes(PairingCrypto.nonceLength)
    private let initiatorKey: Data
    private var keys: PairingCrypto.SessionKeys?
    public private(set) var code: String?

    /// Step 1: the iPad's public key.
    public init(initiatorKey: Data) throws {
        guard initiatorKey.count == PairingCrypto.keyLength else { throw LiveLinkError.pairingFailed }
        _ = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorKey)
        self.initiatorKey = initiatorKey
    }

    public var publicKey: Data { privateKey.publicKey.rawRepresentation }

    /// Step 2: binds the Mac to its key and nonce before it sees the iPad's nonce.
    public var commitment: Data {
        PairingCrypto.commitment(initiatorKey: initiatorKey, responderKey: publicKey, responderNonce: nonce)
    }

    /// Step 3 → 4: returns the nonce to reveal and the code to show.
    public mutating func receiveNonce(_ initiatorNonce: Data) throws -> (nonce: Data, code: String) {
        guard keys == nil, initiatorNonce.count == PairingCrypto.nonceLength else { throw LiveLinkError.pairingFailed }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: initiatorKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        keys = try PairingCrypto.sessionKeys(
            sharedSecret: shared,
            initiatorKey: initiatorKey,
            responderKey: publicKey,
            initiatorNonce: initiatorNonce,
            responderNonce: nonce
        )
        let code = PairingCrypto.code(
            initiatorKey: initiatorKey,
            responderKey: publicKey,
            initiatorNonce: initiatorNonce,
            responderNonce: nonce
        )
        self.code = code
        return (nonce, code)
    }

    /// Step 6: true if the iPad's person confirmed (and it really is the other end of this exchange).
    public func openConfirmation(_ sealed: Data) -> Bool {
        guard let keys, let plaintext = try? PairingCrypto.open(sealed, using: keys.initiatorToResponder) else {
            return false
        }
        return PairingCrypto.isConfirmation(plaintext)
    }

    /// Step 6: the encrypted reply that completes pairing.
    public func sealResult(_ result: PairingCrypto.Result) throws -> Data {
        guard let keys else { throw LiveLinkError.pairingFailed }
        var writer = BinaryWriter()
        writer.string(result.macID)
        writer.string(result.macName)
        writer.string(result.deviceID)
        writer.bytes(result.streamKey)
        return try PairingCrypto.seal(writer.data, using: keys.responderToInitiator)
    }
}
