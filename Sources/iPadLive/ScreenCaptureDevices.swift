import AVFoundation
import CoreMediaIO

/// Finding iPads (and iPhones) plugged in over USB.
///
/// macOS can expose the screen of a USB-connected iPad as a capture device, the same way
/// QuickTime Player's "New Movie Recording" does. The picture comes straight over the cable
/// at the iPad's native resolution, which is why it's far smoother than AirPlay or a
/// meeting app's own iPad sharing.
enum ScreenCaptureDevices {

    /// Ask macOS to publish iOS/iPadOS screens as capture devices. Off by default for every app.
    /// Devices show up asynchronously a moment later.
    @discardableResult
    static func enable() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        let status = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
        if status != 0 {
            NSLog("iPad Live: enabling screen capture devices failed (OSStatus %d)", status)
        }
        return status == 0
    }

    static func makeDiscoverySession() -> AVCaptureDevice.DiscoverySession {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: nil, position: .unspecified)
    }

    /// Connected iPad/iPhone screens. These are the "muxed" (video + audio) external devices;
    /// Continuity Camera and webcams are plain video devices, so they're excluded.
    static func connectedDevices(using discovery: AVCaptureDevice.DiscoverySession) -> [AVCaptureDevice] {
        var devices = discovery.devices.filter { $0.hasMediaType(.muxed) && $0.isConnected }
        if devices.isEmpty {
            // Fallback in case a macOS release stops listing screen devices in discovery sessions.
            devices = AVCaptureDevice.devices(for: .muxed).filter { $0.isConnected }
        }
        return devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }
}
