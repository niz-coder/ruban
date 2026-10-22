import AppKit
import ApplicationServices
import RubanCore

/// A second, tiny Ruban process that brings the windows back if the first one dies.
///
/// Ruban parks the windows it scrolls off screen at the display edge, one point showing. Quitting
/// brings them back, but a crash or a force quit runs no code at all, and they would stay there
/// with no way to reach them. So at launch Ruban starts a copy of itself with `--guard <pid>`, which
/// only waits. When the first process ends without saying it ended cleanly, the copy brings back
/// every window that shows no more than a sliver on any display, then exits too.
enum Guardian {
    private static let marker: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ruban", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clean-exit")
    }()

    /// Starts the guardian for this process.
    static func spawn() {
        guard let exe = Bundle.main.executablePath else { return }
        try? FileManager.default.removeItem(at: marker)
        // It answers for itself, so macOS checks Ruban's Accessibility permission against it even
        // once Ruban, which started it, is gone.
        if let pid = Spawn.detached([exe, "--guard", String(getpid())], disclaim: true) {
            Log.write("guardian \(pid) is watching")
        }
    }

    /// Says the windows are back on screen. Called right before a normal exit.
    static func markCleanExit() {
        try? String(getpid()).write(to: marker, atomically: true, encoding: .utf8)
    }

    /// The guardian itself. Never returns.
    static func run(watching pid: pid_t) -> Never {
        // Killed together with Ruban (pkill, logging out): outlive it long enough to check on it.
        for sig in [SIGTERM, SIGINT, SIGHUP] { signal(sig, SIG_IGN) }
        let ended = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { ended.signal() }
        source.resume()
        // Gone before the watch began: the source would never fire.
        if kill(pid, 0) != 0, errno == ESRCH { ended.signal() }
        ended.wait()
        source.cancel()

        if (try? String(contentsOf: marker, encoding: .utf8)) == String(pid) {
            try? FileManager.default.removeItem(at: marker)
        } else if anotherRuban(besides: pid) {
            Log.write("guardian: Ruban \(pid) ended, a new one is already running")
        } else if !AX.isTrusted() {
            Log.write("guardian: Ruban \(pid) ended without bringing the windows back, and the Accessibility permission is off")
        } else {
            let n = rescue()
            Log.write("guardian: Ruban \(pid) ended without bringing the windows back; brought back \(n)")
        }
        Log.flush()
        exit(0)
    }

    private static func anotherRuban(besides pid: pid_t) -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let me = getpid()
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .contains { $0.processIdentifier != pid && $0.processIdentifier != me }
    }

    /// Brings back every standard window that shows no more than a sliver on any display, in a
    /// cascade on the display it is closest to. Returns how many it moved.
    @discardableResult
    static func rescue() -> Int {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let screens = NSScreen.screens.map { (frame: NSScreen.toAX($0.frame), area: NSScreen.toAX($0.visibleFrame)) }
        guard !screens.isEmpty else { return 0 }
        var lost: [Int: [(AXUIElement, CGRect)]] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            for w in AXUIElementCreateApplication(app.processIdentifier).windows {
                guard w.subrole == kAXStandardWindowSubrole as String, !w.isMinimized, let f = w.frame else { continue }
                let shown = screens.contains { s in
                    let i = f.intersection(s.frame)
                    return !i.isNull && i.width >= 40 && i.height >= 40
                }
                guard !shown else { continue }
                let centre = CGPoint(x: f.midX, y: f.midY)
                let nearest = screens.indices.min { distance(screens[$0].frame, centre) < distance(screens[$1].frame, centre) }!
                lost[nearest, default: []].append((w, f))
            }
        }
        var moved = 0
        for (i, list) in lost {
            for ((w, _), f) in zip(list, Layout.bringBack(list.map(\.1), area: screens[i].area)) {
                w.setFrame(f, resize: true)
                moved += 1
            }
        }
        return moved
    }

    private static func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }
}
