import CryptoKit
import Foundation
import Network
import Security

/// A paired iPad, as the Mac remembers it.
public struct PairedDevice: Codable, Equatable, Sendable {
    /// Random ID the Mac gave this iPad when pairing; the TLS PSK identity when it streams.
    public var deviceID: String
    public var name: String
    /// 256-bit key known only to this Mac and this iPad. New for every pairing.
    public var streamKey: Data

    public init(deviceID: String, name: String, streamKey: Data) {
        self.deviceID = deviceID
        self.name = name
        self.streamKey = streamKey
    }
}

/// How LiveLink keeps strangers on the same Wi-Fi out.
///
/// - **Pairing** uses numeric comparison (`PairingCrypto`): both screens show a code derived from a
///   fresh key exchange and the person confirms they match. Only then does the Mac hand this iPad
///   its own new random 256-bit stream key, encrypted. There is no password to guess or crack.
/// - **Streaming** is TLS 1.2 with ECDHE-PSK (`TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256`) only:
///   the per-iPad stream key authenticates both ends (only that Mac and that iPad know it), and the
///   ECDHE exchange gives every session fresh keys (forward secrecy). The PSK identity is the iPad's
///   device ID, so the Mac uses the right key for each paired iPad.
public enum LiveLinkSecurity {

    /// The only cipher suite offered: ECDHE for forward secrecy, PSK for mutual authentication.
    public static let cipherSuite: UInt16 = 0xCCAC // TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256 (RFC 7905)

    /// A new random 256-bit stream key.
    public static func makeStreamKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    public static func makeDeviceID() -> String {
        UUID().uuidString
    }

    /// iPad side: stream to the Mac as `deviceID`, proving it knows `streamKey`.
    public static func streamClientParameters(deviceID: String, streamKey: Data) -> NWParameters {
        tlsParameters(keys: [(deviceID, streamKey)])
    }

    /// Mac side: accept any paired iPad, each with its own key.
    public static func streamServerParameters(devices: [PairedDevice]) -> NWParameters {
        tlsParameters(keys: devices.map { ($0.deviceID, $0.streamKey) })
    }

    /// Pairing runs over plain TCP: `PairingCrypto` authenticates and encrypts what matters.
    public static func pairingParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }

    private static func tlsParameters(keys: [(identity: String, key: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        for (identity, key) in keys {
            let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityData = Data(identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(options, keyData as __DispatchData, identityData as __DispatchData)
        }
        let suite: tls_ciphersuite_t? = tls_ciphersuite_t(rawValue: cipherSuite)
        if let suite { sec_protocol_options_append_tls_ciphersuite(options, suite) }
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
