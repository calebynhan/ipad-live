import AppKit
import AVFoundation
import iPadLiveCore

/// Shows the live iPad picture.
///
/// There are two ways frames can reach the screen (only both briefly, while switching):
/// - Low-Latency Mode (default): `FrameSink`'s `AVSampleBufferDisplayLayer`, which shows each
///   frame the instant it arrives.
/// - Standard: Apple's `AVCaptureVideoPreviewLayer`, kept so the two can be compared, and as a
///   fallback.
/// Both sit inside a clipping layer so the iPad's status bar can be trimmed off.
final class MirrorView: NSView {

    private let session: AVCaptureSession
    private let displayLayer: AVSampleBufferDisplayLayer
    private let previewLayer = AVCaptureVideoPreviewLayer()
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

    /// Clockwise quarter turns applied to the low-latency layer. The wireless stream always arrives
    /// in portrait plus a rotation; `videoSize` is the size after rotating.
    var videoRotation = 0 {
        didSet { if videoRotation != oldValue { updateLayerFrames() } }
    }

    init(session: AVCaptureSession, displayLayer: AVSampleBufferDisplayLayer) {
        self.session = session
        self.displayLayer = displayLayer
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
        clipLayer.addSublayer(displayLayer) // added last, so it draws on top
        rootLayer.addSublayer(clipLayer)
        setRenderState(previewAttached: false, showsLowLatencyLayer: true)
        updateLayerFrames()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// `previewAttached`: connect Apple's standard preview layer to the capture session (it sits
    /// underneath). It's only attached while needed, so the two paths don't both process frames.
    /// `showsLowLatencyLayer`: show Low-Latency Mode's layer, on top.
    func setRenderState(previewAttached: Bool, showsLowLatencyLayer: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.isHidden = !previewAttached
        displayLayer.isHidden = !showsLowLatencyLayer
        CATransaction.commit()
        let wanted: AVCaptureSession? = previewAttached ? session : nil
        if previewLayer.session !== wanted {
            previewLayer.session = wanted
        }
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
        let frame = layout.videoFrame
        previewLayer.frame = frame
        // Rotate the low-latency layer about its centre. CALayer angles are counterclockwise here.
        let turns = ((videoRotation % 4) + 4) % 4
        displayLayer.setAffineTransform(.identity)
        displayLayer.bounds = CGRect(
            origin: .zero,
            size: turns % 2 == 1 ? CGSize(width: frame.height, height: frame.width) : frame.size
        )
        displayLayer.position = CGPoint(x: frame.midX, y: frame.midY)
        displayLayer.setAffineTransform(CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2))
        CATransaction.commit()
    }
}
