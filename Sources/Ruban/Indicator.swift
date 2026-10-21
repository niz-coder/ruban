import AppKit
import RubanCore

/// The frosted bar that shows every column of the strip while you move around.
/// Hold the modifiers and it stays. Click a tile to jump there; drag a tile onto another to stack
/// the two columns, or between two tiles to move the column there.
final class StripIndicator {
    var onSelect: ((String, Int) -> Void)?
    var onDrop: ((String, Int, StripBarView.BarDrop) -> Void)?

    private var panel: NSPanel?
    private let bar = StripBarView()
    private var hideTimer: Timer?
    private var hideAt: CFTimeInterval = 0
    private var key = ""
    private var holdFlags: NSEvent.ModifierFlags = []
    /// What the bar shows right now; during a swipe it is asked to show the same thing every frame.
    private var signature = ""

    init() {
        bar.onSelect = { [weak self] column in
            guard let self else { return }
            self.onSelect?(self.key, column)
        }
        bar.onDrop = { [weak self] from, drop in
            guard let self else { return }
            self.onDrop?(self.key, from, drop)
        }
    }

    func show(key: String, strip: Strip, present: Set<WindowID>, windows: [WindowID: TrackedWindow],
              geometry g: Geometry, params: LayoutParams, holdWhile flags: NSEvent.ModifierFlags) {
        self.key = key
        holdFlags = flags
        var tiles: [StripBarView.Tile] = []
        for i in strip.liveColumns(present) {
            let c = strip.columns[i]
            let shown = c.windows.filter(present.contains)
            let icons = shown.prefix(3).compactMap { id -> NSImage? in
                windows[id].flatMap { NSRunningApplication(processIdentifier: $0.pid)?.icon }
            }
            let span = g.span(of: i)
            let visible: Bool = {
                guard let span else { return true } // pinned columns are always on screen
                return span.x + span.width > strip.scroll + 1 && span.x < strip.scroll + g.scrollWidth - 1
            }()
            tiles.append(.init(column: i, width: c.width, icons: icons, count: shown.count,
                               focused: i == strip.focused, visible: visible, pinned: c.pinned != nil, tabbed: c.tabbed))
        }
        guard !tiles.isEmpty else { return hide(animated: true) }
        hideAt = CACurrentMediaTime() + 0.9
        let sig = key + tiles.map { "\($0.column):\($0.width):\($0.focused):\($0.visible):\($0.pinned):\($0.tabbed):\($0.count)" }.joined(separator: ",")
        if sig == signature, let panel, panel.isVisible, hideTimer != nil { return }
        signature = sig
        bar.tiles = tiles

        let size = bar.fittingSize
        let panel = self.panel ?? makePanel()
        let cocoaArea = NSScreen.toCocoa(params.area)
        let origin = CGPoint(x: (cocoaArea.midX - size.width / 2).rounded(), y: cocoaArea.maxY - size.height - 14)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        bar.frame = CGRect(origin: .zero, size: size)
        bar.needsDisplay = true
        if !panel.isVisible || panel.alphaValue < 1 {
            panel.alphaValue = panel.isVisible ? panel.alphaValue : 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        guard hideTimer == nil else { return }
        // One timer while the bar is up, checking whether it is time to fade out.
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, CACurrentMediaTime() >= self.hideAt else { return }
            // Still holding ⌃⌥, or hovering the bar: keep it up.
            let held = NSEvent.modifierFlags.intersection([.control, .option, .command, .shift]).isSuperset(of: self.holdFlags)
            let hovering = self.panel.map { $0.frame.contains(NSEvent.mouseLocation) } ?? false
            if held || hovering || self.bar.isDragging { self.hideAt = CACurrentMediaTime() + 0.25 } else { self.hide(animated: true) }
        }
    }

    func hide(animated: Bool) {
        hideTimer?.invalidate()
        hideTimer = nil
        signature = ""
        guard let panel, panel.isVisible else { return }
        if !animated {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        effect.autoresizingMask = [.width, .height]
        bar.autoresizingMask = [.width, .height]
        effect.addSubview(bar)
        p.contentView = effect
        panel = p
        return p
    }
}

final class StripBarView: NSView {
    struct Tile {
        let column: Int
        let width: Double
        let icons: [NSImage]
        let count: Int
        let focused: Bool
        let visible: Bool
        let pinned: Bool
        let tabbed: Bool
    }

    /// Where a dragged tile lands, in strip column indices.
    enum BarDrop: Equatable {
        /// Onto a column: the dragged column joins its stack.
        case stack(into: Int)
        /// Left of a column (nil = at the end): the dragged column moves there.
        case before(Int?)
    }

    var tiles: [Tile] = [] { didSet { invalidateIntrinsicContentSize() } }
    var onSelect: ((Int) -> Void)?
    var onDrop: ((Int, BarDrop) -> Void)?
    var isDragging: Bool { dragFrom != nil && dragPoint != nil }

    private let padding: CGFloat = 10
    private let spacing: CGFloat = 6
    private let height: CGFloat = 46
    private var dragFrom: Int?
    private var dragPoint: CGPoint?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func tileWidth(_ t: Tile) -> CGFloat { min(max(CGFloat(t.width) * 104, 34), 104).rounded() }

    override var fittingSize: NSSize {
        let w = tiles.reduce(0) { $0 + tileWidth($1) } + spacing * CGFloat(max(tiles.count - 1, 0)) + padding * 2
        return NSSize(width: max(w, 60), height: height + padding * 2)
    }

