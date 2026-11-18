@preconcurrency import AVFoundation
import CoreMedia

/// The low-latency picture path ("Low-Latency Mode").
///
/// Frames from the capture session's video data output go straight into an
/// `AVSampleBufferDisplayLayer`, each one marked "display immediately", so nothing holds a frame
/// back to line it up with timestamps or audio. If the Mac ever falls behind, the data output
/// drops late frames instead of queueing them, so the picture never drifts further behind.
///
/// Everything here runs on `queue`, off the main thread.
final class FrameSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {

    /// Where the frames are drawn. `MirrorView` puts it in the window.
    let displayLayer: AVSampleBufferDisplayLayer
    let queue = DispatchQueue(label: "app.ipadlive.frames", qos: .userInteractive)

    /// Reports the picture's size (called on `queue`): whenever it changes, e.g. when the iPad
    /// rotates, and every half second or so, so a size is never missed after a reconnect.
    /// Set once, before capture starts.
    var onSizeChange: (@Sendable (CGSize) -> Void)?

    private let renderer: AVSampleBufferVideoRenderer
    // Only touched on `queue`.
    private var lastSize: CGSize = .zero
    private var framesSinceSizeReport = 0
    private var nextFrameCallback: (@Sendable () -> Void)?
    private var nextFrameNotBefore = DispatchTime.now()
    private var acceptsExternal = false

    /// Called (on `queue`) when the wireless stream needs a fresh keyframe to recover from a decode error.
    var onExternalNeedsKeyframe: (@Sendable () -> Void)?

    override init() {
        let layer = AVSampleBufferDisplayLayer()
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        displayLayer = layer
        renderer = layer.sampleBufferRenderer
        super.init()
    }

    /// Clears the picture, e.g. when the iPad is unplugged, so an old frame never flashes up later.
    func reset() {
        queue.async {
            self.lastSize = .zero
            self.nextFrameCallback = nil
            self.renderer.flush(removingDisplayedImage: true, completionHandler: {})
        }
    }

    /// Calls `callback` (on `queue`) right after the first frame that arrives at least `delay`
    /// seconds from now has been handed to the display layer. Used to switch picture paths without
    /// a blank moment: the iPad only sends frames when its screen changes. A newer request replaces
    /// an older one.
    func notifyOnNextFrame(after delay: TimeInterval = 0, _ callback: @escaping @Sendable () -> Void) {
        let notBefore = DispatchTime.now() + delay
        queue.async {
            self.nextFrameNotBefore = notBefore
            self.nextFrameCallback = callback
        }
    }

    // MARK: - Wireless frames

    /// Whether frames from the wireless stream are shown. Switching flushes the picture, so frames
    /// from the cable and from Wi-Fi never mix.
    func setAcceptsExternal(_ accepts: Bool) {
        queue.async {
            guard accepts != self.acceptsExternal else { return }
            self.acceptsExternal = accepts
            self.renderer.flush()
        }
    }

    /// A compressed frame from the wireless stream; the display layer decodes it on the GPU.
    func enqueueExternal(_ sampleBuffer: CMSampleBuffer) {
        queue.async {
            guard self.acceptsExternal else { return }
            Self.markForImmediateDisplay(sampleBuffer)
            if self.renderer.status == .failed || self.renderer.requiresFlushToResumeDecoding {
                self.renderer.flush()
                self.onExternalNeedsKeyframe?()
            }
            self.renderer.enqueue(sampleBuffer)
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        Self.markForImmediateDisplay(sampleBuffer)
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
        }
        renderer.enqueue(sampleBuffer)

        if let callback = nextFrameCallback, DispatchTime.now() >= nextFrameNotBefore {
            nextFrameCallback = nil
            callback()
        }

        if let description = CMSampleBufferGetFormatDescription(sampleBuffer) {
            let size = CMVideoFormatDescriptionGetPresentationDimensions(
                description,
                usePixelAspectRatio: false,
                useCleanAperture: true
            )
            framesSinceSizeReport += 1
            if size.width > 0, size.height > 0, size != lastSize || framesSinceSizeReport >= 30 {
                lastSize = size
                framesSinceSizeReport = 0
                onSizeChange?(size)
            }
        }
    }

    /// Tells the display layer to show this frame as soon as it's decoded, ignoring its timestamp.
    private static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }
}
