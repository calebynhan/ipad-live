import AppKit

/// The "Pair an iPad" sheet. It walks through: waiting for an iPad → compare the code → waiting
/// for the iPad to confirm.
@MainActor
final class PairingSheet {

    let window: NSWindow
    var onPair: (() -> Void)?
    var onCancel: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let codeLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let pairButton = NSButton(title: "Pair", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init() {
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.preferredMaxLayoutWidth = 372
        codeLabel.font = .monospacedDigitSystemFont(ofSize: 44, weight: .semibold)
        codeLabel.alignment = .center
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        pairButton.bezelStyle = .rounded
        pairButton.keyEquivalent = "\r"
        pairButton.target = self
        pairButton.action = #selector(pairPressed)
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)

        let buttons = NSStackView(views: [spinner, NSView(), cancelButton, pairButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [titleLabel, messageLabel, codeLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            messageLabel.widthAnchor.constraint(equalToConstant: 372),
            codeLabel.widthAnchor.constraint(equalTo: messageLabel.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: messageLabel.widthAnchor),
        ])
        window.contentView = content
    }

    /// Waiting for an iPad to start pairing.
    func showWaiting(note: String? = nil) {
        titleLabel.stringValue = "Pair an iPad"
        messageLabel.stringValue = (note.map { $0 + "\n\n" } ?? "")
            + "On your iPad, open iPad Live Sender and tap this Mac. Keep both on the same Wi-Fi."
        codeLabel.isHidden = true
        setBusy(true)
        pairButton.isHidden = true
    }

    /// An iPad asked to pair: the person must check its screen shows the same code.
    func showCode(deviceName: String, code: String) {
        titleLabel.stringValue = "Pair with “\(deviceName)”?"
        messageLabel.stringValue = "Check that your iPad shows the same code. If it does, click Pair here "
            + "and tap Pair on the iPad. If it doesn't, click Cancel: someone else may be trying to connect."
        codeLabel.stringValue = "\(code.prefix(3)) \(code.suffix(3))"
        codeLabel.isHidden = false
        setBusy(false)
        pairButton.isHidden = false
        pairButton.isEnabled = true
    }

    /// The Mac confirmed; waiting for the iPad's person to confirm too.
    func showWaitingForIPad() {
        messageLabel.stringValue = "Now tap Pair on your iPad."
        pairButton.isEnabled = false
        setBusy(true)
    }

    private func setBusy(_ busy: Bool) {
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func pairPressed() {
        onPair?()
    }

    @objc private func cancelPressed() {
        onCancel?()
    }
}
