import CoreGraphics
import Foundation

/// Everything the layout needs to know about one display. Rects use the
/// Accessibility coordinate space: origin at the top-left of the main display, y grows down.
public struct LayoutParams: Equatable, Sendable {
    /// Usable area of the display (menu bar and Dock excluded).
    public var area: CGRect
    /// Full frame of the display, used to park off-screen windows at its edge.
    public var screen: CGRect
    public var gap: Double
    public var centre: CentreMode

    public init(area: CGRect, screen: CGRect, gap: Double, centre: CentreMode) {
        self.area = area
        self.screen = screen
        self.gap = gap
        self.centre = centre
    }

    public var inner: CGRect { area.insetBy(dx: gap, dy: gap) }
}

/// A column's place on the strip, in strip coordinates (x = 0 is the first column).
public struct Span: Equatable, Sendable {
    public var column: Int
    public var x: Double
    public var width: Double
}

public struct Geometry: Equatable, Sendable {
    /// Screen x where strip x = 0 lands when the scroll offset is 0.
    public var scrollMinX: Double
    /// Width of the scrolling part of the screen (pinned columns excluded).
    public var scrollWidth: Double
    public var spans: [Span]
    public var pinned: [Int: CGRect]
    /// Width of the whole strip.
    public var total: Double

    public var maxScroll: Double { max(0, total - scrollWidth) }

    public func span(of column: Int) -> Span? { spans.first { $0.column == column } }

    /// The part of the screen windows scroll through. Anything outside it gets parked.
    public func scrollRegion(_ p: LayoutParams) -> CGRect {
        CGRect(x: scrollMinX, y: p.area.minY, width: scrollWidth, height: p.area.height)
    }
}

public enum Layout {
    public static let minColumnWidth = 160.0
    /// How much of a parked window stays on screen. macOS pulls back any window that is
    /// entirely off screen to 40 pt, but leaves a 1 pt sliver alone.
    public static let parkSliver = 1.0

    /// A fraction of 0.5 means two columns fill the screen exactly, gap included.
    public static func pixelWidth(_ fraction: Double, inner: Double, gap: Double) -> Double {
        (fraction * (inner + gap) - gap).rounded()
    }

    /// The width fraction that matches a window that is `width` points wide.
    public static func fraction(forWidth width: Double, inner: Double, gap: Double) -> Double {
        min(max((width + gap) / (inner + gap), 0.1), 1)
    }

    public static func geometry(_ strip: Strip, present: Set<WindowID>, _ p: LayoutParams) -> Geometry {
        let inner = p.inner
        var minX = inner.minX, maxX = inner.maxX
        var pinned: [Int: CGRect] = [:]

        for (i, c) in strip.columns.enumerated() where c.isLive(present) {
            guard let side = c.pinned else { continue }
            let w = min(max(pixelWidth(c.width, inner: inner.width, gap: p.gap), minColumnWidth), (inner.width * 0.6).rounded())
            switch side {
            case .left:
                pinned[i] = CGRect(x: minX, y: inner.minY, width: w, height: inner.height)
                minX += w + p.gap
            case .right:
                pinned[i] = CGRect(x: maxX - w, y: inner.minY, width: w, height: inner.height)
                maxX -= w + p.gap
            }
        }

        let scrollWidth = max(maxX - minX, minColumnWidth)
        var spans: [Span] = []
        var x = 0.0
        for (i, c) in strip.columns.enumerated() where c.pinned == nil && c.isLive(present) {
            let w = min(max(pixelWidth(c.width, inner: inner.width, gap: p.gap), minColumnWidth), scrollWidth)
            spans.append(Span(column: i, x: x, width: w))
            x += w + p.gap
        }
        let total = spans.isEmpty ? 0 : x - p.gap
        return Geometry(scrollMinX: minX, scrollWidth: scrollWidth, spans: spans, pinned: pinned, total: total)
    }

    /// The scroll offset that brings the focused column into view, moving as little as the centre mode allows.
    public static func revealScroll(_ g: Geometry, focused: Int, current: Double, mode: CentreMode) -> Double {
        guard let f = g.span(of: focused) else { return min(max(current, 0), g.maxScroll) }
        let v = g.scrollWidth
        switch mode {
        case .always:
            return (f.x + f.width / 2 - v / 2).rounded()
        case .onOverflow:
            if g.total <= v { return 0 }
            return min(max((f.x + f.width / 2 - v / 2).rounded(), 0), g.maxScroll)
        case .never:
            var s = current
            if f.x + f.width > s + v { s = f.x + f.width - v }
            if f.x < s { s = f.x }
            return min(max(s, 0), g.maxScroll)
        }
    }

    /// The scroll offset that puts the focused column in the middle of the screen.
    public static func centreScroll(_ g: Geometry, focused: Int, current: Double) -> Double {
        guard let f = g.span(of: focused) else { return current }
        return (f.x + f.width / 2 - g.scrollWidth / 2).rounded()
    }

