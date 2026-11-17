import CoreGraphics

/// Layout math for showing the iPad's picture inside a Mac window.
///
/// Everything here uses AppKit/Core Animation's default coordinate space:
/// the origin is the bottom-left corner and y grows upwards.
public enum MirrorGeometry {

    /// How many rows of video to hide at the top when "Hide iPad Status Bar" is on.
    ///
    /// iPads draw at 2x and their status bar is 24pt tall (20pt on Home-button models),
    /// so at the native resolution the iPad streams over USB that is 48 pixels.
    /// If the stream is ever smaller than native, the crop shrinks with it.
    public static func statusBarCropPixels(videoSize: CGSize) -> CGFloat {
        let shortSide = min(videoSize.width, videoSize.height)
        guard shortSide > 0 else { return 0 }
        let nativeCrop: CGFloat = 48
        let smallestNativeShortSide: CGFloat = 1488 // iPad mini, the smallest current iPad screen
        if shortSide >= smallestNativeShortSide { return nativeCrop }
        return (nativeCrop * shortSide / smallestNativeShortSide).rounded()
    }

    /// The size of the part of the video that is actually shown.
    public static func visibleVideoSize(videoSize: CGSize, hideStatusBar: Bool) -> CGSize {
        let crop = hideStatusBar ? statusBarCropPixels(videoSize: videoSize) : 0
        return CGSize(width: videoSize.width, height: max(1, videoSize.height - crop))
    }

    public struct Layout: Equatable {
        /// Where the visible picture sits in the view. Anything outside it is clipped.
        public var clipFrame: CGRect
        /// Where the full, uncropped video sits, relative to `clipFrame`'s bottom-left corner.
        /// When the status bar is hidden this is taller than `clipFrame`, and the extra
        /// (the status bar) sticks out above the top edge and gets clipped.
        public var videoFrame: CGRect

        public init(clipFrame: CGRect, videoFrame: CGRect) {
            self.clipFrame = clipFrame
            self.videoFrame = videoFrame
        }
    }

    /// Aspect-fits the video into `bounds`, centred, optionally cropping the iPad status bar.
    public static func layout(videoSize: CGSize, in bounds: CGRect, hideStatusBar: Bool) -> Layout {
        guard videoSize.width > 0, videoSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            return Layout(clipFrame: bounds, videoFrame: CGRect(origin: .zero, size: bounds.size))
        }
        let visible = visibleVideoSize(videoSize: videoSize, hideStatusBar: hideStatusBar)
        let scale = min(bounds.width / visible.width, bounds.height / visible.height)
        let clipSize = CGSize(width: visible.width * scale, height: visible.height * scale)
        let clipOrigin = CGPoint(
            x: bounds.minX + (bounds.width - clipSize.width) / 2,
            y: bounds.minY + (bounds.height - clipSize.height) / 2
        )
        let videoFrame = CGRect(x: 0, y: 0, width: videoSize.width * scale, height: videoSize.height * scale)
        return Layout(clipFrame: CGRect(origin: clipOrigin, size: clipSize), videoFrame: videoFrame)
    }

    /// A window size with the given aspect ratio and roughly the same area as `current`,
    /// shrunk if needed to fit in `maxSize`.
    ///
    /// Keeping the area (rather than the width or height) means that when the iPad rotates,
    /// a portrait window turns into a landscape window of about the same visual size.
    public static func fittedSize(
        aspect: CGSize,
        preservingAreaOf current: CGSize,
        maxSize: CGSize,
        minSize: CGSize = CGSize(width: 240, height: 240)
    ) -> CGSize {
        guard aspect.width > 0, aspect.height > 0 else { return current }
        let ratio = aspect.width / aspect.height
        let area = max(current.width * current.height, minSize.width * minSize.height)
        var height = (area / ratio).squareRoot()
        var width = height * ratio
        if maxSize.width > 0, maxSize.height > 0 {
            let shrink = min(1, maxSize.width / width, maxSize.height / height)
            width *= shrink
            height *= shrink
        }
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    /// A rect of `size` centred on `center`, nudged so it stays inside `container` when possible.
    public static func centeredFrame(size: CGSize, around center: CGPoint, within container: CGRect) -> CGRect {
        var origin = CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2)
        if size.width <= container.width {
            origin.x = min(max(origin.x, container.minX), container.maxX - size.width)
        }
        if size.height <= container.height {
            origin.y = min(max(origin.y, container.minY), container.maxY - size.height)
        }
        return CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: size)
    }
}
