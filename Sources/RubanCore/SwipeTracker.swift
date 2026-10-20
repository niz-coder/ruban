import Foundation

/// Recognises a sideways swipe with a set number of fingers from raw trackpad contacts.
///
/// Positions are normalised to the trackpad (0…1). The swipe only starts once the fingers have
/// clearly moved sideways, so a vertical swipe (Mission Control) or a pinch is left alone.
public struct SwipeTracker: Sendable {
    public enum Event: Equatable, Sendable {
        case began
        /// Horizontal travel since the last event, in trackpad widths (negative = fingers moved left).
        case moved(Double)
        /// Fingers lifted. Velocity in trackpad widths per second, for flicks.
        case ended(velocity: Double)
    }

    private enum State {
        case idle
        case pending(startX: Double, startY: Double)
        case active(lastX: Double)
        /// Some other gesture is under way: ignore everything until every finger has lifted.
        case blocked
    }

    public var fingers: Int
    /// How far the fingers must travel before the swipe counts, in trackpad widths.
    public var threshold = 0.02
    private var state = State.idle
    private var samples: [(time: Double, x: Double)] = []

    public init(fingers: Int) {
        self.fingers = fingers
    }

    public var isActive: Bool {
        if case .active = state { return true }
        return false
    }

    /// Feeds one frame: the positions of the fingers touching the trackpad right now.
    public mutating func update(_ points: [(x: Double, y: Double)], time: Double) -> [Event] {
        let n = points.count
        let x = n == 0 ? 0 : points.reduce(0) { $0 + $1.x } / Double(n)
        let y = n == 0 ? 0 : points.reduce(0) { $0 + $1.y } / Double(n)

        switch state {
        case .idle:
            if n == fingers { state = .pending(startX: x, startY: y) }
            return []

        case .blocked:
            if n == 0 { state = .idle }
            return []

        case let .pending(startX, startY):
            guard n == fingers else {
                state = n == 0 ? .idle : .blocked
                return []
            }
            let dx = x - startX, dy = y - startY
            if abs(dy) >= threshold, abs(dy) > abs(dx) {
                state = .blocked
                return []
            }
            guard abs(dx) >= threshold, abs(dx) > abs(dy) * 1.3 else { return [] }
            state = .active(lastX: x)
            samples = [(time, x)]
            // Catch up with the distance already travelled so the strip starts under the fingers.
            return [.began, .moved(dx)]

        case let .active(lastX):
            guard n == fingers else {
                state = n == 0 ? .idle : .blocked
                let v = velocity()
                samples.removeAll()
                return [.ended(velocity: v)]
            }
            state = .active(lastX: x)
            samples.append((time, x))
            samples.removeAll { time - $0.time > 0.1 }
            return x == lastX ? [] : [.moved(x - lastX)]
        }
    }

    /// Average speed over the last tenth of a second.
    private func velocity() -> Double {
        guard let first = samples.first, let last = samples.last, last.time - first.time > 0.008 else { return 0 }
        return (last.x - first.x) / (last.time - first.time)
    }
}