    /// Where a free scroll (trackpad) should come to rest, and which column then gets focus.
    public static func snap(_ g: Geometry, scroll: Double, focused: Int, mode: CentreMode) -> (scroll: Double, focused: Int)? {
        guard !g.spans.isEmpty else { return nil }
        let v = g.scrollWidth
        if mode == .always {
            let centre = scroll + v / 2
            let best = g.spans.min { abs($0.x + $0.width / 2 - centre) < abs($1.x + $1.width / 2 - centre) }!
            return ((best.x + best.width / 2 - v / 2).rounded(), best.column)
        }
        let best = g.spans.min { abs($0.x - scroll) < abs($1.x - scroll) }!
        let s = min(max(best.x, 0), g.maxScroll)
        func visible(_ span: Span) -> Double {
            max(0, min(span.x + span.width, s + v) - max(span.x, s))
        }
        if let f = g.span(of: focused), visible(f) >= f.width - 1 { return (s, focused) }
        let most = g.spans.max { visible($0) < visible($1) }!
        return (s, most.column)
    }

    /// Heights for the windows of a stack: shared by weight, but never below a window's minimum
    /// (some apps refuse to get shorter). Nil when the minimums alone don't fit in `total`.
    public static func stackHeights(total: Double, gap: Double, weights: [Double], minimums: [Double]) -> [Double]? {
        let n = weights.count
        let available = total - gap * Double(max(n - 1, 0))
        guard n > 0, minimums.reduce(0, +) <= available + 0.5 else { return nil }
        // Windows whose share falls below their minimum get the minimum; the rest share what is left.
        var fixed = [Double?](repeating: nil, count: n)
        while true {
            let free = (0..<n).filter { fixed[$0] == nil }
            let remaining = available - fixed.compactMap { $0 }.reduce(0, +)
            let weightSum = free.reduce(0.0) { $0 + weights[$1] }
            var changed = false
            for i in free where remaining * weights[i] / weightSum < minimums[i] {
                fixed[i] = minimums[i]
                changed = true
            }
            if !changed || free.isEmpty {
                return (0..<n).map { fixed[$0] ?? remaining * weights[$0] / weightSum }
            }
        }
    }

    /// Whether a column shows its windows one above the other. A tabbed column doesn't, and neither
    /// does a stack whose windows' minimum heights can't all fit on screen: it falls back to tabs.
    public static func showsStacked(_ c: Column, present: Set<WindowID>, minHeights: [WindowID: Double], height: Double, gap: Double) -> Bool {
        let live = c.windows.enumerated().filter { present.contains($0.element) }
        guard !c.tabbed, live.count > 1 else { return false }
        return stackHeights(total: height, gap: gap, weights: live.map { c.weights[$0.offset] },
                            minimums: live.map { minHeights[$0.element] ?? 0 }) != nil
    }

    /// Target frame of every present window for a given scroll offset. `minHeights` holds the heights
    /// apps refused to go below.
    public static func frames(_ strip: Strip, present: Set<WindowID>, _ p: LayoutParams, geometry g: Geometry, scroll: Double,
                              minHeights: [WindowID: Double] = [:]) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]

        func place(_ c: Column, in rect: CGRect) {
            let live = c.windows.enumerated().filter { present.contains($0.element) }
            guard !live.isEmpty else { return }
            let heights = c.tabbed || live.count == 1 ? nil
                : stackHeights(total: rect.height, gap: p.gap, weights: live.map { c.weights[$0.offset] },
                               minimums: live.map { minHeights[$0.element] ?? 0 })
            guard let heights else {
                // One window, a tabbed column, or a stack too tall for the screen: full height each.
                for (_, w) in live { out[w] = rect }
                return
            }
            var y = rect.minY
            for (k, (_, w)) in live.enumerated() {
                let h = k == live.count - 1 ? rect.maxY - y : heights[k].rounded()
                out[w] = CGRect(x: rect.minX, y: y, width: rect.width, height: h)
                y += h + p.gap
            }
        }

        for (i, r) in g.pinned { place(strip.columns[i], in: r) }
        let inner = p.inner
        for s in g.spans {
            let r = CGRect(x: (g.scrollMinX + s.x - scroll).rounded(), y: inner.minY, width: s.width, height: inner.height)
            place(strip.columns[s.column], in: r)
        }
        return out
    }

    /// Moves a window that ends up outside the scrolling region to the screen edge, with a sliver visible.
    public static func park(_ r: CGRect, region: CGRect, screen: CGRect) -> CGRect {
        let visible = r.intersection(region)
        if !visible.isNull, visible.width >= 1 { return r }
        var out = r
        if r.midX < region.midX {
            out.origin.x = screen.minX - r.width + parkSliver
        } else {
            out.origin.x = screen.maxX - parkSliver
        }
        return out
    }
}
