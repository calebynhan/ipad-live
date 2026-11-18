import Foundation

/// LiveLink: how iPad Live Sender (on the iPad) streams its screen to iPad Live (on the Mac)
/// over Wi-Fi. This file is shared by the Mac app and the iPad app.
///
/// Every message on the wire is `[type: UInt8][payload length: UInt32, big-endian][payload]`.
/// Streaming runs inside TLS that only a paired iPad can open (see `LiveLinkSecurity`); pairing
/// secures itself (see `PairingCrypto`).
public enum LiveLink {
    /// Bonjour service the Mac advertises for streaming. Its TXT record carries the Mac's ID.
    public static let streamServiceType = "_ipadlive._tcp"
    /// Bonjour service the Mac advertises only while its "Pair iPad" window is open.
    public static let pairingServiceType = "_ipadlive-pair._tcp"
    /// TXT record key holding the Mac's ID, so a paired iPad finds the right Mac.
    public static let macIDKey = "id"

    /// Largest payload accepted. A keyframe of a full-resolution iPad screen is well under this.
    public static let maxPayloadLength = 16 * 1024 * 1024
}

public enum VideoCodec: UInt8, Sendable {
    case h264 = 1
}

/// Everything a decoder needs before the first frame: codec, size and parameter sets (SPS/PPS).
public struct VideoFormat: Equatable, Sendable {
    public var codec: VideoCodec
    public var width: Int
    public var height: Int
    public var parameterSets: [Data]

    public init(codec: VideoCodec, width: Int, height: Int, parameterSets: [Data]) {
        self.codec = codec
        self.width = width
        self.height = height
        self.parameterSets = parameterSets
    }
}

/// One compressed frame: length-prefixed (AVCC) NAL units.
public struct VideoFrame: Equatable, Sendable {
    public var isKeyframe: Bool
    /// How the frame must be rotated to display upright, as a `CGImagePropertyOrientation`
    /// raw value (1 = up, 3 = down, 6 = rotate 90° clockwise, 8 = rotate 90° counterclockwise).
    /// The iPad always captures in portrait and reports its rotation here.
    public var orientation: UInt8
    public var presentationTimeMicros: Int64
    public var data: Data

    public init(isKeyframe: Bool, orientation: UInt8, presentationTimeMicros: Int64, data: Data) {
        self.isKeyframe = isKeyframe
        self.orientation = orientation
        self.presentationTimeMicros = presentationTimeMicros
        self.data = data
    }
}

/// Sent by the Mac to the iPad.
public enum ControlCommand: UInt8, Sendable {
    case requestKeyframe = 1
    /// The Mac is showing something else (e.g. the USB cable is plugged in): stop encoding.
    case pause = 2
    case resume = 3
}

public enum LiveLinkMessage: Equatable, Sendable {
    /// First message from the iPad on every stream connection.
    case hello(deviceName: String)
    case videoFormat(VideoFormat)
    case videoFrame(VideoFrame)
    case control(ControlCommand)

    // Pairing (see `PairingCrypto` for what each step proves).
    /// iPad → Mac: the iPad's one-time public key.
    case pairStart(deviceName: String, publicKey: Data)
    /// Mac → iPad: the Mac's one-time public key, and a commitment to its random nonce.
    case pairCommit(publicKey: Data, commitment: Data)
    /// Both directions: a random nonce (the iPad's first; then the Mac reveals its committed one).
    case pairNonce(Data)
    /// iPad → Mac, encrypted: the person tapped Pair after checking the codes match.
    case pairConfirm(sealed: Data)
    /// Mac → iPad, encrypted: everything the iPad needs to stream to this Mac.
    case pairResult(sealed: Data)

    enum Kind: UInt8 {
        case hello = 1
        case videoFormat = 3
        case videoFrame = 4
        case control = 5
        case pairStart = 6
        case pairCommit = 7
        case pairNonce = 8
        case pairConfirm = 9
        case pairResult = 10
    }

    public static let headerLength = 5

    public struct Header: Equatable {
        public var type: UInt8
        public var payloadLength: Int

        public init(_ bytes: Data) throws {
            guard bytes.count == LiveLinkMessage.headerLength else { throw LiveLinkError.malformedMessage }
            var reader = BinaryReader(bytes)
            type = try reader.u8()
            payloadLength = Int(try reader.u32())
            guard payloadLength <= LiveLink.maxPayloadLength else { throw LiveLinkError.messageTooLarge }
        }
    }

