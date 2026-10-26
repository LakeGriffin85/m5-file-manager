import AppKit

enum InterfaceTheme {
    static let background = NSColor(calibratedRed: 192 / 255, green: 229 / 255, blue: 240 / 255, alpha: 1)
    static let blue = NSColor(calibratedRed: 0, green: 112 / 255, blue: 185 / 255, alpha: 1)
    static let ink = NSColor(calibratedRed: 8 / 255, green: 45 / 255, blue: 59 / 255, alpha: 1)

    static func configure(_ button: NSButton) {
        let title = button.title, target = button.target, action = button.action
        let image = button.image, position = button.imagePosition, enabled = button.isEnabled
        let key = button.keyEquivalent, modifiers = button.keyEquivalentModifierMask
        if let popup = button as? NSPopUpButton {
            button.cell = InterfacePopupCell(textCell: title, pullsDown: popup.pullsDown)
        } else {
            button.cell = InterfaceButtonCell(textCell: title)
            button.setButtonType(.momentaryPushIn)
        }
        button.target = target; button.action = action
        button.image = image; button.imagePosition = position; button.isEnabled = enabled
        button.keyEquivalent = key; button.keyEquivalentModifierMask = modifiers
        button.bezelStyle = .rounded; button.contentTintColor = .white
    }

    static func drawButton(_ frame: NSRect, enabled: Bool, highlighted: Bool) {
        let shape = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        let color = highlighted ? blue.blended(withFraction: 0.18, of: ink)! : blue
        (enabled ? color : color.withAlphaComponent(0.35)).setFill()
        shape.fill()
        ink.withAlphaComponent(enabled ? 1 : 0.35).setStroke()
        shape.lineWidth = 1.5; shape.stroke()
    }

    static func title(_ original: NSAttributedString, enabled: Bool) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: original)
        text.addAttributes([.foregroundColor: enabled ? NSColor.white : ink.withAlphaComponent(0.65),
                            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)], range: NSRange(location: 0, length: text.length))
        return text
    }
}

final class InterfaceButtonCell: NSButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        InterfaceTheme.drawButton(frame, enabled: isEnabled, highlighted: isHighlighted)
    }
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(InterfaceTheme.title(title, enabled: isEnabled), withFrame: frame, in: controlView)
    }
}

final class InterfacePopupCell: NSPopUpButtonCell {
    override func drawBezel(withFrame frame: NSRect, in controlView: NSView) {
        InterfaceTheme.drawButton(frame, enabled: isEnabled, highlighted: isHighlighted)
    }
    override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in controlView: NSView) -> NSRect {
        super.drawTitle(InterfaceTheme.title(title, enabled: isEnabled), withFrame: frame, in: controlView)
    }
}

final class InterfaceBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        InterfaceTheme.background.setFill(); bounds.fill()
    }
}

/// Neutral title rendered with the system font; no personal artwork.
final class PixelTitleView: NSView {
    override var intrinsicContentSize: NSSize { NSSize(width: 580, height: 78) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        ("M5 File Manager" as NSString).draw(at: NSPoint(x: 12, y: 22), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 32, weight: .bold), .foregroundColor: InterfaceTheme.ink])
    }
}