    private func rects() -> [CGRect] {
        var x = padding
        return tiles.map { t in
            let r = CGRect(x: x, y: padding, width: tileWidth(t), height: height)
            x += r.width + spacing
            return r
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = NSColor.controlAccentColor
        for (t, r) in zip(tiles, rects()) {
            let path = NSBezierPath(roundedRect: r, xRadius: 9, yRadius: 9)
            let base: NSColor = t.focused ? accent.withAlphaComponent(0.55)
                : t.visible ? NSColor.white.withAlphaComponent(0.16) : NSColor.white.withAlphaComponent(0.06)
            base.setFill()
            path.fill()
            if t.focused {
                accent.setStroke()
                path.lineWidth = 2
                path.stroke()
            }
            let side: CGFloat = t.icons.count > 1 ? 22 : 30
            let total = CGFloat(t.icons.count) * side + CGFloat(max(t.icons.count - 1, 0)) * 2
            var y = r.midY - total / 2
            for icon in t.icons {
                icon.draw(in: CGRect(x: r.midX - side / 2, y: y, width: side, height: side))
                y += side + 2
            }
            if t.count > 3 {
                draw(badge: "\(t.count)", at: CGPoint(x: r.maxX - 4, y: r.minY + 4))
            }
            if t.pinned { draw(symbol: "pin.fill", at: CGPoint(x: r.minX + 4, y: r.minY + 4)) }
            if t.tabbed { draw(symbol: "rectangle.topthird.inset.filled", at: CGPoint(x: r.minX + 4, y: r.maxY - 14)) }
        }
        if let from = dragFrom, let p = dragPoint, let r = rects()[safe: from] {
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let ghost = NSBezierPath(roundedRect: r.offsetBy(dx: p.x - r.midX, dy: 0), xRadius: 9, yRadius: 9)
            ghost.lineWidth = 1.5
            ghost.stroke()
            drawLanding(drop(at: p, from: from), accent: accent)
        }
    }

    /// The landing spot of the tile being dragged: a ring around the tile it will stack onto,
    /// or a bar in the gap where it will be inserted.
    private func drawLanding(_ landing: BarDrop?, accent: NSColor) {
        let rs = rects()
        switch landing {
        case .stack(let column)?:
            guard let k = tiles.firstIndex(where: { $0.column == column }) else { return }
            let ring = NSBezierPath(roundedRect: rs[k].insetBy(dx: -2, dy: -2), xRadius: 11, yRadius: 11)
            accent.setStroke()
            ring.lineWidth = 3
            ring.stroke()
        case .before(let column)?:
            let x: CGFloat
            if let column, let k = tiles.firstIndex(where: { $0.column == column }) {
                x = rs[k].minX - spacing / 2
            } else if let last = rs.last {
                x = last.maxX + spacing / 2
            } else {
                return
            }
            accent.setFill()
            NSBezierPath(roundedRect: CGRect(x: x - 1.5, y: padding - 3, width: 3, height: height + 6), xRadius: 1.5, yRadius: 1.5).fill()
        case nil:
            break
        }
    }

    /// Shows the bar as if tile `from` were being dragged to `p` (for `--snapshot`).
    func simulateDrag(from: Int, to p: CGPoint) {
        dragFrom = from
        dragPoint = p
        needsDisplay = true
    }

    /// The centre of tile `k`, in the bar's coordinates.
    func tileCenter(_ k: Int) -> CGPoint {
        let r = rects()[k]
        return CGPoint(x: r.midX, y: r.midY)
    }

    /// What dropping the tile at index `from` at point `p` would do; nil when it would not move.
    func drop(at p: CGPoint, from: Int) -> BarDrop? {
        let rs = rects()
        var landing = BarDrop.before(nil)
        for (k, r) in rs.enumerated() {
            if p.x < r.minX {
                landing = .before(tiles[k].column)
                break
            }
            guard p.x <= r.maxX else { continue }
            let edge = max(r.width * 0.25, 8)
            if p.x < r.minX + edge {
                landing = .before(tiles[k].column)
            } else if p.x > r.maxX - edge {
                landing = .before(tiles[safe: k + 1]?.column)
            } else {
                landing = .stack(into: tiles[k].column)
            }
            break
        }
        let source = tiles[from].column
        switch landing {
        case .stack(let into) where into == source: return nil
        case .before(let column) where column == source || column == tiles[safe: from + 1]?.column: return nil
        default: return landing
        }
    }

    private func draw(symbol name: String, at p: CGPoint) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold)) else { return }
        let tinted = img.copy() as! NSImage
        tinted.lockFocus()
        NSColor.white.set()
        CGRect(origin: .zero, size: tinted.size).fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.draw(in: CGRect(origin: p, size: tinted.size))
    }

    private func draw(badge text: String, at topRight: CGPoint) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9, weight: .bold), .foregroundColor: NSColor.white]
        let s = NSAttributedString(string: text, attributes: attrs)
        s.draw(at: CGPoint(x: topRight.x - s.size().width, y: topRight.y))
    }

    private func index(at p: CGPoint) -> Int? {
        rects().firstIndex { $0.insetBy(dx: -spacing / 2, dy: -padding).contains(p) }
    }

    override func mouseDown(with event: NSEvent) {
        dragFrom = index(at: convert(event.locationInWindow, from: nil))
        dragPoint = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragFrom != nil else { return }
        dragPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragFrom = nil
            dragPoint = nil
            needsDisplay = true
        }
        let p = convert(event.locationInWindow, from: nil)
        guard let from = dragFrom else { return }
        if dragPoint == nil {
            if index(at: p) == from { onSelect?(tiles[from].column) }
        } else if let landing = drop(at: p, from: from) {
            onDrop?(tiles[from].column, landing)
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
