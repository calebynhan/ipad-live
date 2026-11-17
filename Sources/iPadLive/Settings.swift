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
    }

    static func registerDefaults() {
        defaults.register(defaults: [
            Key.hideStatusBar: false,
            Key.lockAspectRatio: true,
            Key.floatOnTop: false,
            Key.playsAudio: false,
            Key.background: BackgroundStyle.black.rawValue,
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

    static var background: BackgroundStyle {
        get { BackgroundStyle(rawValue: defaults.string(forKey: Key.background) ?? "") ?? .black }
        set { defaults.set(newValue.rawValue, forKey: Key.background) }
    }
}
