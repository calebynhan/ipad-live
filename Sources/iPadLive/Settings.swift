import AppKit

/// The window background shown around the iPad picture.
enum BackgroundStyle: String, CaseIterable {
    case black
    case darkGray
    case white

    var title: String {
        switch self {
        case .black: return "Black"
        case .darkGray: return "Dark Gray"
        case .white: return "White"
        }
    }

    var color: NSColor {
        switch self {
        case .black: return .black
        case .darkGray: return NSColor(calibratedWhite: 0.16, alpha: 1)
        case .white: return .white
        }
    }
}

/// Preferences, remembered between launches.
enum Settings {
    private static var defaults: UserDefaults { .standard }

    private enum Key {
        static let lastDeviceID = "lastDeviceID"
        static let hideStatusBar = "hideStatusBar"
        static let lockAspectRatio = "lockAspectRatio"
        static let floatOnTop = "floatOnTop"
        static let playsAudio = "playsAudio"
        static let background = "background"
        static let lowLatency = "lowLatency"
        static let wirelessEnabled = "wirelessEnabled"
        static let wirelessMacID = "wirelessMacID"
        static let wirelessStreamKey = "wirelessStreamKey"
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.hideStatusBar: false,
            Key.lockAspectRatio: true,
            Key.floatOnTop: false,
            Key.playsAudio: false,
            Key.background: BackgroundStyle.black.rawValue,
            Key.lowLatency: true,
            Key.wirelessEnabled: true,
        ])
    }

    /// The device used last time, so it's picked first if several are plugged in.
    static var lastDeviceID: String? {
        get { defaults.string(forKey: Key.lastDeviceID) }
        set { defaults.set(newValue, forKey: Key.lastDeviceID) }
    }

    static var hideStatusBar: Bool {
        get { defaults.bool(forKey: Key.hideStatusBar) }
        set { defaults.set(newValue, forKey: Key.hideStatusBar) }
    }

    /// Keep the window the same shape as the iPad screen (no black bars), and
    /// reshape it automatically when the iPad rotates.
    static var lockAspectRatio: Bool {
        get { defaults.bool(forKey: Key.lockAspectRatio) }
        set { defaults.set(newValue, forKey: Key.lockAspectRatio) }
    }

    static var floatOnTop: Bool {
        get { defaults.bool(forKey: Key.floatOnTop) }
        set { defaults.set(newValue, forKey: Key.floatOnTop) }
    }

    static var playsAudio: Bool {
        get { defaults.bool(forKey: Key.playsAudio) }
        set { defaults.set(newValue, forKey: Key.playsAudio) }
    }

    /// Show each frame the instant it arrives (see FrameSink). Off = Apple's standard preview layer.
    static var lowLatency: Bool {
        get { defaults.bool(forKey: Key.lowLatency) }
        set { defaults.set(newValue, forKey: Key.lowLatency) }
    }

    /// Accept streams from paired iPads over Wi-Fi.
    static var wirelessEnabled: Bool {
        get { defaults.bool(forKey: Key.wirelessEnabled) }
        set { defaults.set(newValue, forKey: Key.wirelessEnabled) }
    }

    /// This Mac's ID, advertised over Bonjour so a paired iPad finds the right Mac.
    static var wirelessMacID: String {
        if let id = defaults.string(forKey: Key.wirelessMacID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.wirelessMacID)
        return id
    }

    /// The secret paired iPads use to stream to this Mac. `nil` until the first pairing.
    /// Kept in the app's preferences (readable only by your user account) rather than the keychain,
    /// because a self-built app would trigger a keychain password prompt after every rebuild.
    static var wirelessStreamKey: Data? {
        get { defaults.data(forKey: Key.wirelessStreamKey) }
        set { defaults.set(newValue, forKey: Key.wirelessStreamKey) }
    }

    static var background: BackgroundStyle {
        get { BackgroundStyle(rawValue: defaults.string(forKey: Key.background) ?? "") ?? .black }
        set { defaults.set(newValue.rawValue, forKey: Key.background) }
    }
}
