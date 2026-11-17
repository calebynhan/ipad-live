import AppKit

/// The full-window message shown whenever the iPad picture isn't live:
/// waiting for a cable, asking for permission, connecting, or an error.
final class StatusOverlayView: NSView {

    struct Content {
        var symbolName: String
        var title: String
        var message: String
        var showsSpinner = false
        var buttonTitle: String?
        var buttonAction: (() -> Void)?
    }

    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let button = NSButton(title: "", target: nil, action: nil)
    private var buttonAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor

        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 54, weight: .light)
        imageView.contentTintColor = NSColor(calibratedWhite: 0.6, alpha: 1)

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center

        messageLabel.font = .systemFont(ofSize: 14)
        messageLabel.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        messageLabel.alignment = .center
        messageLabel.isSelectable = false
        messageLabel.preferredMaxLayoutWidth = 400

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = #selector(buttonPressed)

        let stack = NSStackView(views: [imageView, titleLabel, messageLabel, spinner, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.setCustomSpacing(20, after: imageView)
        stack.setCustomSpacing(20, after: messageLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.init(490), for: .horizontal)
        stack.setHuggingPriority(.init(490), for: .vertical)
        addSubview(stack)

        // The insets are deliberately weaker than NSLayoutConstraint.Priority.windowSizeStayPut (500),
        // so this message can never stop the window from being resized to the iPad's shape.
        let leading = stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24)
        let trailing = stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24)
        leading.priority = .init(490)
        trailing.priority = .init(490)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leading,
            trailing,
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ content: Content) {
        imageView.image = NSImage(systemSymbolName: content.symbolName, accessibilityDescription: nil)
        imageView.isHidden = imageView.image == nil
        titleLabel.stringValue = content.title
        messageLabel.stringValue = content.message
        messageLabel.isHidden = content.message.isEmpty

        if content.showsSpinner {
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }

        buttonAction = content.buttonAction
        button.title = content.buttonTitle ?? ""
        button.isHidden = content.buttonTitle == nil
        isHidden = false
    }

    func hide() {
        spinner.stopAnimation(nil)
        isHidden = true
    }

    @objc private func buttonPressed() {
        buttonAction?()
    }
}

/// A small pill of text near the bottom of the window, e.g. "Unlock your iPad".
final class HintView: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0, alpha: 0.7).cgColor
        layer?.cornerRadius = 10

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    var text: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }
}
