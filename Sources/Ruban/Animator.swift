import AppKit
import QuartzCore
import RubanCore

/// Slides windows from where they are to where the layout wants them.
/// It animates "virtual" frames (where the window would be on the endless strip);
/// the window manager decides on every frame whether that spot is on screen or parked.
final class Animator {
    struct Job {
        let window: WindowID
        let from: CGRect
        let to: CGRect
        let start: CFTimeInterval
        let duration: Double
    }

    private var jobs: [WindowID: Job] = [:]
    private lazy var clock = FrameClock { [weak self] in self?.tick() }

    /// Moves one window to a virtual frame. Set by the window manager.
    var apply: ((WindowID, CGRect) -> Void)?
    /// Called once every window has arrived, with the windows that moved.
    var didFinish: (([WindowID]) -> Void)?
    private var moved = Set<WindowID>()

    var isRunning: Bool { clock.isRunning }

    func run(_ targets: [(WindowID, from: CGRect, to: CGRect)], animated: Bool, duration: Double) {
        let now = CACurrentMediaTime()
        for t in targets {
            moved.insert(t.0)
            if !animated || duration <= 0 || t.from.isClose(to: t.to, tolerance: 0.5) {
                jobs[t.0] = nil
                apply?(t.0, t.to)
            } else {
                jobs[t.0] = Job(window: t.0, from: t.from, to: t.to, start: now, duration: duration)
            }
        }
        if jobs.isEmpty {
            finish()
        } else if !clock.isRunning {
            clock.start()
            tick()
        }
    }

    func cancel(_ window: WindowID) { jobs[window] = nil }

    func cancelAll() {
        jobs.removeAll()
        clock.stop()
        moved.removeAll()
    }

    private func tick() {
        let now = CACurrentMediaTime()
        for (id, job) in jobs {
            let t = min(1, (now - job.start) / job.duration)
            // Ease-out cubic: starts fast the instant the key goes down, settles softly.
            let e = 1 - pow(1 - t, 3)
            let x = job.from.minX + (job.to.minX - job.from.minX) * e
            let y = job.from.minY + (job.to.minY - job.from.minY) * e
            let frame = t >= 1 ? job.to : CGRect(x: x.rounded(), y: y.rounded(), width: job.to.width, height: job.to.height)
            apply?(id, frame)
            if t >= 1 { jobs[id] = nil }
        }
        if jobs.isEmpty { finish() }
    }

    private func finish() {
        clock.stop()
        let done = Array(moved)
        moved.removeAll()
        didFinish?(done)
    }
}

/// Calls back once per screen refresh (vsync), so windows move in step with what the display shows.
/// Falls back to a 120 Hz timer when no screen is available (lid closed, display asleep).
final class FrameClock: NSObject {
    private var link: CADisplayLink?
    private var timer: Timer?
    private let onFrame: () -> Void

    init(_ onFrame: @escaping () -> Void) {
        self.onFrame = onFrame
    }

    var isRunning: Bool { link != nil || timer != nil }

    func start() {
        guard !isRunning else { return }
        if let screen = NSScreen.main {
            let link = screen.displayLink(target: self, selector: #selector(frame))
            link.add(to: .main, forMode: .common)
            self.link = link
        } else {
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.onFrame() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
    }

    @objc private func frame() { onFrame() }
}
