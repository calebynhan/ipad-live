import CoreMedia
import CoreVideo
import Network
import VideoToolbox
import XCTest
@testable import LiveLink

/// End-to-end checks of the wireless pipeline on a Mac: message format, TLS-PSK pairing and
/// streaming over a real loopback connection, and real H.264 encode → network → decode.
final class LiveLinkTests: XCTestCase {

    // MARK: - Message format

    func testEveryMessageRoundTrips() throws {
        let messages: [LiveLinkMessage] = [
            .hello(deviceName: "Caleb’s iPad 🖊"),
            .pairAccepted(macID: "ABC-123", macName: "MacBook", streamKey: Data(repeating: 7, count: 32)),
            .videoFormat(VideoFormat(codec: .h264, width: 1640, height: 2360, parameterSets: [Data([1, 2, 3]), Data([4, 5])])),
            .videoFrame(VideoFrame(isKeyframe: true, orientation: 6, presentationTimeMicros: -42, data: Data([9, 8, 7, 6]))),
            .videoFrame(VideoFrame(isKeyframe: false, orientation: 1, presentationTimeMicros: 1 << 40, data: Data([0]))),
            .control(.requestKeyframe),
            .control(.pause),
            .control(.resume),
        ]
        for message in messages {
            let wire = message.encoded()
            let header = try LiveLinkMessage.Header(wire.prefix(LiveLinkMessage.headerLength))
            XCTAssertEqual(header.payloadLength, wire.count - LiveLinkMessage.headerLength)
            let decoded = try LiveLinkMessage.decode(type: header.type, payload: wire.dropFirst(LiveLinkMessage.headerLength))
            XCTAssertEqual(decoded, message)
        }
    }

    func testOversizedPayloadIsRejected() {
        var header = Data([4])
        header.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertThrowsError(try LiveLinkMessage.Header(header))
    }

    func testTruncatedPayloadThrows() {
        let wire = LiveLinkMessage.hello(deviceName: "iPad").encoded()
        XCTAssertThrowsError(try LiveLinkMessage.decode(type: wire[0], payload: wire.dropFirst(5).dropLast()))
    }

    func testUnknownMessageTypeIsIgnored() throws {
        XCTAssertNil(try LiveLinkMessage.decode(type: 200, payload: Data([1, 2, 3])))
    }

    // MARK: - Keys

    func testPairingCodes() {
        let code = LiveLinkSecurity.makePairingCode()
        XCTAssertEqual(code.count, 6)
        XCTAssertTrue(code.allSatisfy(\.isNumber))
        XCTAssertEqual(LiveLinkSecurity.pairingKey(code: "123 456"), LiveLinkSecurity.pairingKey(code: "123456"))
        XCTAssertNotEqual(LiveLinkSecurity.pairingKey(code: "123456"), LiveLinkSecurity.pairingKey(code: "123457"))
        XCTAssertEqual(LiveLinkSecurity.pairingKey(code: "123456").count, 32)
        XCTAssertEqual(LiveLinkSecurity.makeStreamKey().count, 32)
        XCTAssertNotEqual(LiveLinkSecurity.makeStreamKey(), LiveLinkSecurity.makeStreamKey())
    }

