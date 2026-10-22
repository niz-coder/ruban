import Foundation
import RubanCore

/// Swipe with three (or four) fingers and the strip moves with them, then settles on a column.
///
/// macOS turns multi-finger swipes into system gestures before any app sees them, so this reads the
/// trackpad's raw contacts through the private MultitouchSupport framework (the one MiddleClick and
/// similar utilities use). It needs no permission. Contacts arrive on the framework's own thread;
/// recognised moves are batched and handed to the main thread.
final class TrackpadSwipe {
    static let shared = TrackpadSwipe()

    private typealias Device = UnsafeMutableRawPointer
    private typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

    private struct API {
        let createList: @convention(c) () -> Unmanaged<CFMutableArray>?
        let register: @convention(c) (Device, Callback) -> Void
        let unregister: @convention(c) (Device, Callback) -> Void
        let start: @convention(c) (Device, Int32) -> Void
        let stop: @convention(c) (Device) -> Void

        static let shared: API? = {
            guard let h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY),
                  let a = dlsym(h, "MTDeviceCreateList"), let b = dlsym(h, "MTRegisterContactFrameCallback"),
                  let c = dlsym(h, "MTUnregisterContactFrameCallback"), let d = dlsym(h, "MTDeviceStart"),
                  let e = dlsym(h, "MTDeviceStop") else { return nil }
            return API(createList: unsafeBitCast(a, to: (@convention(c) () -> Unmanaged<CFMutableArray>?).self),
                       register: unsafeBitCast(b, to: (@convention(c) (Device, Callback) -> Void).self),
                       unregister: unsafeBitCast(c, to: (@convention(c) (Device, Callback) -> Void).self),
                       start: unsafeBitCast(d, to: (@convention(c) (Device, Int32) -> Void).self),
                       stop: unsafeBitCast(e, to: (@convention(c) (Device) -> Void).self))
        }()
    }

    // Layout of one contact in a frame: 96 bytes, state at 20, normalised x/y at 32/36.
    private static let contactSize = 96
    private static let callback: Callback = { device, data, count, time, _ in
        TrackpadSwipe.shared.frame(device, data, Int(count), time)
        return 0
    }

    private let lock = NSLock()
    private var fingers = 3
    private var trackers: [Int: SwipeTracker] = [:]
    private var queued: [SwipeTracker.Event] = []
    private var drainScheduled = false
    private var devices: CFMutableArray?

    /// Starts listening with the given finger count; 0 turns swipes off.
    func start(fingers: Int) {
        stop()
        lock.lock()
        self.fingers = fingers
        trackers.removeAll()
        lock.unlock()
        guard fingers > 0 else { return }
        guard let api = API.shared, let list = api.createList()?.takeRetainedValue() else {
            Log.write("trackpad: MultitouchSupport is missing, swiping is off")
            return
        }
        devices = list
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = Device(mutating: raw)
            api.register(device, Self.callback)
            api.start(device, 0)
        }
        Log.write("trackpad: \(CFArrayGetCount(list)) device(s), swipe with \(fingers) fingers")
    }

    func stop() {
        guard let list = devices, let api = API.shared else { return }
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = Device(mutating: raw)
            api.unregister(device, Self.callback)
            api.stop(device)
        }
        devices = nil
    }

    /// After sleep, or when a Magic Trackpad comes and goes, the device list has to be rebuilt.
    func restart() {
        lock.lock()
        let f = fingers
        lock.unlock()
        start(fingers: f)
    }

    private func frame(_ device: UnsafeMutableRawPointer?, _ data: UnsafeMutableRawPointer?, _ count: Int, _ time: Double) {
        var points: [(x: Double, y: Double)] = []
        if let data {
            for i in 0..<count {
                let c = data + i * Self.contactSize
                // States 3–5: touching, about to touch, lifting. Hovering or out of range don't count.
                guard (3...5).contains(c.load(fromByteOffset: 20, as: Int32.self)) else { continue }
                points.append((Double(c.load(fromByteOffset: 32, as: Float.self)), Double(c.load(fromByteOffset: 36, as: Float.self))))
            }
        }
        let key = device.map { Int(bitPattern: $0) } ?? 0
        lock.lock()
        var tracker = trackers[key] ?? SwipeTracker(fingers: fingers)
        let events = tracker.update(points, time: time)
        trackers[key] = tracker
        queued += events
        let schedule = !events.isEmpty && !drainScheduled
        if schedule { drainScheduled = true }
        lock.unlock()
        if schedule { DispatchQueue.main.async { self.drain() } }
    }

    /// Hands the recognised events to the window manager, merging consecutive moves.
    private func drain() {
        lock.lock()
        let events = queued
        queued.removeAll()
        drainScheduled = false
        lock.unlock()
        let wm = WindowManager.shared
        var travel = 0.0
        for e in events {
            switch e {
            case .began:
                break
            case .moved(let dx):
                travel += dx
            case .ended(let velocity):
                if travel != 0 { wm.swipe(by: travel) }
                travel = 0
                wm.endSwipe(velocity: velocity)
            }
        }
        if travel != 0 { wm.swipe(by: travel) }
    }
}
