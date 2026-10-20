import AppKit

/// An optional coloured outline around the focused window. Off until you turn it on.
final class FocusBorder {
    private var window: NSWindow?

    func show(frameAX: CGRect, width: Double) {
        let w = window ?? make()
        let inset = -CGFloat(width) / 2
        w.setFrame(NSScreen.toCocoa(frameAX).insetBy(dx: inset, dy: inset), display: true)
        if let layer = w.contentView?.layer {
            layer.borderWidth = CGFloat(width)
            layer.borderColor = NSColor.controlAccentColor.cgColor
        }
        w.orderFrontRegardless()
    }

    func hide() { window?.orderOut(nil) }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.cornerRadius = 14
        v.layer?.cornerCurve = .continuous
        w.contentView = v
        window = w
        return w
    }
}