    func testOrientationToQuarterTurns() {
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 1), 0)
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 6), 1)
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 3), 2)
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 8), 3)
    }

    // MARK: - Pairing over loopback

    func testPairingWithTheRightCodeHandsOverTheStreamKey() throws {
        let streamKey = LiveLinkSecurity.makeStreamKey()
        let server = LiveLinkPairingServer(code: "482913", macID: "mac-1", macName: "Test Mac", streamKey: streamKey, advertise: false)
        let port = try listen(server)
        defer { server.stop() }

        let paired = expectation(description: "server saw the pairing")
        server.onPaired = { name in
            XCTAssertEqual(name, "Test iPad")
            paired.fulfill()
        }
        let result = expectation(description: "iPad got the key")
        LiveLinkPairing.pair(with: loopback(port), code: "482 913", deviceName: "Test iPad", queue: DispatchQueue(label: "pair")) { outcome in
            switch outcome {
            case .success(let pairing):
                XCTAssertEqual(pairing, LiveLinkPairing.Result(macID: "mac-1", macName: "Test Mac", streamKey: streamKey))
            case .failure(let error):
                XCTFail("pairing failed: \(error)")
            }
            result.fulfill()
        }
        wait(for: [paired, result], timeout: 15)
    }

    func testPairingWithTheWrongCodeFails() throws {
        let server = LiveLinkPairingServer(code: "482913", macID: "mac-1", macName: "Test Mac", streamKey: LiveLinkSecurity.makeStreamKey(), advertise: false)
        let port = try listen(server)
        defer { server.stop() }

        let notPaired = expectation(description: "never paired")
        notPaired.isInverted = true
        server.onPaired = { _ in notPaired.fulfill() }
        let counted = expectation(description: "failed attempt counted")
        server.onFailedAttempt = { count in
            XCTAssertEqual(count, 1)
            counted.fulfill()
        }
        let result = expectation(description: "iPad was refused")
        LiveLinkPairing.pair(with: loopback(port), code: "111111", deviceName: "Intruder", queue: DispatchQueue(label: "pair")) { outcome in
            if case .success = outcome { XCTFail("paired with the wrong code") }
            result.fulfill()
        }
        wait(for: [result, counted], timeout: 15)
        wait(for: [notPaired], timeout: 1)
    }

    // MARK: - Streaming over loopback

    func testStreamWithTheRightKeyConnectsBothWays() throws {
        let key = LiveLinkSecurity.makeStreamKey()
        let server = LiveLinkStreamServer(streamKey: key, macID: nil)
        let port = try listen(server)
        defer { server.stop() }

        let started = expectation(description: "stream started")
        server.onStreamStarted = { name in
            XCTAssertEqual(name, "Test iPad")
            started.fulfill()
            server.send(.requestKeyframe)
        }
        let queue = DispatchQueue(label: "client")
        let client = LiveLinkStreamClient(streamKey: key, deviceName: "Test iPad", target: .endpoint(loopback(port)), queue: queue)
        defer { client.stop() }
        let control = expectation(description: "iPad received a command")
        client.onControl = { command in
            XCTAssertEqual(command, .requestKeyframe)
            control.fulfill()
        }
        let ready = expectation(description: "client ready")
        client.onReady = {
            let suite = client.negotiatedCipherSuite
            print("LiveLink negotiated TLS cipher suite: \(suite.map { String(format: "0x%04X", $0) } ?? "unknown")")
            XCTAssertTrue(suite == LiveLinkSecurity.ecdhePSKSuite || suite == LiveLinkSecurity.pskSuite)
            ready.fulfill()
        }
        client.start()
        wait(for: [ready, started, control], timeout: 15)
    }

    func testStreamWithTheWrongKeyIsRefused() throws {
        let server = LiveLinkStreamServer(streamKey: LiveLinkSecurity.makeStreamKey(), macID: nil)
        let port = try listen(server)
        defer { server.stop() }

        let notStarted = expectation(description: "stream never starts")
        notStarted.isInverted = true
        server.onStreamStarted = { _ in notStarted.fulfill() }

        let client = LiveLinkStreamClient(
            streamKey: LiveLinkSecurity.makeStreamKey(),
            deviceName: "Intruder",
            target: .endpoint(loopback(port)),
            queue: DispatchQueue(label: "client")
        )
        let refused = expectation(description: "client disconnected")
        refused.assertForOverFulfill = false
        client.onDisconnected = { _ in refused.fulfill() }
        client.start()
        wait(for: [refused], timeout: 15)
        client.stop()
        wait(for: [notStarted], timeout: 1)
    }

    // MARK: - Real video: encode → send → receive → decode

    func testEncodedVideoArrivesDecodable() throws {
        let key = LiveLinkSecurity.makeStreamKey()
        let server = LiveLinkStreamServer(streamKey: key, macID: nil)
        let port = try listen(server)
        defer { server.stop() }

        let received = Locked<[CMSampleBuffer]>([])
        let info = Locked<(Int, Int, UInt8)?>(nil)
        let gotFrames = expectation(description: "frames arrived")
        server.onVideoInfo = { width, height, orientation in info.set((width, height, orientation)) }
        server.onFrame = { sampleBuffer in
            if received.mutate({ $0.append(sampleBuffer); return $0.count }) == 5 { gotFrames.fulfill() }
        }

        let queue = DispatchQueue(label: "client")
        let client = LiveLinkStreamClient(streamKey: key, deviceName: "Test iPad", target: .endpoint(loopback(port)), queue: queue)
        defer { client.stop() }
        let ready = expectation(description: "client ready")
        client.onReady = { ready.fulfill() }
        client.start()
        wait(for: [ready], timeout: 15)

        let encoder = H264Encoder(bitRate: 2_000_000)
        encoder.onOutput = { output in
            queue.async {
                if let format = output.format { client.send(.videoFormat(format)) }
                client.send(.videoFrame(output.frame))
            }
        }
        for index in 0..<12 {
            let pixelBuffer = try makePixelBuffer(width: 640, height: 480, shade: UInt8(index * 20))
            guard encoder.encode(pixelBuffer, presentationTime: CMTime(value: Int64(index), timescale: 60), orientation: 6) else {
                throw XCTSkip("No H.264 encoder available on this machine")
            }
        }
        encoder.flush()
        wait(for: [gotFrames], timeout: 20)

        let firstInfo = try XCTUnwrap(info.get())
        XCTAssertEqual(firstInfo.0, 640)
        XCTAssertEqual(firstInfo.1, 480)
        XCTAssertEqual(firstInfo.2, 6)

        let first = try XCTUnwrap(received.get().first)
        XCTAssertTrue(isSync(first), "the first frame must be a keyframe")
        let decoded = try XCTUnwrap(decodeSize(of: first), "the first frame should decode")
        XCTAssertEqual(decoded.0, 640)
        XCTAssertEqual(decoded.1, 480)
    }

    // MARK: - Helpers

    private func loopback(_ port: NWEndpoint.Port) -> NWEndpoint {
        .hostPort(host: "127.0.0.1", port: port)
    }

    private func listen(_ server: LiveLinkStreamServer) throws -> NWEndpoint.Port {
        let port = Locked<NWEndpoint.Port?>(nil)
        let listening = expectation(description: "listening")
        server.onListening = { port.set($0); listening.fulfill() }
        server.onListenerFailed = { XCTFail("listener failed: \($0)") }
        server.start()
        wait(for: [listening], timeout: 10)
        return try XCTUnwrap(port.get())
    }

    private func listen(_ server: LiveLinkPairingServer) throws -> NWEndpoint.Port {
        let port = Locked<NWEndpoint.Port?>(nil)
        let listening = expectation(description: "listening")
        server.onListening = { port.set($0); listening.fulfill() }
        server.onListenerFailed = { XCTFail("listener failed: \($0)") }
        server.start()
        wait(for: [listening], timeout: 10)
        return try XCTUnwrap(port.get())
    }

    private func makePixelBuffer(width: Int, height: Int, shade: UInt8) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attributes, &pixelBuffer)
        let buffer = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { continue }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for row in 0..<rows {
                for column in 0..<bytesPerRow {
                    bytes[row * bytesPerRow + column] = plane == 0 ? UInt8(truncatingIfNeeded: row + column + Int(shade)) : 128
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private func isSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false)
    }

    private func decodeSize(of sampleBuffer: CMSampleBuffer) -> (Int, Int)? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary
        guard VTDecompressionSessionCreate(
            allocator: nil,
            formatDescription: description,
            decoderSpecification: nil,
            imageBufferAttributes: attributes,
            outputCallback: nil,
            decompressionSessionOut: &session
        ) == noErr, let session else { return nil }
        defer { VTDecompressionSessionInvalidate(session) }

        let size = Locked<(Int, Int)?>(nil)
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [], infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer {
                size.set((CVPixelBufferGetWidth(imageBuffer), CVPixelBufferGetHeight(imageBuffer)))
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        return status == noErr ? size.get() : nil
    }
}

/// A value shared with callbacks on other queues.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func mutate<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
