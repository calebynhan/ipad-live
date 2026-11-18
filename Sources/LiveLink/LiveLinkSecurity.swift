import CryptoKit
import Foundation
import Network
import Security

/// How LiveLink keeps strangers on the same Wi-Fi out.
///
/// Every connection is TLS 1.2 with a pre-shared key (PSK), so the TLS handshake itself proves
/// both ends know the key, and everything after it is encrypted:
///
/// - **Pairing** (once): the Mac shows a random 6-digit code; the iPad user types it in. Both sides
///   derive a PSK from the code. The Mac's pairing listener only runs while its pairing window is
///   open, and it gives up after a few wrong attempts.
/// - **Streaming**: during pairing the Mac hands the iPad a random 256-bit stream key, which is the
///   PSK for every streaming connection afterwards.
///
/// The ECDHE-PSK cipher suite is preferred so each session gets fresh keys (forward secrecy) and a
/// passive eavesdropper can't attack the pairing code. Plain PSK-AES-GCM, the suite Apple's own
/// peer-to-peer sample uses, is the fallback.
public enum LiveLinkSecurity {

    /// A random 6-digit pairing code, e.g. "042917".
    public static func makePairingCode() -> String {
        var generator = SystemRandomNumberGenerator() // cryptographically secure on Apple platforms
        return String(format: "%06d", Int.random(in: 0...999_999, using: &generator))
    }

    /// The PSK both sides derive from the pairing code. Spaces and dashes are ignored.
    public static func pairingKey(code: String) -> Data {
        let digits = code.filter(\.isNumber)
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(digits.utf8)),
            salt: Data("ipad-live-pairing-v1".utf8),
            info: Data("tls-psk".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// A new random 256-bit stream key.
    public static func makeStreamKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func streamParameters(streamKey: Data) -> NWParameters {
        parameters(psk: streamKey, identity: LiveLink.streamPSKIdentity)
    }

    public static func pairingParameters(code: String) -> NWParameters {
        parameters(psk: pairingKey(code: code), identity: LiveLink.pairingPSKIdentity)
    }

    // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905) and TLS_PSK_WITH_AES_128_GCM_SHA256 (RFC 5487).
    static let ecdhePSKSuite: UInt16 = 0xCCAC
    static let pskSuite: UInt16 = 0x00A8

    static func parameters(psk: Data, identity: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        let pskData = psk.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, pskData as __DispatchData, identityData as __DispatchData)
        for raw in [ecdhePSKSuite, pskSuite] {
            let suite: tls_ciphersuite_t? = tls_ciphersuite_t(rawValue: raw)
            if let suite { sec_protocol_options_append_tls_ciphersuite(options, suite) }
        }
        // PSK cipher suites are TLS 1.2 features.
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true // send each frame immediately; latency beats packing
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        parameters.includePeerToPeer = false
        return parameters
    }
}