    /// The message as it goes on the wire: header followed by payload.
    public func encoded() -> Data {
        var payload = BinaryWriter()
        let kind: Kind
        switch self {
        case .hello(let deviceName):
            kind = .hello
            payload.string(deviceName)
        case .pairStart(let deviceName, let publicKey):
            kind = .pairStart
            payload.string(deviceName)
            payload.bytes(publicKey)
        case .pairCommit(let publicKey, let commitment):
            kind = .pairCommit
            payload.bytes(publicKey)
            payload.bytes(commitment)
        case .pairNonce(let nonce):
            kind = .pairNonce
            payload.bytes(nonce)
        case .pairConfirm(let sealed):
            kind = .pairConfirm
            payload.bytes(sealed)
        case .pairResult(let sealed):
            kind = .pairResult
            payload.bytes(sealed)
        case .videoFormat(let format):
            kind = .videoFormat
            payload.u8(format.codec.rawValue)
            payload.u32(UInt32(clamping: format.width))
            payload.u32(UInt32(clamping: format.height))
            payload.u8(UInt8(clamping: format.parameterSets.count))
            for set in format.parameterSets.prefix(255) { payload.bytes(set) }
        case .videoFrame(let frame):
            kind = .videoFrame
            payload.u8(frame.isKeyframe ? 1 : 0)
            payload.u8(frame.orientation)
            payload.i64(frame.presentationTimeMicros)
            payload.raw(frame.data) // rest of the payload; no inner length needed
        case .control(let command):
            kind = .control
            payload.u8(command.rawValue)
        }
        var message = BinaryWriter()
        message.u8(kind.rawValue)
        message.u32(UInt32(payload.data.count))
        message.raw(payload.data)
        return message.data
    }

    /// Decodes a payload. Returns `nil` for message types this version doesn't know.
    public static func decode(type: UInt8, payload: Data) throws -> LiveLinkMessage? {
        guard let kind = Kind(rawValue: type) else { return nil }
        var reader = BinaryReader(payload)
        let message: LiveLinkMessage
        switch kind {
        case .hello:
            message = .hello(deviceName: try reader.string())
        case .pairStart:
            message = .pairStart(deviceName: try reader.string(), publicKey: try reader.bytes())
        case .pairCommit:
            message = .pairCommit(publicKey: try reader.bytes(), commitment: try reader.bytes())
        case .pairNonce:
            message = .pairNonce(try reader.bytes())
        case .pairConfirm:
            message = .pairConfirm(sealed: try reader.bytes())
        case .pairResult:
            message = .pairResult(sealed: try reader.bytes())
        case .videoFormat:
            guard let codec = VideoCodec(rawValue: try reader.u8()) else { throw LiveLinkError.unsupportedCodec }
            let width = Int(try reader.u32())
            let height = Int(try reader.u32())
            let count = Int(try reader.u8())
            var sets: [Data] = []
            for _ in 0..<count { sets.append(try reader.bytes()) }
            message = .videoFormat(VideoFormat(codec: codec, width: width, height: height, parameterSets: sets))
        case .videoFrame:
            let flags = try reader.u8()
            let orientation = try reader.u8()
            let pts = try reader.i64()
            message = .videoFrame(VideoFrame(
                isKeyframe: flags & 1 == 1,
                orientation: orientation,
                presentationTimeMicros: pts,
                data: reader.remaining()
            ))
            return message
        case .control:
            guard let command = ControlCommand(rawValue: try reader.u8()) else { return nil }
            message = .control(command)
        }
        guard reader.isAtEnd else { throw LiveLinkError.malformedMessage }
        return message
    }
}

public enum LiveLinkError: LocalizedError, Equatable {
    case malformedMessage
    case messageTooLarge
    case unsupportedCodec
    case invalidVideoFormat
    case pairingFailed
    case pairingDeclined
    case pairingBusy
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .malformedMessage: return "The other device sent something unexpected."
        case .messageTooLarge: return "The other device sent a message that was too large."
        case .unsupportedCodec: return "The iPad is using a video format this Mac doesn't understand."
        case .invalidVideoFormat: return "The iPad's video format couldn't be read."
        case .pairingFailed: return "Pairing didn't work. Try again while the Mac's Pair iPad Wirelessly window is open."
        case .pairingDeclined: return "Pairing was cancelled."
        case .pairingBusy: return "The Mac is already pairing with another device. Try again in a moment."
        case .timedOut: return "Pairing timed out. Make sure the Mac's pairing window is open and both are on the same Wi-Fi."
        }
    }
}

// MARK: - Binary helpers (big-endian, bounds-checked)

struct BinaryWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    mutating func i64(_ value: Int64) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    /// Length-prefixed bytes.
    mutating func bytes(_ value: Data) {
        u32(UInt32(value.count))
        data.append(value)
    }

    mutating func string(_ value: String) { bytes(Data(value.utf8)) }

    mutating func raw(_ value: Data) { data.append(value) }
}

struct BinaryReader {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        offset = data.startIndex
    }

    var isAtEnd: Bool { offset == data.endIndex }

    private mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, data.endIndex - offset >= count else { throw LiveLinkError.malformedMessage }
        let slice = data[offset..<offset + count]
        offset += count
        return slice
    }

    mutating func u8() throws -> UInt8 { try take(1).first! }

    mutating func u32() throws -> UInt32 {
        try take(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    mutating func i64() throws -> Int64 {
        Int64(bitPattern: try take(8).reduce(0) { $0 << 8 | UInt64($1) })
    }

    mutating func bytes() throws -> Data {
        let count = Int(try u32())
        return Data(try take(count))
    }

    mutating func string() throws -> String {
        guard let string = String(data: try bytes(), encoding: .utf8) else { throw LiveLinkError.malformedMessage }
        return string
    }

    mutating func remaining() -> Data {
        let rest = Data(data[offset...])
        offset = data.endIndex
        return rest
    }
}
