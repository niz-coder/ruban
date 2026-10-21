import AppKit
import RubanCore

/// While you drag a window, a translucent rectangle shows where it will land when you let go.
/// It sits right under the dragged window, like macOS's own tiling preview.
final class DropPreview {
    private var window: NSWindow?
    private(set) var isVisible = false

    func show(frameAX: CGRect, below draggedWindow: WindowID) {
        let w = window ?? make()
        let frame = NSScreen.toCocoa(frameAX)
        if isVisible {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                w.animator().setFrame(frame, display: true)
            }
        } else {
            w.setFrame(frame, display: true)
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.1
                w.animator().alphaValue = 1
            }
            isVisible = true
        }
        w.order(.below, relativeTo: Int(draggedWindow))
    }

    func hide() {
        guard isVisible, let w = window else { return }
        isVisible = false
        w.orderOut(nil)
    }

    private func make() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let v = NSView()
        v.wantsLayer = true
        if let layer = v.layer {
            let accent = NSColor.controlAccentColor
            layer.backgroundColor = accent.withAlphaComponent(0.2).cgColor
            layer.borderColor = accent.withAlphaComponent(0.85).cgColor
            layer.borderWidth = 2
            layer.cornerRadius = 12
            layer.cornerCurve = .continuous
        }
        w.contentView = v
        window = w
        return w
    }
}
