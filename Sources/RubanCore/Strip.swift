import Foundation

public typealias WindowID = UInt32

public enum CentreMode: String, Codable, CaseIterable, Sendable {
    case never, onOverflow, always
}

public enum PinSide: String, Codable, Sendable {
    case left, right
}

/// One column of the strip. Usually a single window; several windows make a stack.
public struct Column: Equatable, Codable, Sendable {
    public var id = UUID()
    public var windows: [WindowID]
    /// Relative heights of the windows in a stack, same order as `windows`.
    public var weights: [Double]
    public var active = 0
    /// Width as a fraction of the usable screen width.
    public var width: Double
    public var tabbed = false
    public var widthBeforeFull: Double?
    public var pinned: PinSide?

    public init(window: WindowID, width: Double) {
        windows = [window]
        weights = [1]
        self.width = width
    }

    public var activeWindow: WindowID? {
        windows.indices.contains(active) ? windows[active] : windows.first
    }

    mutating func clampActive() {
        active = windows.isEmpty ? 0 : min(max(active, 0), windows.count - 1)
    }

    func isLive(_ present: Set<WindowID>) -> Bool {
        windows.contains(where: present.contains)
    }
}

/// The endless horizontal strip of one display (and one Space).
public struct Strip: Equatable, Sendable {
    public var columns: [Column] = []
    public var focused = 0
    /// Horizontal offset of the viewport inside the strip, in points.
    public var scroll: Double = 0

    public init() {}

    public func columnIndex(of window: WindowID) -> Int? {
        columns.firstIndex { $0.windows.contains(window) }
    }

    public var focusedWindow: WindowID? {
        columns.indices.contains(focused) ? columns[focused].activeWindow : nil
    }

    public func liveColumns(_ present: Set<WindowID>) -> [Int] {
        columns.indices.filter { columns[$0].isLive(present) }
    }

    // MARK: Insertion and removal

    /// Inserts a window as a new column right after `index` (or at the end) and returns its column index.
    @discardableResult
    public mutating func insert(_ window: WindowID, width: Double, after index: Int?) -> Int {
        let at = insertionIndex(index.map { $0 + 1 } ?? columns.count)
        let wasEmpty = columns.isEmpty
        columns.insert(Column(window: window, width: width), at: at)
        if wasEmpty { focused = 0 } else if focused >= at { focused += 1 }
        return at
    }

    public mutating func remove(_ window: WindowID) {
        guard let ci = columnIndex(of: window), let wi = columns[ci].windows.firstIndex(of: window) else { return }
        columns[ci].windows.remove(at: wi)
        columns[ci].weights.remove(at: wi)
        if wi < columns[ci].active { columns[ci].active -= 1 }
        columns[ci].clampActive()
        if columns[ci].windows.isEmpty {
            columns.remove(at: ci)
            if ci < focused || (ci == focused && focused > 0) { focused -= 1 }
        }
        focused = columns.isEmpty ? 0 : min(max(focused, 0), columns.count - 1)
    }

    /// Swaps one window for another in place (native tabs, re-created windows).
    public mutating func replace(_ old: WindowID, with new: WindowID) {
        guard let ci = columnIndex(of: old), let wi = columns[ci].windows.firstIndex(of: old) else { return }
        columns[ci].windows[wi] = new
    }

    // MARK: Navigation

    public func neighbor(of index: Int, direction: Int, present: Set<WindowID>) -> Int? {
        var i = index + direction
        while columns.indices.contains(i) {
            if columns[i].isLive(present) { return i }
            i += direction
        }
        return nil
    }

    public mutating func focusNeighbor(_ direction: Int, present: Set<WindowID>) -> Bool {
        guard let n = neighbor(of: focused, direction: direction, present: present) else { return false }
        focused = n
        return true
    }

    public mutating func focusEdge(last: Bool, present: Set<WindowID>) -> Bool {
        let live = liveColumns(present)
        guard let target = last ? live.last : live.first, target != focused else { return false }
        focused = target
        return true
    }

    /// Jumps to the n-th visible column, counting from 1.
    public mutating func focusNumber(_ n: Int, present: Set<WindowID>) -> Bool {
        let live = liveColumns(present)
        guard live.indices.contains(n - 1) else { return false }
        focused = live[n - 1]
        return true
    }

    public mutating func focusInStack(_ direction: Int, present: Set<WindowID>) -> Bool {
        guard columns.indices.contains(focused) else { return false }
        let c = columns[focused]
        var i = c.active + direction
        while c.windows.indices.contains(i) {
            if present.contains(c.windows[i]) {
                columns[focused].active = i
                return true
            }
            i += direction
        }
        return false
    }

    // MARK: Moving

