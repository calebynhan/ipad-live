import AppKit
import AVFoundation
import iPadLiveCore

/// Shows the live iPad picture.
///
/// It uses `AVCaptureVideoPreviewLayer`, which hands frames from the capture device straight to
/// the window server on the GPU: no copying, no re-encoding. That's the lowest-latency way to put
/// a capture device on screen on macOS. The preview layer sits inside a clipping layer so the
/// iPad's status bar can be trimmed off.
final class MirrorView: NSView {

    let previewLayer: AVCaptureVideoPreviewLayer
    private let rootLayer = CALayer()
    private let clipLayer = CALayer()

    /// Pixel size of the incoming video. `nil` until the first frame format is known.
    var videoSize: CGSize? {
        didSet { if videoSize != oldValue { updateLayerFrames() } }
    }

    var hideStatusBar = false {
        didSet { if hideStatusBar != oldValue { updateLayerFrames() } }
    }

    var fillColor: NSColor = .black {
        didSet { rootLayer.backgroundColor = fillColor.cgColor }
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

        // Layer-hosting view: we own the layer tree, AppKit just keeps the root sized to the view.
        rootLayer.isGeometryFlipped = false
        rootLayer.backgroundColor = fillColor.cgColor
        layer = rootLayer
        wantsLayer = true
        layerContentsRedrawPolicy = .never

        clipLayer.masksToBounds = true
        clipLayer.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor

        clipLayer.addSublayer(previewLayer)
        rootLayer.addSublayer(clipLayer)
        updateLayerFrames()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLayerFrames()
    }

    override func layout() {
        super.layout()
        updateLayerFrames()
    }

    private func updateLayerFrames() {
        CATransaction.begin()
        CATransaction.setDisableActions(true) // no implicit animations while resizing
        let layout = MirrorGeometry.layout(
            videoSize: videoSize ?? .zero,
            in: bounds,
            hideStatusBar: hideStatusBar
        )
        clipLayer.frame = layout.clipFrame
        previewLayer.frame = layout.videoFrame
        CATransaction.commit()
    }
}
