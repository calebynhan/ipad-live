import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {

    private var mirror: MirrorSession!
    private var windowController: MirrorWindowController!
    private var pairingSheet: PairingSheet?
    private let deviceMenu = NSMenu(title: "Device")
    private let deviceItemTag = 1001

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.registerDefaults()

        mirror = MirrorSession()
        windowController = MirrorWindowController(mirror: mirror)
        mirror.onDevicesChange = { [weak self] in self?.rebuildDeviceItems() }
        mirror.onAudioPermissionDenied = { [weak self] in self?.showMicrophoneDeniedAlert() }

        NSApp.mainMenu = makeMainMenu()
        windowController.showWindow(nil)
        NSApp.activate()

        mirror.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mirror?.stop()
    }

    // MARK: - Menu actions

    @objc private func fitWindowToIPad(_ sender: Any?) {
        windowController.fitWindowToVideo(animated: true)
    }

    @objc private func toggleLockAspectRatio(_ sender: Any?) {
        windowController.toggleLockAspectRatio()
    }

    @objc private func toggleHideStatusBar(_ sender: Any?) {
        windowController.toggleHideStatusBar()
    }

    @objc private func toggleLowLatency(_ sender: Any?) {
        mirror.setLowLatency(!mirror.lowLatency)
    }

    @objc private func toggleFloatOnTop(_ sender: Any?) {
        windowController.toggleFloatOnTop()
    }

    @objc private func chooseBackground(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = BackgroundStyle(rawValue: raw) else { return }
        windowController.setBackground(style)
    }

    @objc private func chooseDevice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        mirror.select(deviceID: id)
    }

    @objc private func reconnect(_ sender: Any?) {
        mirror.reconnect()
    }

    @objc private func togglePlayAudio(_ sender: Any?) {
        mirror.setPlaysAudio(!mirror.playsAudio)
    }

    // MARK: Wi-Fi

    @objc private func pairWirelessly(_ sender: Any?) {
        windowController.showWindow(nil)
        guard let window = windowController.window, window.attachedSheet == nil else { return }

        let sheet = PairingSheet()
        pairingSheet = sheet
        sheet.onPair = { [weak self, weak sheet] in
            self?.mirror.wireless.confirmPairing()
            sheet?.showWaitingForIPad()
        }
        sheet.onCancel = { [weak self] in
            self?.mirror.wireless.cancelPairing()
            self?.closePairingSheet()
        }
        mirror.wireless.beginPairing { [weak self] event in
            guard let self else { return }
            switch event {
            case .request(let deviceName, let code):
                self.pairingSheet?.showCode(deviceName: deviceName, code: code)
            case .requestEnded:
                self.pairingSheet?.showWaiting(note: "The iPad stopped pairing.")
            case .paired(let deviceName):
                self.closePairingSheet()
                self.showPairingAlert(
                    title: "Paired with \(deviceName)",
                    message: "To stream over Wi-Fi, open iPad Live Sender on your iPad and tap Start Streaming. "
                        + "The cable still works too, and takes over whenever it's plugged in."
                )
            case .failed(let message):
                self.closePairingSheet()
                self.showPairingAlert(title: "Couldn't Start Pairing", message: message)
            }
        }
        sheet.showWaiting()
        window.beginSheet(sheet.window)
    }

    private func closePairingSheet() {
        guard let sheet = pairingSheet else { return }
        pairingSheet = nil
        sheet.onPair = nil
        sheet.onCancel = nil
        windowController.window?.endSheet(sheet.window)
    }

    private func showPairingAlert(title: String, message: String) {
        // Let the pairing sheet finish closing first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                guard let window = self.windowController.window, window.attachedSheet == nil else { return }
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = message
                alert.beginSheetModal(for: window)
            }
        }
    }

    @objc private func toggleWireless(_ sender: Any?) {
        mirror.wireless.setEnabled(!mirror.wireless.isEnabled)
    }

    @objc private func forgetWirelessDevices(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Forget Paired iPads?"
        alert.informativeText = "iPads you've paired won't be able to stream to this Mac over Wi-Fi until you pair them again."
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            mirror.wireless.forgetPairedDevices()
        }
    }

    @objc private func showWindow(_ sender: Any?) {
        windowController.showWindow(nil)
    }

    @objc private func showSharingTips(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Tips for a Smooth Share"
        let wifiTip = mirror.wireless.isAvailable
            ? " For Wi-Fi, pair once with Device → Pair iPad Wirelessly, then tap Start Streaming in "
                + "iPad Live Sender. Plugging in the cable switches back to it."
            : ""
        alert.informativeText = """
        In your meeting app, share the “iPad Live” window (or your whole screen).

        • Zoom: Share Screen → pick “iPad Live”. Tick “Optimize for video clip” \
        (bottom-left of the share picker) so drawing looks smooth to others.
        • Google Meet: Share screen → Window → “iPad Live”.
        • FaceTime: Share Screen → Window, then click the iPad Live window.

        On your iPad:
        • Use a USB cable that carries data. That's what keeps it lag-free.\(wifiTip)
        • Settings → Display & Brightness → Auto-Lock → Never, so the screen doesn't sleep.
        • Turn on Do Not Disturb so notifications don't pop up while you share.

        On this Mac:
        • View → Low-Latency Mode (⌘L) is on by default. It shows each frame the instant it arrives.
        • View → Hide iPad Status Bar trims the clock and battery off the top.
        • Double-click the picture for full screen. Drag anywhere to move the window.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showMicrophoneDeniedAlert() {
        let alert = NSAlert()
        alert.messageText = "Microphone Access Is Off"
        alert.informativeText = "macOS treats a plugged-in iPad's sound like a microphone. "
            + "To hear your iPad through this Mac, turn on iPad Live in "
            + "System Settings → Privacy & Security → Microphone, then try again."
        alert.addButton(withTitle: "Open Privacy Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Menu state

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        switch action {
        case #selector(fitWindowToIPad(_:)):
            return windowController.canFitWindow
        case #selector(toggleLockAspectRatio(_:)):
            menuItem.state = Settings.lockAspectRatio ? .on : .off
        case #selector(toggleHideStatusBar(_:)):
            menuItem.state = Settings.hideStatusBar ? .on : .off
        case #selector(toggleFloatOnTop(_:)):
            menuItem.state = Settings.floatOnTop ? .on : .off
        case #selector(toggleLowLatency(_:)):
            menuItem.state = mirror.lowLatency ? .on : .off
        case #selector(chooseBackground(_:)):
            menuItem.state = (menuItem.representedObject as? String) == Settings.background.rawValue ? .on : .off
        case #selector(chooseDevice(_:)):
            menuItem.state = (menuItem.representedObject as? String) == mirror.activeDevice?.uniqueID ? .on : .off
        case #selector(togglePlayAudio(_:)):
            menuItem.state = mirror.playsAudio ? .on : .off
        case #selector(toggleWireless(_:)):
            menuItem.state = mirror.wireless.isEnabled ? .on : .off
        case #selector(forgetWirelessDevices(_:)):
            return mirror.wireless.isPaired
        default:
            break
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === deviceMenu { rebuildDeviceItems() }
    }

    /// The top of the Device menu lists every connected iPad/iPhone.
    private func rebuildDeviceItems() {
        while let item = deviceMenu.items.first, item.tag == deviceItemTag {
            deviceMenu.removeItem(item)
        }
        var items: [NSMenuItem] = []
        if mirror.devices.isEmpty {
            let none = NSMenuItem(title: "No iPad Connected", action: nil, keyEquivalent: "")
            none.isEnabled = false
            items.append(none)
        } else {
            for device in mirror.devices {
                let item = NSMenuItem(title: device.localizedName, action: #selector(chooseDevice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = device.uniqueID
                items.append(item)
            }
        }
        items.append(.separator())
        for (index, item) in items.enumerated() {
            item.tag = deviceItemTag
            deviceMenu.insertItem(item, at: index)
        }
    }

    // MARK: - Building the menu bar

    private func makeMainMenu() -> NSMenu {
        let mainMenu = NSMenu()

        // iPad Live
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About iPad Live",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide iPad Live", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others",
                                         action: #selector(NSApplication.hideOtherApplications(_:)),
                                         keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit iPad Live", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(appMenu, titled: "iPad Live", to: mainMenu)

        // View
        let viewMenu = NSMenu(title: "View")
        addItem("Fit Window to iPad", #selector(fitWindowToIPad(_:)), key: "0", to: viewMenu)
        addItem("Keep iPad Shape", #selector(toggleLockAspectRatio(_:)), key: "", to: viewMenu)
        viewMenu.addItem(.separator())
        addItem("Low-Latency Mode", #selector(toggleLowLatency(_:)), key: "l", to: viewMenu)
        addItem("Hide iPad Status Bar", #selector(toggleHideStatusBar(_:)), key: "b", to: viewMenu)
        let backgroundMenu = NSMenu(title: "Background")
        for style in BackgroundStyle.allCases {
            let item = addItem(style.title, #selector(chooseBackground(_:)), key: "", to: backgroundMenu)
            item.representedObject = style.rawValue
        }
        let backgroundItem = viewMenu.addItem(withTitle: "Background", action: nil, keyEquivalent: "")
        backgroundItem.submenu = backgroundMenu
        viewMenu.addItem(.separator())
        let floatItem = addItem("Float on Top", #selector(toggleFloatOnTop(_:)), key: "t", to: viewMenu)
        floatItem.keyEquivalentModifierMask = [.command, .option]
        let fullScreen = viewMenu.addItem(withTitle: "Enter Full Screen",
                                          action: #selector(NSWindow.toggleFullScreen(_:)),
                                          keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        addSubmenu(viewMenu, titled: "View", to: mainMenu)

        // Device
        deviceMenu.delegate = self
        addItem("Reconnect", #selector(reconnect(_:)), key: "r", to: deviceMenu)
        deviceMenu.addItem(.separator())
        addItem("Play iPad Sound on This Mac", #selector(togglePlayAudio(_:)), key: "", to: deviceMenu)
        if mirror.wireless.isAvailable { // experimental; off by default (see Settings.wirelessFeature)
            deviceMenu.addItem(.separator())
            addItem("Pair iPad Wirelessly…", #selector(pairWirelessly(_:)), key: "", to: deviceMenu)
            addItem("Allow Wi-Fi Streaming", #selector(toggleWireless(_:)), key: "", to: deviceMenu)
            addItem("Forget Paired iPads…", #selector(forgetWirelessDevices(_:)), key: "", to: deviceMenu)
        }
        addSubmenu(deviceMenu, titled: "Device", to: mainMenu)
        rebuildDeviceItems()

        // Window
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(.separator())
        addItem("iPad Live", #selector(showWindow(_:)), key: "1", to: windowMenu)
        addSubmenu(windowMenu, titled: "Window", to: mainMenu)
        NSApp.windowsMenu = windowMenu

        // Help
        let helpMenu = NSMenu(title: "Help")
        addItem("Tips for a Smooth Share", #selector(showSharingTips(_:)), key: "", to: helpMenu)
        addSubmenu(helpMenu, titled: "Help", to: mainMenu)
        NSApp.helpMenu = helpMenu

        return mainMenu
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, key: String, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ submenu: NSMenu, titled title: String, to mainMenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        mainMenu.addItem(item)
    }
}
