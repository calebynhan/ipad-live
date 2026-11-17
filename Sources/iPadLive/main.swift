import AppKit

// Top-level code runs on the main thread; tell the compiler so it can call main-actor code.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    NSWindow.allowsAutomaticWindowTabbing = false
    withExtendedLifetime(delegate) {
        app.run()
    }
}
