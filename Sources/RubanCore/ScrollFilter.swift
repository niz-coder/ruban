import Foundation

/// Decides which scroll events move the strip: those made with the modifiers held, and the momentum
/// that carries on once the fingers lift. Everything else belongs to the app under the pointer.
///
/// It runs inside an event tap, where every scroll on the Mac waits for its answer, so it only looks
/// at the event and the clock: never at anything another thread could be holding.
public struct ScrollFilter: Sendable {
    public struct Event: Sendable {
        /// The modifiers are down, and shift is not.
        public var held: Bool
        /// Trackpad gesture phase; 0 outside a gesture, and always 0 for a mouse wheel.
        public var phase: Int
        /// Momentum phase; 3 when the glide after the fingers lift is over.
        public var momentum: Int
        /// A trackpad or Magic Mouse, as opposed to a wheel that turns in notches.
        public var continuous: Bool
        public var dx: Double
        public var dy: Double
        /// When it arrived, in seconds.
        public var time: Double

        public init(held: Bool, phase: Int, momentum: Int, continuous: Bool, dx: Double, dy: Double, time: Double) {
            self.held = held
            self.phase = phase
            self.momentum = momentum
            self.continuous = continuous
            self.dx = dx
            self.dy = dy
            self.time = time
        }
    }

    public var invert = false
    /// Until then, events still belong to a gesture begun with the modifiers held.
    private var gestureUntil = -Double.infinity

    public init() {}

    /// How far the strip moves for this event, in points, and how long after it the strip should
    /// settle if nothing else comes; nil to let the event through to the app.
    public mutating func filter(_ e: Event) -> (delta: Double, settleAfter: Double)? {
        guard e.held || e.time < gestureUntil else { return nil }
        // Momentum after the fingers lift belongs to the gesture that started with the keys held;
        // a new gesture without them belongs to the app.
        if !e.held && e.phase != 0 { return nil }
        var delta = abs(e.dx) > abs(e.dy) ? e.dx : e.dy
        if !e.continuous { delta *= 12 } // a mouse wheel notch
        if invert { delta = -delta }
        // Momentum phase 3 = the glide is over. Otherwise settle once events stop coming
        // (fingers lifted with no momentum, or a mouse wheel that has no phases at all).
        let settle = e.momentum == 3 ? 0.05 : e.continuous ? 0.15 : 0.25
        gestureUntil = e.time + settle
        return (-delta, settle)
    }
}
