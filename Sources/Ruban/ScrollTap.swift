import AppKit

/// Hold the modifiers (⌃⌥ by default) and scroll sideways on the trackpad, or turn the mouse wheel:
/// the strip follows your fingers one to one, then settles on the nearest column.
/// The scroll is swallowed so the app under the pointer does not scroll at the same time.
final class ScrollTap {
    static let shared = ScrollTap()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var settleTimer: Timer?
    private var scrolling = false

    func start() {
        guard tap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            ScrollTap.shared.handle(type, event)
        }, userInfo: nil) else { return }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let settings = Settings.shared
        let wm = WindowManager.shared
        let wanted = settings.modifiers.flags
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection([.control, .option, .command, .shift])
        let held = flags.isSuperset(of: wanted) && !flags.contains(.shift)
        guard type == .scrollWheel, settings.scrollWithModifiers, wm.running, held || scrolling else {
            return Unmanaged.passUnretained(event)
        }
        // Momentum after the fingers lift belongs to the gesture that started with the keys held.
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if !held && phase != 0 { return Unmanaged.passUnretained(event) }

        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        var delta = abs(dx) > abs(dy) ? dx : dy
        if !continuous { delta *= 12 } // a mouse wheel notch
        if settings.invertScroll { delta = -delta }

        scrolling = true
        if delta != 0 { wm.scroll(by: -delta) }

        // Momentum phase 3 = the glide is over. Otherwise settle once events stop coming
        // (fingers lifted with no momentum, or a mouse wheel that has no phases at all).
        settle(after: momentum == 3 ? 0.05 : continuous ? 0.15 : 0.25)
        return nil
    }

    private func settle(after delay: Double) {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.scrolling = false
            WindowManager.shared.endScroll()
        }
    }
}
