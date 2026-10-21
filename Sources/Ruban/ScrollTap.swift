import AppKit
import RubanCore

/// Hold the modifiers (⌃⌥ by default) and scroll sideways on the trackpad, or turn the mouse wheel:
/// the strip follows your fingers one to one, then settles on the nearest column.
/// The scroll is swallowed so the app under the pointer does not scroll at the same time.
///
/// Every scroll on the Mac waits in this tap until it answers. So the tap is only installed while
/// it has something to do, and it lives on a thread of its own that does nothing else: it decides
/// from a copy of the settings and hands the strip's moves to the main thread without waiting.
/// A busy main thread can delay the strip, never the scrolling in other apps.
final class ScrollTap {
    static let shared = ScrollTap()

    private struct Config {
        var enabled = false
        var wanted: NSEvent.ModifierFlags = []
    }

    /// Guards everything the tap's thread touches.
    private let lock = NSLock()
    private var config = Config()
    private var filter = ScrollFilter()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// Strip moves the main thread has not taken yet.
    private var pending = 0.0
    private var settleAfter = 0.0
    private var drainScheduled = false

    private var settleTimer: Timer?

    /// Installs or removes the tap to match the settings and the state of tiling. Main thread.
    func refresh() {
        let settings = Settings.shared, wm = WindowManager.shared
        let enabled = settings.scrollWithModifiers && wm.running && !wm.paused
        lock.lock()
        config = Config(enabled: enabled, wanted: settings.modifiers.flags)
        filter.invert = settings.invertScroll
        let installed = tap != nil
        lock.unlock()
        if enabled && !installed { start() }
        if !enabled && installed { stop() }
    }

    private func start() {
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, _ in
            ScrollTap.shared.handle(type, event)
        }, userInfo: nil) else { return }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            lock.lock()
            runLoop = loop
            lock.unlock()
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Ruban scroll tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        lock.lock()
        self.tap = tap
        lock.unlock()
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func stop() {
        lock.lock()
        let tap = self.tap, loop = runLoop
        self.tap = nil
        runLoop = nil
        pending = 0
        lock.unlock()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let loop { CFRunLoopStop(loop) }
        settleTimer?.invalidate()
        settleTimer = nil
    }

    /// On the tap's thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let tap = self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        let flags = NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)).intersection([.control, .option, .command, .shift])
        let phase = Int(event.getIntegerValueField(.scrollWheelEventScrollPhase))
        let momentum = Int(event.getIntegerValueField(.scrollWheelEventMomentumPhase))
        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        let now = CACurrentMediaTime()

        lock.lock()
        let held = flags.isSuperset(of: config.wanted) && !flags.contains(.shift)
        let move = config.enabled
            ? filter.filter(.init(held: held, phase: phase, momentum: momentum, continuous: continuous, dx: dx, dy: dy, time: now))
            : nil
        guard let move else {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        pending += move.delta
        settleAfter = move.settleAfter
        let schedule = !drainScheduled
        drainScheduled = true
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.drain() } }
        return nil
    }

    /// On the main thread: moves the strip by everything scrolled since the last time.
    private func drain() {
        lock.lock()
        let delta = pending, settle = settleAfter
        pending = 0
        drainScheduled = false
        lock.unlock()
        let wm = WindowManager.shared
        if delta != 0 { wm.scroll(by: delta) }
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: settle, repeats: false) { _ in wm.endScroll() }
    }
}
