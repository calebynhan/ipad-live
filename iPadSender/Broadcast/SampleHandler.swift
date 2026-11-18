import CoreMedia
import CoreVideo
import ReplayKit

/// The broadcast upload extension. While you broadcast, iPadOS hands it every frame of the whole
/// screen (any app, including Concepts). It encodes them with the low-latency hardware encoder
/// and streams them to the paired Mac.
///
/// Delay is kept down by only ever encoding the newest frame: if the network is still busy, older
/// frames are skipped rather than queued.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {

    private let queue = DispatchQueue(label: "app.ipadlive.broadcast", qos: .userInteractive)
    private let encoder = H264Encoder()

    // Touched only on `queue`.
    private var client: LiveLinkStreamClient?
    private var paused = false
    private var hasConnected = false

    // Shared between ReplayKit's thread and `queue`, guarded by `frameLock`.
    private let frameLock = NSLock()
    private var latestFrame: (pixelBuffer: CVPixelBuffer, time: CMTime, orientation: UInt8)?
    private var latestFrameNumber = 0
    private var sentFrameNumber = 0
    private var drainScheduled = false

    /// Never hand the network more than this; skip frames instead, so delay can't build up.
    private let maxPendingBytes = 1_500_000

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard let mac = PairedMacStore.load() else {
            fail("Open iPad Live Sender and pair with your Mac first.")
            return
        }
        encoder.onOutput = { output in
            self.queue.async { self.send(output) }
        }
        queue.sync {
            let client = LiveLinkStreamClient(
                streamKey: mac.streamKey,
                deviceName: mac.deviceName,
                target: .bonjour(macID: mac.macID),
                queue: queue
            )
            client.onReady = {
                self.hasConnected = true
                self.sendCurrentScreen()
            }
            client.onControl = { command in self.handle(command) }
            client.onSendCompleted = { self.drain() }
            self.client = client
            client.start()
        }
        // If the Mac never answers, say why instead of broadcasting into the void.
        queue.asyncAfter(deadline: .now() + 20) {
            guard !self.hasConnected, self.client != nil else { return }
            self.fail("Couldn't find \(mac.macName). Make sure iPad Live is open on your Mac, "
                + "Wi-Fi streaming is allowed there, and both are on the same Wi-Fi.")
        }
    }

    override func broadcastFinished() {
        queue.sync {
            client?.stop()
            client = nil
        }
        encoder.onOutput = nil
        encoder.invalidate()
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = (CMGetAttachment(
            sampleBuffer,
            key: RPVideoSampleOrientationKey as CFString,
            attachmentModeOut: nil
        ) as? NSNumber)?.uint8Value ?? 1

        frameLock.lock()
        latestFrame = (pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), orientation)
        latestFrameNumber += 1
        let schedule = !drainScheduled
        drainScheduled = true
        frameLock.unlock()
        if schedule {
            queue.async { self.drain() }
        }
    }

    // MARK: - On `queue`

    /// Encodes the newest captured frame if it hasn't been sent and the network can take it.
    private func drain() {
        frameLock.lock()
        drainScheduled = false
        let number = latestFrameNumber
        let frame = number > sentFrameNumber ? latestFrame : nil
        frameLock.unlock()

        guard let frame, let client, client.isReady, !paused, client.pendingBytes < maxPendingBytes else { return }

        frameLock.lock()
        sentFrameNumber = max(sentFrameNumber, number)
        frameLock.unlock()
        encoder.encode(frame.pixelBuffer, presentationTime: frame.time, orientation: frame.orientation)
    }

    /// Re-sends what's on screen right now as a keyframe: when the Mac connects or resumes, the
    /// screen may be still, and the iPad only produces frames when something changes.
    private func sendCurrentScreen() {
        encoder.requestKeyframe()
        frameLock.lock()
        sentFrameNumber = 0
        frameLock.unlock()
        drain()
    }

    private func send(_ output: H264Encoder.Output) {
        guard let client, client.isReady, !paused else { return }
        if let format = output.format { client.send(.videoFormat(format)) }
        client.send(.videoFrame(output.frame))
    }

    private func handle(_ command: ControlCommand) {
        switch command {
        case .requestKeyframe:
            sendCurrentScreen()
        case .pause:
            paused = true
        case .resume:
            paused = false
            sendCurrentScreen()
        }
    }

    private func fail(_ message: String) {
        finishBroadcastWithError(NSError(domain: "iPadLive", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }
}
