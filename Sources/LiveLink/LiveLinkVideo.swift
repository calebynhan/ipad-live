import CoreMedia
import Foundation
import VideoToolbox

// MARK: - Sending side: encoder output → LiveLink messages

public enum H264Packaging {

    /// The parameter sets (SPS, PPS) and size from an H.264 encoder's format description.
    public static func videoFormat(from description: CMFormatDescription) -> VideoFormat? {
        var count = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: nil
        ) == noErr, count > 0 else { return nil }

        var sets: [Data] = []
        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            sets.append(Data(bytes: pointer, count: size))
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return VideoFormat(codec: .h264, width: Int(dimensions.width), height: Int(dimensions.height), parameterSets: sets)
    }

    /// The compressed bytes of an encoded frame (length-prefixed NAL units).
    public static func frameData(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { buffer in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? data : nil
    }

    public static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[String: Any]],
              let first = attachments.first else { return true }
        return !((first[kCMSampleAttachmentKey_NotSync as String] as? Bool) ?? false)
    }
}

// MARK: - Receiving side: LiveLink messages → CMSampleBuffers a display layer can show

/// Rebuilds compressed `CMSampleBuffer`s from LiveLink messages. `AVSampleBufferDisplayLayer`
/// decodes them on the GPU itself, so the Mac never decompresses anything by hand.
public final class SampleBufferAssembler {
    public private(set) var format: VideoFormat?
    private var formatDescription: CMVideoFormatDescription?

    public init() {}

    public func setFormat(_ format: VideoFormat) throws {
        guard format != self.format else { return }
        guard format.codec == .h264, format.parameterSets.count >= 2,
              !format.parameterSets.contains(where: \.isEmpty) else {
            throw LiveLinkError.invalidVideoFormat
        }
        // Copy each parameter set into its own buffer so all the pointers stay valid together.
        let buffers: [UnsafeMutablePointer<UInt8>] = format.parameterSets.map { set in
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            return buffer
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers: [UnsafePointer<UInt8>] = buffers.map { UnsafePointer($0) }
        let sizes = format.parameterSets.map(\.count)

        var description: CMFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: pointers.count,
            parameterSetPointers: pointers,
            parameterSetSizes: sizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw LiveLinkError.invalidVideoFormat }
        self.format = format
        formatDescription = description
    }

    /// `nil` until a format has arrived, or if the frame is empty.
    public func sampleBuffer(for frame: VideoFrame) -> CMSampleBuffer? {
        guard let formatDescription, !frame.data.isEmpty else { return nil }
        let length = frame.data.count

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = frame.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: length
            )
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: frame.presentationTimeMicros, timescale: 1_000_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = length
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        if !frame.isKeyframe {
            setAttachment(kCMSampleAttachmentKey_NotSync, on: sampleBuffer)
        }
        return sampleBuffer
    }

    private func setAttachment(_ key: CFString, on sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}

// MARK: - Orientation

public enum VideoOrientation {
    /// Clockwise quarter turns needed to show a frame upright, from a `CGImagePropertyOrientation`
    /// raw value (1 = up, 6 = right, 3 = down, 8 = left). Mirrored orientations aren't used by
    /// screen capture and are treated as upright.
    public static func clockwiseQuarterTurns(forOrientation orientation: UInt8) -> Int {
        switch orientation {
        case 6: return 1
        case 3: return 2
        case 8: return 3
        default: return 0
        }
    }
}
