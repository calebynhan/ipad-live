import CoreGraphics
import XCTest
@testable import iPadLiveCore

final class MirrorGeometryTests: XCTestCase {

    // iPad Air 11" streams at its native 1640 x 2360.
    let portrait = CGSize(width: 1640, height: 2360)
    let landscape = CGSize(width: 2360, height: 1640)

    func testStatusBarCropAtNativeResolution() {
        XCTAssertEqual(MirrorGeometry.statusBarCropPixels(videoSize: portrait), 48)
        XCTAssertEqual(MirrorGeometry.statusBarCropPixels(videoSize: landscape), 48)
        XCTAssertEqual(MirrorGeometry.statusBarCropPixels(videoSize: CGSize(width: 2048, height: 2732)), 48)
    }

    func testStatusBarCropScalesWithSmallerStreams() {
        // Half of the iPad mini's native size -> half the crop.
        XCTAssertEqual(MirrorGeometry.statusBarCropPixels(videoSize: CGSize(width: 744, height: 1133)), 24)
        XCTAssertEqual(MirrorGeometry.statusBarCropPixels(videoSize: .zero), 0)
    }

    func testVisibleSize() {
        XCTAssertEqual(MirrorGeometry.visibleVideoSize(videoSize: portrait, hideStatusBar: false), portrait)
        XCTAssertEqual(
            MirrorGeometry.visibleVideoSize(videoSize: portrait, hideStatusBar: true),
            CGSize(width: 1640, height: 2312)
        )
    }

    func testLayoutAspectFitsAndCentres() {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let layout = MirrorGeometry.layout(videoSize: portrait, in: bounds, hideStatusBar: false)
        // Height-limited: 1000 tall, width = 1640/2360*1000.
        XCTAssertEqual(layout.clipFrame.height, 1000, accuracy: 0.001)
        XCTAssertEqual(layout.clipFrame.width, 1640.0 / 2360.0 * 1000, accuracy: 0.001)
        XCTAssertEqual(layout.clipFrame.midX, 500, accuracy: 0.001)
        XCTAssertEqual(layout.clipFrame.midY, 500, accuracy: 0.001)
        XCTAssertEqual(layout.videoFrame.size, layout.clipFrame.size)
        XCTAssertEqual(layout.videoFrame.origin, .zero)
    }

    func testLayoutWithHiddenStatusBarClipsTheTop() {
        let bounds = CGRect(x: 0, y: 0, width: 1640, height: 2312)
        let layout = MirrorGeometry.layout(videoSize: portrait, in: bounds, hideStatusBar: true)
        // The cropped picture exactly fills the bounds at 1:1...
        XCTAssertEqual(layout.clipFrame, bounds)
        // ...and the full video is 48px taller, starting at the bottom, so its top 48px are clipped.
        XCTAssertEqual(layout.videoFrame, CGRect(x: 0, y: 0, width: 1640, height: 2360))
        XCTAssertGreaterThan(layout.videoFrame.maxY, layout.clipFrame.height)
    }

    func testLayoutWithUnknownVideoFillsBounds() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let layout = MirrorGeometry.layout(videoSize: .zero, in: bounds, hideStatusBar: true)
        XCTAssertEqual(layout.clipFrame, bounds)
        XCTAssertEqual(layout.videoFrame, CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    func testFittedSizeKeepsAreaWhenRotating() {
        let portraitWindow = CGSize(width: 600, height: 863)
        let rotated = MirrorGeometry.fittedSize(
            aspect: landscape,
            preservingAreaOf: portraitWindow,
            maxSize: CGSize(width: 3000, height: 3000)
        )
        XCTAssertEqual(rotated.width / rotated.height, 2360.0 / 1640.0, accuracy: 0.01)
        let areaRatio = (rotated.width * rotated.height) / (portraitWindow.width * portraitWindow.height)
        XCTAssertEqual(areaRatio, 1, accuracy: 0.01)
    }

    func testFittedSizeRespectsMaximum() {
        let size = MirrorGeometry.fittedSize(
            aspect: portrait,
            preservingAreaOf: CGSize(width: 1400, height: 1400),
            maxSize: CGSize(width: 1300, height: 800)
        )
        XCTAssertLessThanOrEqual(size.height, 800)
        XCTAssertLessThanOrEqual(size.width, 1300)
        XCTAssertEqual(size.width / size.height, 1640.0 / 2360.0, accuracy: 0.01)
    }

    func testCenteredFrameStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = MirrorGeometry.centeredFrame(
            size: CGSize(width: 600, height: 800),
            around: CGPoint(x: 1400, y: 100),
            within: screen
        )
        XCTAssertEqual(frame.maxX, screen.maxX)
        XCTAssertEqual(frame.minY, screen.minY)
        XCTAssertEqual(frame.size, CGSize(width: 600, height: 800))
    }
}
