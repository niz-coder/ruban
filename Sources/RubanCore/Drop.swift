import CoreGraphics
import Foundation

/// Where a dragged window (or a dragged column of the strip indicator) lands.
/// Columns are named by id, so the target survives the source column disappearing.
public enum Drop: Equatable, Sendable {
    /// Into an existing column's stack, above `before` (nil = at the bottom).
    case stack(column: UUID, before: WindowID?)
    /// As a column of its own, left of the column `before` (nil = at the end of the strip).
    case column(before: UUID?)
}

extension Strip {
    /// Moves a window already on the strip to a drop position. Returns false, leaving the strip
    /// unchanged, when the drop would put it back where it is.
    @discardableResult
    public mutating func move(_ window: WindowID, to drop: Drop) -> Bool {
        guard let src = columnIndex(of: window) else { return false }
        let source = columns[src]
        let alone = source.windows.count == 1
        switch drop {
        case let .stack(target, _) where target == source.id && alone:
            return false
        case let .column(before) where alone && (before == source.id || before == columnID(after: src)):
            return false
        default:
            break
        }
        let snapshot = self
        remove(window)
        place(window, at: drop, width: source.width)
        if columns.map(\.windows) == snapshot.columns.map(\.windows) {
            self = snapshot
            return false
        }
        return true
    }

    /// Puts a window that is not on this strip at a drop position, and focuses it.
    public mutating func place(_ window: WindowID, at drop: Drop, width: Double) {
        switch drop {
        case let .stack(id, before):
            guard let t = columns.firstIndex(where: { $0.id == id }) else {
                return place(window, at: .column(before: nil), width: width)
            }
            let at = before.flatMap { columns[t].windows.firstIndex(of: $0) } ?? columns[t].windows.count
            columns[t].windows.insert(window, at: at)
            columns[t].weights.insert(1, at: at)
            columns[t].active = at
            focused = t
        case let .column(before):
            let wanted = before.flatMap { id in columns.firstIndex { $0.id == id } } ?? columns.count
            let at = insertionIndex(wanted)
            columns.insert(Column(window: window, width: width), at: at)
            focused = at
        }
    }

    /// Moves a whole column (from the strip indicator): onto another column it merges into that
    /// stack, between columns it is reordered. Returns false when nothing changes.
    @discardableResult
    public mutating func move(column id: UUID, to drop: Drop) -> Bool {
        guard let src = columns.firstIndex(where: { $0.id == id }) else { return false }
        let snapshot = self
        switch drop {
        case let .stack(target, before):
            guard target != id else { return false }
            let moving = columns.remove(at: src)
            guard let t = columns.firstIndex(where: { $0.id == target }) else {
                self = snapshot
                return false
            }
            let at = before.flatMap { columns[t].windows.firstIndex(of: $0) } ?? columns[t].windows.count
            columns[t].windows.insert(contentsOf: moving.windows, at: at)
            columns[t].weights.insert(contentsOf: moving.weights, at: at)
            columns[t].active = at + min(moving.active, moving.windows.count - 1)
            focused = t
        case let .column(before):
            guard before != id, before != columnID(after: src) else { return false }
            var moving = columns.remove(at: src)
            moving.pinned = nil
            let wanted = before.flatMap { b in columns.firstIndex { $0.id == b } } ?? columns.count
            let at = insertionIndex(wanted)
            columns.insert(moving, at: at)
            focused = at
        }
        if columns.map(\.windows) == snapshot.columns.map(\.windows) {
            self = snapshot
            return false
        }
        return true
    }

    func columnID(after index: Int) -> UUID? {
        columns.indices.contains(index + 1) ? columns[index + 1].id : nil
    }

    /// Nothing goes between a left-pinned column and the left edge, or past a right-pinned one.
    func insertionIndex(_ wanted: Int) -> Int {
        var at = min(max(wanted, 0), columns.count)
        if at < columns.count, columns[at].pinned == .left { at += 1 }
        while at > 0, columns[at - 1].pinned == .right { at -= 1 }
        return at
    }
}

extension Layout {
    /// What dropping a dragged window at point `p` would do, given where every other window sits.
    ///
    /// Over the middle of a column the window joins its stack, above whichever window's centre the
    /// point is above; near a column's left or right edge, or in the gap between two columns, it
    /// becomes a column of its own there.
    public static func dropTarget(at p: CGPoint, moving window: WindowID, in strip: Strip, frames: [WindowID: CGRect]) -> Drop {
        for (i, c) in strip.columns.enumerated() {
            let others = c.windows.filter { $0 != window && frames[$0] != nil }
            guard let first = others.first else { continue }
            let rect = others.dropFirst().reduce(frames[first]!) { $0.union(frames[$1]!) }
            if p.x < rect.minX { return .column(before: c.id) }
            guard p.x <= rect.maxX else { continue }
            let edge = min(max(rect.width * 0.22, 36), 120)
            if p.x < rect.minX + edge { return .column(before: c.id) }
            if p.x > rect.maxX - edge { return .column(before: strip.columnID(after: i)) }
            if c.tabbed { return .stack(column: c.id, before: nil) }
            let below = others.first { frames[$0]!.midY > p.y }
            return .stack(column: c.id, before: below)
        }
        return .column(before: nil)
    }
}
