import CoreMedia
import CoreVideo
import Network
import VideoToolbox
import XCTest
@testable import LiveLink

/// End-to-end checks of the wireless pipeline on a Mac: message format, numeric-comparison
/// pairing, TLS-PSK streaming over a real loopback connection, and real H.264 encode → network → decode.
final class LiveLinkTests: XCTestCase {

    // MARK: - Message format

    func testEveryMessageRoundTrips() throws {
        let messages: [LiveLinkMessage] = [
            .hello(deviceName: "Caleb’s iPad 🖊"),
            .pairStart(deviceName: "iPad", publicKey: Data(repeating: 1, count: 32)),
            .pairCommit(publicKey: Data(repeating: 2, count: 32), commitment: Data(repeating: 3, count: 32)),
            .pairNonce(Data(repeating: 4, count: 32)),
            .pairConfirm(sealed: Data([5, 6, 7])),
            .pairResult(sealed: Data([8, 9])),
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

    func testStreamKeys() {
        XCTAssertEqual(LiveLinkSecurity.makeStreamKey().count, 32)
        XCTAssertNotEqual(LiveLinkSecurity.makeStreamKey(), LiveLinkSecurity.makeStreamKey())
    }

    func testOrientationToQuarterTurns() {
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 1), 0)
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 6), 1)
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 3), 2)
        XCTAssertEqual(VideoOrientation.clockwiseQuarterTurns(forOrientation: 8), 3)
    }

    // MARK: - Pairing crypto (numeric comparison)

    func testPairingExchangeAgreesOnTheCodeAndDeliversTheKey() throws {
        var iPad = PairingInitiator()
        var mac = try PairingResponder(initiatorKey: iPad.publicKey)
        let iPadNonce = try iPad.receiveCommit(responderKey: mac.publicKey, commitment: mac.commitment)
        let (macNonce, macCode) = try mac.receiveNonce(iPadNonce)
        let iPadCode = try iPad.receiveNonce(macNonce)
        XCTAssertEqual(iPadCode, macCode)
        XCTAssertEqual(iPadCode.count, 6)
        XCTAssertTrue(iPadCode.allSatisfy(\.isNumber))

        XCTAssertTrue(mac.openConfirmation(try iPad.sealConfirmation()))
        let result = PairingCrypto.Result(macID: "mac", macName: "Mac", deviceID: "dev", streamKey: LiveLinkSecurity.makeStreamKey())
        XCTAssertEqual(try iPad.openResult(try mac.sealResult(result)), result)
    }

    func testIPadRejectsANonceThatDoesNotMatchTheCommitment() throws {
        var iPad = PairingInitiator()
        let mac = try PairingResponder(initiatorKey: iPad.publicKey)
        _ = try iPad.receiveCommit(responderKey: mac.publicKey, commitment: mac.commitment)
        // Someone trying to steer the code by changing the nonce after committing:
        XCTAssertThrowsError(try iPad.receiveNonce(Data(repeating: 9, count: 32)))
    }

    func testAManInTheMiddleGetsMismatchedCodesAndCannotReadTheResult() throws {
        // The attacker runs one exchange with the iPad (posing as the Mac) and one with the Mac
        // (posing as the iPad). Each screen shows the code from a different exchange.
        var iPad = PairingInitiator()
        var fakeMac = try PairingResponder(initiatorKey: iPad.publicKey)
        let n1 = try iPad.receiveCommit(responderKey: fakeMac.publicKey, commitment: fakeMac.commitment)
        let (fakeMacNonce, _) = try fakeMac.receiveNonce(n1)
        let iPadCode = try iPad.receiveNonce(fakeMacNonce)

        var fakeIPad = PairingInitiator()
        var mac = try PairingResponder(initiatorKey: fakeIPad.publicKey)
        let n2 = try fakeIPad.receiveCommit(responderKey: mac.publicKey, commitment: mac.commitment)
        let (macNonce, macCode) = try mac.receiveNonce(n2)
        _ = try fakeIPad.receiveNonce(macNonce)

        // Codes match only by chance (1 in a million); with these fresh random values they won't.
        XCTAssertNotEqual(iPadCode, macCode)
        // The real Mac's result is sealed to its own exchange: the iPad's keys can't open it.
        let result = PairingCrypto.Result(macID: "mac", macName: "Mac", deviceID: "dev", streamKey: LiveLinkSecurity.makeStreamKey())
        XCTAssertThrowsError(try iPad.openResult(try mac.sealResult(result)))
        // And the iPad's confirmation means nothing to the real Mac.
        XCTAssertFalse(mac.openConfirmation(try iPad.sealConfirmation()))
    }

    // MARK: - Pairing over loopback

    func testPairingCompletesOnlyAfterBothSidesConfirmTheShownRequest() throws {
        let server = LiveLinkPairingServer(macID: "mac-1", macName: "Test Mac", advertise: false)
        let port = try listen(server)
        defer { server.stop() }

        let shown = Locked<PairingRequest?>(nil)
        let requested = expectation(description: "Mac shows the request")
        server.onRequest = { request in
            XCTAssertEqual(request.deviceName, "Test iPad")
            shown.set(request)
            requested.fulfill()
        }
        let macPaired = Locked<PairedDevice?>(nil)
        let paired = expectation(description: "Mac paired")
        server.onPaired = { device in
            macPaired.set(device)
            paired.fulfill()
        }

        let session = LiveLinkPairingSession(endpoint: loopback(port), deviceName: "Test iPad", queue: DispatchQueue(label: "pair"))
        let iPadCode = Locked<String?>(nil)
        let codeShown = expectation(description: "iPad shows the code")
        session.onCode = { code in
            iPadCode.set(code)
            codeShown.fulfill()
        }
        let iPadResult = Locked<PairingCrypto.Result?>(nil)
        let iPadPaired = expectation(description: "iPad paired")
        session.onPaired = { result in
            iPadResult.set(result)
            iPadPaired.fulfill()
        }
        session.onFailed = { XCTFail("pairing failed: \($0)") }
        session.start()

        wait(for: [requested, codeShown], timeout: 15)
        let request = try XCTUnwrap(shown.get())
        XCTAssertEqual(request.code, iPadCode.get())

        // The iPad confirms, and the Mac confirms some other (stale) request: nothing is handed over.
        let notYet = expectation(description: "not paired before the Mac confirms this request")
        notYet.isInverted = true
        server.onPaired = { _ in notYet.fulfill() }
        session.confirm()
        server.confirm(requestID: UUID())
        wait(for: [notYet], timeout: 1)

        // The Mac confirms the request on screen: now both get the same fresh key.
        server.onPaired = { device in
            macPaired.set(device)
            paired.fulfill()
        }
        server.confirm(requestID: request.id)
        wait(for: [paired, iPadPaired], timeout: 15)

        let device = try XCTUnwrap(macPaired.get())
        let result = try XCTUnwrap(iPadResult.get())
        XCTAssertEqual(result.macID, "mac-1")
        XCTAssertEqual(result.macName, "Test Mac")
        XCTAssertEqual(result.deviceID, device.deviceID)
        XCTAssertEqual(result.streamKey, device.streamKey)
        XCTAssertEqual(device.streamKey.count, 32)
    }

    func testMacDecliningFailsThePairing() throws {
        let server = LiveLinkPairingServer(macID: "mac-1", macName: "Test Mac", advertise: false)
        let port = try listen(server)
        defer { server.stop() }
        server.onRequest = { request in server.decline(requestID: request.id) }
        let notPaired = expectation(description: "never paired")
        notPaired.isInverted = true
        server.onPaired = { _ in notPaired.fulfill() }

        let session = LiveLinkPairingSession(endpoint: loopback(port), deviceName: "Test iPad", queue: DispatchQueue(label: "pair"))
        let failed = expectation(description: "iPad told pairing failed")
        session.onCode = { _ in session.confirm() }
        session.onPaired = { _ in XCTFail("paired after the Mac declined") }
        session.onFailed = { _ in failed.fulfill() }
        session.start()
        wait(for: [failed], timeout: 15)
        wait(for: [notPaired], timeout: 1)
    }

    func testASilentConnectionIsDroppedAndFreesPairing() throws {
        let server = LiveLinkPairingServer(macID: "mac-1", macName: "Test Mac", advertise: false, handshakeTimeout: 0.5)
        let port = try listen(server)
        defer { server.stop() }

        // Something connects and then says nothing, which would otherwise hold the only pairing slot.
        let silent = NWConnection(to: loopback(port), using: .tcp)
        let connected = expectation(description: "silent connection open")
        silent.stateUpdateHandler = { state in
            if case .ready = state { connected.fulfill() }
        }
        silent.start(queue: DispatchQueue(label: "silent"))
        wait(for: [connected], timeout: 10)
        defer { silent.cancel() }
        let pause = expectation(description: "let the time limit pass")
        pause.isInverted = true
        wait(for: [pause], timeout: 1.5)

        // A real iPad can now pair.
        let requested = expectation(description: "Mac shows the real request")
        server.onRequest = { _ in requested.fulfill() }
        let session = LiveLinkPairingSession(endpoint: loopback(port), deviceName: "Test iPad", queue: DispatchQueue(label: "pair"))
        session.onFailed = { XCTFail("pairing was blocked: \($0)") }
        session.start()
        wait(for: [requested], timeout: 10)
        session.onFailed = nil // cancelling below is expected, not a failure
        session.cancel()
    }

    func testARequestNobodyConfirmsTimesOut() throws {
        let server = LiveLinkPairingServer(macID: "mac-1", macName: "Test Mac", advertise: false, confirmationTimeout: 0.5)
        let port = try listen(server)
        defer { server.stop() }

        let ended = expectation(description: "Mac drops the request")
        server.onRequestEnded = { ended.fulfill() }
        let notPaired = expectation(description: "never paired")
        notPaired.isInverted = true
        server.onPaired = { _ in notPaired.fulfill() }

        let session = LiveLinkPairingSession(endpoint: loopback(port), deviceName: "Test iPad", queue: DispatchQueue(label: "pair"))
        let failed = expectation(description: "iPad told pairing failed")
        session.onFailed = { _ in failed.fulfill() }
        session.start()
        wait(for: [ended, failed], timeout: 10)
        wait(for: [notPaired], timeout: 0.5)
    }

    // MARK: - Streaming over loopback

    func testStreamWithTheRightKeyConnectsBothWays() throws {
        let device = PairedDevice(deviceID: "dev-1", name: "Test iPad", streamKey: LiveLinkSecurity.makeStreamKey())
        let server = LiveLinkStreamServer(devices: [device], macID: nil)
        let port = try listen(server)
        defer { server.stop() }

        let started = expectation(description: "stream started")
        server.onStreamStarted = { name in
            XCTAssertEqual(name, "Test iPad")
            started.fulfill()
            server.send(.requestKeyframe)
        }
        let queue = DispatchQueue(label: "client")
        let client = LiveLinkStreamClient(
            deviceID: device.deviceID, streamKey: device.streamKey, deviceName: "Test iPad",
            target: .endpoint(loopback(port)), queue: queue
        )
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
            XCTAssertEqual(suite, LiveLinkSecurity.cipherSuite, "streaming must use ECDHE-PSK")
            ready.fulfill()
        }
        client.start()
        wait(for: [ready, started, control], timeout: 15)
    }

    func testEachPairedIPadUsesItsOwnKey() throws {
        let first = PairedDevice(deviceID: "dev-1", name: "iPad 1", streamKey: LiveLinkSecurity.makeStreamKey())
        let second = PairedDevice(deviceID: "dev-2", name: "iPad 2", streamKey: LiveLinkSecurity.makeStreamKey())
        let server = LiveLinkStreamServer(devices: [first, second], macID: nil)
        let port = try listen(server)
        defer { server.stop() }

        let started = expectation(description: "second iPad streams")
        server.onStreamStarted = { name in
            if name == "iPad 2" { started.fulfill() }
        }
        let client = LiveLinkStreamClient(
            deviceID: second.deviceID, streamKey: second.streamKey, deviceName: "iPad 2",
            target: .endpoint(loopback(port)), queue: DispatchQueue(label: "client")
        )
        defer { client.stop() }
        client.start()
        wait(for: [started], timeout: 15)
    }

    func testStreamWithTheWrongKeyIsRefused() throws {
        let device = PairedDevice(deviceID: "dev-1", name: "Test iPad", streamKey: LiveLinkSecurity.makeStreamKey())
        let other = PairedDevice(deviceID: "dev-2", name: "Other iPad", streamKey: LiveLinkSecurity.makeStreamKey())
        let server = LiveLinkStreamServer(devices: [device, other], macID: nil)
        let port = try listen(server)
        defer { server.stop() }

        let notStarted = expectation(description: "stream never starts")
        notStarted.isInverted = true
        server.onStreamStarted = { _ in notStarted.fulfill() }

        // A paired device's ID with another device's key, and an unknown device: both refused.
        let attempts: [(String, Data)] = [
            (device.deviceID, other.streamKey),
            ("intruder", LiveLinkSecurity.makeStreamKey()),
        ]
        for (deviceID, key) in attempts {
            let client = LiveLinkStreamClient(
                deviceID: deviceID, streamKey: key, deviceName: "Intruder",
                target: .endpoint(loopback(port)), queue: DispatchQueue(label: "client")
            )
            let refused = expectation(description: "refused \(deviceID)")
            refused.assertForOverFulfill = false
            client.onDisconnected = { _ in refused.fulfill() }
            client.start()
            wait(for: [refused], timeout: 15)
            client.stop()
        }
        wait(for: [notStarted], timeout: 1)
    }

    // MARK: - Real video: encode → send → receive → decode

    func testEncodedVideoArrivesDecodable() throws {
        let device = PairedDevice(deviceID: "dev-1", name: "Test iPad", streamKey: LiveLinkSecurity.makeStreamKey())
        let server = LiveLinkStreamServer(devices: [device], macID: nil)
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
        let client = LiveLinkStreamClient(
            deviceID: device.deviceID, streamKey: device.streamKey, deviceName: "Test iPad",
            target: .endpoint(loopback(port)), queue: queue
        )
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