    public mutating func moveColumn(_ direction: Int, present: Set<WindowID>) -> Bool {
        guard columns.indices.contains(focused),
              let n = neighbor(of: focused, direction: direction, present: present),
              columns[n].pinned == nil, columns[focused].pinned == nil else { return false }
        columns.swapAt(focused, n)
        focused = n
        return true
    }

    public mutating func moveColumn(from: Int, to: Int) {
        guard columns.indices.contains(from), columns.indices.contains(to), from != to else { return }
        let focusedID = columns.indices.contains(focused) ? columns[focused].id : nil
        let c = columns.remove(at: from)
        columns.insert(c, at: to)
        if let focusedID, let f = columns.firstIndex(where: { $0.id == focusedID }) { focused = f }
    }

    public mutating func moveInStack(_ direction: Int) -> Bool {
        guard columns.indices.contains(focused) else { return false }
        let a = columns[focused].active, b = a + direction
        guard columns[focused].windows.indices.contains(b) else { return false }
        columns[focused].windows.swapAt(a, b)
        columns[focused].weights.swapAt(a, b)
        columns[focused].active = b
        return true
    }

    // MARK: Stacks

    /// Moves the focused window into the neighbouring column, at the bottom of its stack.
    public mutating func stackIntoNeighbor(_ direction: Int, present: Set<WindowID>) -> Bool {
        guard columns.indices.contains(focused), let w = focusedWindow,
              let n = neighbor(of: focused, direction: direction, present: present) else { return false }
        let targetID = columns[n].id
        remove(w)
        guard let t = columns.firstIndex(where: { $0.id == targetID }) else { return false }
        columns[t].windows.append(w)
        columns[t].weights.append(1)
        columns[t].active = columns[t].windows.count - 1
        focused = t
        return true
    }

    /// Takes the focused window out of its stack and gives it a column of its own.
    public mutating func popOut(_ direction: Int) -> Bool {
        guard columns.indices.contains(focused), columns[focused].windows.count > 1, let w = focusedWindow else { return false }
        let width = columns[focused].width
        let sourceID = columns[focused].id
        remove(w)
        guard let s = columns.firstIndex(where: { $0.id == sourceID }) else { return false }
        let at = direction > 0 ? s + 1 : s
        var c = Column(window: w, width: width)
        c.pinned = nil
        columns.insert(c, at: at)
        focused = at
        return true
    }

    public mutating func toggleTabbed() -> Bool {
        guard columns.indices.contains(focused) else { return false }
        columns[focused].tabbed.toggle()
        return true
    }

    // MARK: Sizes

    public mutating func cycleWidth(presets: [Double]) -> Bool {
        guard columns.indices.contains(focused), !presets.isEmpty else { return false }
        let sorted = presets.sorted()
        let current = columns[focused].width
        let next = sorted.first { $0 > current + 0.01 } ?? sorted[0]
        columns[focused].width = next
        columns[focused].widthBeforeFull = nil
        return true
    }

    public mutating func toggleFullWidth() -> Bool {
        guard columns.indices.contains(focused) else { return false }
        if let before = columns[focused].widthBeforeFull, columns[focused].width >= 0.999 {
            columns[focused].width = before
            columns[focused].widthBeforeFull = nil
        } else {
            columns[focused].widthBeforeFull = columns[focused].width
            columns[focused].width = 1
        }
        return true
    }

    public mutating func adjustWidth(by delta: Double) -> Bool {
        guard columns.indices.contains(focused) else { return false }
        columns[focused].width = min(max(columns[focused].width + delta, 0.1), 1)
        columns[focused].widthBeforeFull = nil
        return true
    }

    public mutating func adjustHeight(factor: Double) -> Bool {
        guard columns.indices.contains(focused), columns[focused].windows.count > 1, !columns[focused].tabbed else { return false }
        let a = columns[focused].active
        columns[focused].weights[a] = min(max(columns[focused].weights[a] * factor, 0.2), 5)
        return true
    }

    public mutating func equalizeHeights() -> Bool {
        guard columns.indices.contains(focused) else { return false }
        columns[focused].weights = columns[focused].weights.map { _ in 1 }
        return true
    }

    // MARK: Pinning

    /// Pins the focused column to one edge, or unpins it if it already sits there.
    public mutating func togglePin(_ side: PinSide) -> Bool {
        guard columns.indices.contains(focused) else { return false }
        if columns[focused].pinned == side {
            columns[focused].pinned = nil
            return true
        }
        for i in columns.indices where columns[i].pinned == side { columns[i].pinned = nil }
        var c = columns.remove(at: focused)
        c.pinned = side
        let at = side == .left ? 0 : columns.count
        columns.insert(c, at: at)
        focused = at
        return true
    }
}
