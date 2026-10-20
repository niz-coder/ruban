import ApplicationServices
import QuartzCore
import RubanCore

/// Moves windows off the main thread, one serial queue per app.
///
/// Setting a frame through Accessibility waits for the target app to answer. A busy app (Electron,
/// a page loading) can take hundreds of milliseconds, which would freeze shortcuts and animations
/// if done on the main thread. Here each app gets its own queue, and if frames pile up for a window
/// faster than its app can take them, only the latest one is applied.
final class AXWorker {
    static let shared = AXWorker()

    private struct Job {
        let element: AXUIElement
        let frame: CGRect
        let resize: Bool
    }

    private let lock = NSLock()
    private var queues: [pid_t: DispatchQueue] = [:]
    private var pending: [WindowID: Job] = [:]
    /// Apps whose AXEnhancedUserInterface (set by screen readers and some utilities) we switched off:
    /// while it is on, Chrome and Electron animate every frame change and moves crawl.
    private var enhancedOff: Set<pid_t> = []
    private var enhancedChecked: [pid_t: CFTimeInterval] = [:]
    private var generation: [pid_t: Int] = [:]

    func setFrame(_ element: AXUIElement, window: WindowID, pid: pid_t, frame: CGRect, resize: Bool) {
        lock.lock()
        let alreadyQueued = pending[window] != nil
        pending[window] = Job(element: element, frame: frame, resize: resize || (pending[window]?.resize ?? false))
        generation[pid, default: 0] += 1
        let q = queue(for: pid)
        lock.unlock()
        guard !alreadyQueued else { return }

        q.async { [self] in
            lock.lock()
            let job = pending.removeValue(forKey: window)
            lock.unlock()
            guard let job else { return }
            switchOffEnhancedUI(pid)
            job.element.setFrame(job.frame, resize: job.resize)
            restoreEnhancedUILater(pid, on: q)
        }
    }

    /// Runs `work` after every frame already queued for this app has been applied.
    func afterPending(_ pid: pid_t, _ work: @escaping () -> Void) {
        lock.lock()
        let q = queue(for: pid)
        lock.unlock()
        q.async(execute: work)
    }

    private func queue(for pid: pid_t) -> DispatchQueue {
        if let q = queues[pid] { return q }
        let q = DispatchQueue(label: "ruban.ax.\(pid)", qos: .userInteractive)
        queues[pid] = q
        return q
    }

    private func switchOffEnhancedUI(_ pid: pid_t) {
        let now = CACurrentMediaTime()
        lock.lock()
        let skip = enhancedOff.contains(pid) || now - (enhancedChecked[pid] ?? 0) < 5
        if !skip { enhancedChecked[pid] = now }
        lock.unlock()
        guard !skip else { return }
        let app = AXUIElementCreateApplication(pid)
        guard app.bool("AXEnhancedUserInterface") == true else { return }
        app.set("AXEnhancedUserInterface", kCFBooleanFalse)
        lock.lock()
        enhancedOff.insert(pid)
        lock.unlock()
    }

    private func restoreEnhancedUILater(_ pid: pid_t, on q: DispatchQueue) {
        lock.lock()
        let gen = generation[pid] ?? 0
        let off = enhancedOff.contains(pid)
        lock.unlock()
        guard off else { return }
        q.asyncAfter(deadline: .now() + 0.6) { [self] in
            lock.lock()
            let idle = generation[pid] == gen
            if idle { enhancedOff.remove(pid) }
            lock.unlock()
            if idle { AXUIElementCreateApplication(pid).set("AXEnhancedUserInterface", kCFBooleanTrue) }
        }
    }
}
