import AppKit
import CoreGraphics

final class AgentTabView: NSView {
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "The agent tab appears here.")
    private let caption = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // The capture is a fixed 1280x720 image; it must not impose that size
        // on the window. Let Auto Layout shrink it to whatever room the tab
        // view has.
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentHuggingPriority(.defaultLow, for: axis)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: axis)
            setContentHuggingPriority(.defaultLow, for: axis)
            setContentCompressionResistancePriority(.defaultLow, for: axis)
        }
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .secondaryLabelColor
        placeholder.font = .systemFont(ofSize: 13)
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.textColor = .secondaryLabelColor
        caption.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        addSubview(imageView)
        addSubview(placeholder)
        addSubview(caption)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            imageView.bottomAnchor.constraint(equalTo: caption.topAnchor, constant: -6),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            caption.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func show(_ capture: Capture) {
        if ProcessInfo.processInfo.environment["AGENT_BROWSER_TRACE_LAYERS"] != nil {
            AgentLog.write(
                "tab show image=\(capture.image.width)x\(capture.image.height) viewport=\(Int(capture.viewport.width))x\(Int(capture.viewport.height)) tab-bounds=\(bounds) window=\(String(describing: window?.frame))"
            )
        }
        placeholder.isHidden = true
        imageView.image = NSImage(cgImage: capture.image, size: capture.viewport)
        caption.stringValue = capture.caption
    }

    func showPlaceholder(_ text: String) {
        imageView.image = nil
        placeholder.stringValue = text
        placeholder.isHidden = false
        caption.stringValue = ""
    }
}
