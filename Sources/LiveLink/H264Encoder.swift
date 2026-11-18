import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for latency rather than file size: low-latency rate control,
/// no frame reordering, no frame buffering, and speed over quality.
///
/// Used by the iPad's broadcast extension (and by the tests on the Mac).
public final class H264Encoder: @unchecked Sendable {

    public struct Output: Sendable {
        /// Sent with every keyframe, so a receiver that (re)joins mid-stream can always decode.
        public var format: VideoFormat?
        public var frame: VideoFrame
    }

    /// Called on VideoToolbox's thread for every encoded frame. Set before the first `encode`.
    public var onOutput: (@Sendable (Output) -> Void)?

    public let bitRate: Int
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var width = 0
    private var height = 0
    private var forceKeyframe = true

    public init(bitRate: Int = 16_000_000) {
        self.bitRate = bitRate
    }

    deinit {
        if let session { VTCompressionSessionInvalidate(session) }
    }

    /// The next encoded frame will be a keyframe (e.g. when a receiver connects).
    public func requestKeyframe() {
        lock.lock()
        forceKeyframe = true
        lock.unlock()
    }

    /// Returns `false` if no encoder could be created for this frame size.
    @discardableResult
    public func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime, orientation: UInt8) -> Bool {
        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)

        lock.lock()
        if session == nil || frameWidth != width || frameHeight != height {
            if let session { VTCompressionSessionInvalidate(session) }
            session = Self.makeSession(width: frameWidth, height: frameHeight, bitRate: bitRate)
            width = frameWidth
            height = frameHeight
            forceKeyframe = true
        }
        let session = self.session
        let keyframe = forceKeyframe
        forceKeyframe = false
        lock.unlock()

        guard let session else { return false }
        let properties: CFDictionary? = keyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame as String: true] as CFDictionary
            : nil
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self else { return }
            self.deliver(sampleBuffer, orientation: orientation)
        }
        if status != noErr { requestKeyframe() }
        return status == noErr
    }

    /// Waits until every frame passed to `encode` so far has been delivered.
    public func flush() {
        lock.lock()
        let session = self.session
        lock.unlock()
        if let session { VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid) }
    }

    public func invalidate() {
        lock.lock()
        if let session { VTCompressionSessionInvalidate(session) }
        session = nil
        lock.unlock()
    }

    private func deliver(_ sampleBuffer: CMSampleBuffer, orientation: UInt8) {
        guard let data = H264Packaging.frameData(from: sampleBuffer) else { return }
        let isKeyframe = H264Packaging.isKeyframe(sampleBuffer)
        var format: VideoFormat?
        if isKeyframe, let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            format = H264Packaging.videoFormat(from: description)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isNumeric ? Int64(pts.seconds * 1_000_000) : 0
        onOutput?(Output(
            format: format,
            frame: VideoFrame(isKeyframe: isKeyframe, orientation: orientation, presentationTimeMicros: micros, data: data)
        ))
    }

    private static func makeSession(width: Int, height: Int, bitRate: Int) -> VTCompressionSession? {
        var session: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl as String: true] as CFDictionary
        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatency,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if status != noErr || session == nil {
            // Low-latency rate control needs a hardware encoder; fall back to whatever is available.
            session = nil
            status = VTCompressionSessionCreate(
                allocator: nil,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else { return nil }

        // Each property is best-effort: encoders that don't support one just ignore it.
        let properties: [(CFString, CFTypeRef)] = [
            (kVTCompressionPropertyKey_RealTime, kCFBooleanTrue),
            (kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse),
            (kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber),
            (kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue),
            (kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel),
            (kVTCompressionPropertyKey_AverageBitRate, bitRate as CFNumber),
            (kVTCompressionPropertyKey_ExpectedFrameRate, 60 as CFNumber),
            (kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 5 as CFNumber),
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        return session
    }
}
