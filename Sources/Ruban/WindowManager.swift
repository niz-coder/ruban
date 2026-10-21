import AppKit
import ApplicationServices
import RubanCore

final class TrackedWindow {
    let id: WindowID
    let pid: pid_t
    let element: AXUIElement
    let bundleID: String
    var title: String

    init(id: WindowID, pid: pid_t, element: AXUIElement, bundleID: String, title: String) {
        self.id = id
        self.pid = pid
        self.element = element
        self.bundleID = bundleID
        self.title = title
    }
}

struct Display {
    let screen: NSScreen
    /// Strip key: one strip per display and per Space.
    let key: String
    let params: LayoutParams
}

/// Watches every app's windows through the Accessibility API and keeps them on the strips.
final class WindowManager {
    static let shared = WindowManager()

    let settings = Settings.shared
    private(set) var running = false

    private(set) var windows: [WindowID: TrackedWindow] = [:]
    private(set) var strips: [String: Strip] = [:]
    private var stripKeyOf: [WindowID: String] = [:]
    /// Tracked windows that are visible right now (not minimised, not hidden, on this Space).
    private(set) var present: Set<WindowID> = []
    private var userFloating: Set<WindowID> = []
    /// Last frame we gave each window, after parking.
    private var applied: [WindowID: CGRect] = [:]
    /// Where each window sits on its endless strip, before parking.
    private var virtual: [WindowID: CGRect] = [:]
    private(set) var displays: [Display] = []
    private var observers: [pid_t: AppObserver] = [:]

    let animator = Animator()
    let indicator = StripIndicator()
    let border = FocusBorder()
    let dropPreview = DropPreview()
    let session = SessionStore()

    private var reconcileWork: DispatchWorkItem?
    private var heartbeat: Timer?
    private var workspaceTokens: [NSObjectProtocol] = []
    private var ignoreMovesUntil: CFTimeInterval = 0
    private var dragTimer: Timer?
    private var bootstrapped = false
    private var pendingFocus: (id: WindowID, until: CFTimeInterval)?
    private var stubbornCheck: DispatchWorkItem?
    private var sizeRetried = Set<WindowID>()
    private var suspectMoves: [WindowID: Int] = [:]
    /// Windows that were judged not tileable (dialogs, panels), with how many times. Re-judged a few times
    /// because some apps finish setting up a new window after it appears.
    private var rejected: [WindowID: Int] = [:]
    /// Set when a setting changes which windows tile: the next pass asks every app again.
    var needsFullScan = true
    private var pendingVanish: [WindowID: Int] = [:]

    private init() {
        animator.apply = { [weak self] id, frame in self?.place(id, virtual: frame) }
        animator.didFinish = { [weak self] ids in self?.animationFinished(ids) }
        indicator.onSelect = { [weak self] key, column in self?.focusColumn(column, in: key) }
        indicator.onDrop = { [weak self] key, from, drop in self?.dropColumn(from, drop, in: key) }
    }

    // MARK: Lifecycle

    func start() {
        guard !running, AX.isTrusted() else { return }
        running = true
        bootstrapped = false
        needsFullScan = true
        rejected.removeAll()
        Log.write("start")
        installWorkspaceObservers()
        reconcile()
        heartbeat = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.reconcile() }
    }

    /// Stops tiling. Parked windows come back on screen so nothing is left hidden at the edge.
    func stop() {
        guard running else { return }
        Log.write("stop")
        animator.cancelAll()
        springs.removeAll()
        dirtyStrips.removeAll()
        clock.stop()
        bringEverythingBack()
        running = false
        heartbeat?.invalidate()
        heartbeat = nil
        for t in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(t) }
        workspaceTokens.removeAll()
        NotificationCenter.default.removeObserver(self)
        for o in observers.values { o.invalidate() }
        observers.removeAll()
        windows.removeAll()
        strips.removeAll()
        stripKeyOf.removeAll()
        present.removeAll()
        applied.removeAll()
        virtual.removeAll()
        indicator.hide(animated: false)
        border.hide()
    }

    func toggle() {
        if running { stop() } else { start() }
        NotificationCenter.default.post(name: .rubanStateChanged, object: nil)
    }

    private func bringEverythingBack() {
        var pids = Set<pid_t>()
        for (id, w) in windows {
            guard let key = stripKeyOf[id], let d = displays.first(where: { $0.key == key }),
                  let frame = applied[id] else { continue }
            let area = d.params.area
            var f = frame
            if f.maxX <= area.minX + 2 || f.minX >= area.maxX - 2 {
                f.size.width = min(f.width, area.width * 0.7)
                f.origin.x = area.midX - f.width / 2 + CGFloat(Int(id % 5) * 24 - 48)
            }
            f.origin.x = min(max(f.minX, area.minX), area.maxX - f.width)
            // Through the same per-app queue, so no move still in flight can park it again afterwards.
            AXWorker.shared.setFrame(w.element, window: id, pid: w.pid, frame: f, resize: f.width != frame.width)
            pids.insert(w.pid)
        }
        // We may be about to exit: wait (briefly) until every app has taken its last frame.
        let group = DispatchGroup()
        for pid in pids {
            group.enter()
            AXWorker.shared.afterPending(pid) { group.leave() }
        }
        _ = group.wait(timeout: .now() + 2)
    }

    private func installWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let soon: (Notification) -> Void = { [weak self] _ in self?.scheduleReconcile(after: 0.05) }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            workspaceTokens.append(nc.addObserver(forName: name, object: nil, queue: .main, using: soon))
        }
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            self?.syncFocus()
            self?.scheduleReconcile(after: 0.1)
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.needsFullScan = true
            self?.scheduleReconcile(after: 0.25)
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            TrackpadSwipe.shared.restart()
            self?.needsFullScan = true
            self?.scheduleReconcile(after: 1.5)
        })
        workspaceTokens.append(nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReconcile(after: 1.0)
        })
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleReconcile(after: 0.5)
        }
    }

    // MARK: Displays

    private func refreshDisplays() {
        displays = NSScreen.screens.map { screen in
            let uuid = screen.uuidString
            let space = SkyLight.currentSpace(displayUUID: uuid)
            let params = LayoutParams(area: NSScreen.toAX(screen.visibleFrame), screen: NSScreen.toAX(screen.frame),
                                      gap: settings.gap, centre: settings.centreMode)
            return Display(screen: screen, key: "\(uuid)#\(space)", params: params)
        }
    }

    private func display(containing point: CGPoint) -> Display? {
        displays.first { $0.params.screen.contains(point) }
            ?? displays.min { distance($0.params.screen, point) < distance($1.params.screen, point) }
    }

    private func distance(_ r: CGRect, _ p: CGPoint) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    var mouseLocationAX: CGPoint {
        let m = NSEvent.mouseLocation
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: m.x, y: h - m.y)
    }

    /// The strip the user is working in: the one holding the focused window, else the one under the mouse.
    func activeKey() -> String? {
        if let (_, id) = AX.focusedWindow(), let key = stripKeyOf[id], displays.contains(where: { $0.key == key }) { return key }
        return display(containing: mouseLocationAX)?.key
    }

    // MARK: Discovering windows

    func scheduleReconcile(after delay: Double = 0.05) {
        reconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reconcile() }
        reconcileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func isTileable(_ el: AXUIElement, app: NSRunningApplication, id: WindowID) -> Bool {
        if userFloating.contains(id) { return false }
        if let b = app.bundleIdentifier, settings.floatApps.contains(b) { return false }
        guard el.role == kAXWindowRole as String, el.subrole == kAXStandardWindowSubrole as String else { return false }
        guard !el.isMinimized, !el.isFullScreen else { return false }
        guard el.isSettable(kAXPositionAttribute), el.isSettable(kAXSizeAttribute) else { return false }
        guard let size = el.size, size.width >= 120, size.height >= 80 else { return false }
        // Fixed-size windows (Calculator, About boxes) float: their green button is disabled.
        if let zoom = el.element(kAXZoomButtonAttribute), zoom.bool(kAXEnabledAttribute) == false { return false }
        return true
    }

    func reconcile() {
        guard running else { return }
        guard AX.isTrusted() else { return }
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 150 { Log.write("reconcile took \(ms) ms") }
        }
        refreshDisplays()
        let currentKeys = Set(displays.map(\.key))
        let owners = WindowList.onScreenOwners()
        let onScreen = Set(owners.keys)
        var onScreenByPID: [pid_t: Set<WindowID>] = [:]
        for (id, pid) in owners { onScreenByPID[pid, default: []].insert(id) }
        let existing = WindowList.all()
        rejected = rejected.filter { existing.contains($0.key) }
        let full = needsFullScan
        needsFullScan = false
        let me = ProcessInfo.processInfo.processIdentifier

        var tileable: [WindowID: (AXUIElement, NSRunningApplication)] = [:]
        var hiddenPIDs = Set<pid_t>()
        var livePIDs = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != me {
            let pid = app.processIdentifier
            livePIDs.insert(pid)
            let appStart = CACurrentMediaTime()
            defer {
                let ms = Int((CACurrentMediaTime() - appStart) * 1000)
                if ms > 250 { Log.write("  slow app \(app.bundleIdentifier ?? "?"): \(ms) ms") }
            }
            if observers[pid] == nil { observers[pid] = AppObserver(pid: pid) }
            if app.isHidden {
                hiddenPIDs.insert(pid)
                continue
            }
            guard let ids = onScreenByPID[pid], !ids.isEmpty else { continue }
            // Asking an app for its windows is a slow cross-process call. The window server's list is
            // nearly free, so only ask apps that show a window we have not judged yet.
            let unknown = ids.contains { windows[$0] == nil && (rejected[$0] ?? 0) < 3 }
            if !full && !unknown {
                for id in ids { if let w = windows[id] { tileable[id] = (w.element, app) } }
                continue
            }
            var seen = Set<WindowID>()
            for w in AXUIElementCreateApplication(pid).windows {
                guard let id = w.windowID, onScreen.contains(id) else { continue }
                seen.insert(id)
                if isTileable(w, app: app, id: id) {
                    tileable[id] = (w, app)
                    rejected[id] = nil
                } else {
                    rejected[id, default: 0] += 1
                }
            }
            // On-screen windows the app does not list (overlays, helper panels) are never tiles.
            for id in ids.subtracting(seen) where windows[id] == nil { rejected[id, default: 0] += 1 }
        }
        for pid in observers.keys where !livePIDs.contains(pid) {
            observers[pid]?.invalidate()
            observers[pid] = nil
        }

        var changed = false

        // Windows we track that are no longer tileable here.
        var vanished: [WindowID] = []
        for (id, w) in windows where tileable[id] == nil {
            if !existing.contains(id) || !livePIDs.contains(w.pid) {
                drop(id)
                changed = true
                continue
            }
            if hiddenPIDs.contains(w.pid) || w.element.isMinimized { continue } // keep its slot for when it returns
            guard let key = stripKeyOf[id], currentKeys.contains(key) else { continue } // lives on another Space
            vanished.append(id)
        }

        // Tracked windows that now show up on another strip's Space (moved by Mission Control).
        // Space switches are not atomic, so a move only counts once two passes agree.
        var suspects: [WindowID: Int] = [:]
        for (id, entry) in tileable {
            guard let key = stripKeyOf[id], !currentKeys.contains(key), let frame = entry.0.frame,
                  let d = display(containing: CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            suspects[id] = (suspectMoves[id] ?? 0) + 1
            guard suspects[id]! >= 2 else { continue }
            strips[key]?.remove(id)
            add(id, to: d.key)
            changed = true
        }
        suspectMoves = suspects

        // New windows.
        let fresh = tileable.keys.filter { windows[$0] == nil }
            .compactMap { id -> (WindowID, CGRect)? in tileable[id]!.0.frame.map { (id, $0) } }
            .sorted { $0.1.minX < $1.1.minX }
        if !fresh.isEmpty { changed = true }

        if !bootstrapped {
            bootstrap(fresh, tileable: tileable)
        } else {
            for (id, frame) in fresh {
                let (el, app) = tileable[id]!
                let w = TrackedWindow(id: id, pid: app.processIdentifier, element: el,
                                      bundleID: app.bundleIdentifier ?? "", title: el.title)
                // Native tabs and re-created windows: take over the slot of a window that just
                // disappeared from the same app at the same place.
                if let i = vanished.firstIndex(where: { windows[$0]?.pid == w.pid && (applied[$0] ?? .null).isClose(to: frame, tolerance: 4) }) {
                    let old = vanished.remove(at: i)
                    track(w)
                    if let key = stripKeyOf[old] {
                        strips[key]?.replace(old, with: id)
                        stripKeyOf[id] = key
                    }
                    applied[id] = frame
                    virtual[id] = virtual[old]
                    forget(old)
                    continue
                }
                track(w)
                guard let d = display(containing: CGPoint(x: frame.midX, y: frame.midY)) else { continue }
                add(id, to: d.key)
                applied[id] = frame
            }
        }
        // Same caution for windows that left this Space: drop them on the second pass.
        var stillGone: [WindowID: Int] = [:]
        for id in vanished {
            let n = (pendingVanish[id] ?? 0) + 1
            if n >= 2 {
                drop(id)
                changed = true
            } else {
                stillGone[id] = n
            }
        }
        pendingVanish = stillGone
        if !stillGone.isEmpty || !suspectMoves.isEmpty { scheduleReconcile(after: 0.4) }

        let newPresent = Set(tileable.keys).intersection(windows.keys)
        if newPresent != present { changed = true }
        present = newPresent

        if changed {
            Log.write("reconcile: \(present.count) present, strips " + strips.map { "\($0.key.suffix(8)): \($0.value.columns.map { $0.windows })" }.joined(separator: " | "))
            syncFocus(layout: false)
            layoutAll(animated: bootstrapped)
            saveSession()
        }
        bootstrapped = true
    }

    private func bootstrap(_ fresh: [(WindowID, CGRect)], tileable: [WindowID: (AXUIElement, NSRunningApplication)]) {
        var byKey: [String: [(id: WindowID, bundleID: String, title: String)]] = [:]
        for (id, frame) in fresh {
            let (el, app) = tileable[id]!
            let w = TrackedWindow(id: id, pid: app.processIdentifier, element: el, bundleID: app.bundleIdentifier ?? "", title: el.title)
            track(w)
            applied[id] = frame
            guard let d = display(containing: CGPoint(x: frame.midX, y: frame.midY)) else { continue }
            byKey[d.key, default: []].append((id, w.bundleID, w.title))
        }
        for (key, list) in byKey {
            guard let d = displays.first(where: { $0.key == key }) else { continue }
            let inner = d.params.inner.width
            let widthOf: (WindowID) -> Double = { [applied, settings] id in
                // Keep the width the window already has, snapped to the nearest preset.
                guard let f = applied[id] else { return settings.defaultWidth }
                let raw = Layout.fraction(forWidth: f.width, inner: inner, gap: d.params.gap)
                return (settings.presets + [1]).min { abs($0 - raw) < abs($1 - raw) } ?? settings.defaultWidth
            }
            let columns = settings.restoreSession
                ? session.restore(list, key: key, defaultWidth: widthOf)
                : list.map { Column(window: $0.id, width: widthOf($0.id)) }
            var strip = strips[key] ?? Strip()
            strip.columns += columns
            strips[key] = strip
            for c in columns { for id in c.windows { stripKeyOf[id] = key } }
        }
    }

    private func track(_ w: TrackedWindow) {
        windows[w.id] = w
        if observers[w.pid] == nil { observers[w.pid] = AppObserver(pid: w.pid) }
        observers[w.pid]?.watch(w.element)
    }

    /// Adds a window as a new column right of the focused one.
    private func add(_ id: WindowID, to key: String) {
        var strip = strips[key] ?? Strip()
        strip.insert(id, width: settings.defaultWidth, after: strip.columns.isEmpty ? nil : strip.focused)
        strips[key] = strip
        stripKeyOf[id] = key
    }

    private func drop(_ id: WindowID) {
        if let key = stripKeyOf[id] { strips[key]?.remove(id) }
        forget(id)
    }

    private func forget(_ id: WindowID) {
        windows[id] = nil
        stripKeyOf[id] = nil
        applied[id] = nil
        virtual[id] = nil
        present.remove(id)
        animator.cancel(id)
    }

    // MARK: Focus

    /// Follows the system focus: when you click a window or switch apps, the strip scrolls to it.
    /// `reported` is the window an AX notification named, when it named one.
    func syncFocus(layout: Bool = true, reported: WindowID? = nil) {
        guard running else { return }
        guard let id = reported ?? AX.focusedWindow()?.1 else {
            updateBorder()
            return
        }
        // Right after we move focus, macOS can still report the previous window for a moment.
        // Ignore those stale reports instead of jumping back.
        if let p = pendingFocus {
            let now = CACurrentMediaTime()
            if id != p.id && now < p.until {
                // If it was a real change (a click during the window), catch it once the grace period ends.
                DispatchQueue.main.asyncAfter(deadline: .now() + (p.until - now) + 0.05) { [weak self] in self?.syncFocus() }
                return
            }
            pendingFocus = nil
        }
        guard let key = stripKeyOf[id], var strip = strips[key],
              let ci = strip.columnIndex(of: id), let wi = strip.columns[ci].windows.firstIndex(of: id) else {
            updateBorder()
            return
        }
        let changed = strip.focused != ci || strip.columns[ci].active != wi
        strip.focused = ci
        strip.columns[ci].active = wi
        strips[key] = strip
        if changed && layout { self.layout(key, animated: true) }
        updateBorder()
    }

    private func focus(_ id: WindowID) {
        guard let w = windows[id] else { return }
        pendingFocus = (id, CACurrentMediaTime() + 0.6)
        if !SkyLight.focus(pid: w.pid, window: id) {
            NSRunningApplication(processIdentifier: w.pid)?.activate()
        }
        w.element.set(kAXMainAttribute, kCFBooleanTrue)
        w.element.raise()
    }

    func focusColumn(_ column: Int, in key: String) {
        guard var strip = strips[key], strip.columns.indices.contains(column) else { return }
        strip.focused = column
        strips[key] = strip
        if let id = strip.focusedWindow { focus(id) }
        layout(key, animated: true)
        showIndicator(key)
    }

    // MARK: Layout

    /// Re-applies the layout after a setting changed (gap, centring, border).
    func relayout() {
        guard running else { return }
        refreshDisplays()
        layoutAll(animated: true)
        updateBorder()
    }

    func layoutAll(animated: Bool) {
        for d in displays { layout(d.key, animated: animated) }
    }

    func layout(_ key: String, animated: Bool, reveal: Bool = true) {
        guard running, let d = displays.first(where: { $0.key == key }), var strip = strips[key] else { return }
        // A layout change (a key press, a new window) takes over from a settling swipe.
        springs[key] = nil
        let g = Layout.geometry(strip, present: present, d.params)
        if reveal {
            strip.scroll = Layout.revealScroll(g, focused: strip.focused, current: strip.scroll, mode: settings.centreMode)
            strips[key] = strip
        }
        let targets = Layout.frames(strip, present: present, d.params, geometry: g, scroll: strip.scroll)
        let jobs = targets.compactMap { id, to -> (WindowID, from: CGRect, to: CGRect)? in
            guard windows[id] != nil else { return nil }
            let from = virtual[id] ?? applied[id] ?? to
            // Size changes happen up front; only the position slides.
            return (id, CGRect(origin: from.origin, size: to.size), to)
        }
        prepareParking(key, strip: strip, geometry: g, display: d)
        animator.run(jobs, animated: animated && settings.animate, duration: settings.animationDuration)
        raiseTabbedActive(strip)
    }

    /// Remembers where this strip's windows scroll and which ones are pinned, for `place`.
    private func prepareParking(_ key: String, strip: Strip, geometry g: Geometry, display d: Display) {
        regions[key] = g.scrollRegion(d.params)
        pinnedWindows.subtract(strip.columns.flatMap(\.windows))
        for i in g.pinned.keys { pinnedWindows.formUnion(strip.columns[i].windows) }
        screenOf[key] = d.params.screen
    }

    /// Puts every window of a strip where its current scroll offset says, with no animation.
    /// Used on each screen refresh while a swipe or its spring moves the strip.
    private func placeStrip(_ key: String) {
        guard let d = displays.first(where: { $0.key == key }), let strip = strips[key] else { return }
        let g = Layout.geometry(strip, present: present, d.params)
        prepareParking(key, strip: strip, geometry: g, display: d)
        for (id, frame) in Layout.frames(strip, present: present, d.params, geometry: g, scroll: strip.scroll) {
            animator.cancel(id)
            place(id, virtual: frame)
        }
    }

    private var regions: [String: CGRect] = [:]
    private var screenOf: [String: CGRect] = [:]
    private var pinnedWindows: Set<WindowID> = []

    /// Puts one window at a point of its strip, parking it at the screen edge if that point is off screen.
    private func place(_ id: WindowID, virtual frame: CGRect) {
        guard let w = windows[id], let key = stripKeyOf[id] else { return }
        virtual[id] = frame
        var target = frame
        if !pinnedWindows.contains(id), let region = regions[key], let screen = screenOf[key] {
            target = Layout.park(frame, region: region, screen: screen)
        }
        let last = applied[id]
        if let last, last.isClose(to: target, tolerance: 0.5) { return }
        let resize = last.map { abs($0.width - target.width) > 0.5 || abs($0.height - target.height) > 0.5 } ?? true
        AXWorker.shared.setFrame(w.element, window: id, pid: w.pid, frame: target, resize: resize)
        applied[id] = target
    }

    private func animationFinished(_ ids: [WindowID]) {
        ignoreMovesUntil = CACurrentMediaTime() + 0.35
        updateBorder()
        // Stubborn apps: give them a moment to finish resizing, then look at what they chose.
        stubbornCheck?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkStubbornSizes(ids) }
        stubbornCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Reads each moved window's real frame once its app has applied everything we queued.
    private func checkStubbornSizes(_ ids: [WindowID]) {
        for id in ids {
            guard let w = windows[id] else { continue }
            let element = w.element
            AXWorker.shared.afterPending(w.pid) { [weak self] in
                guard let actual = element.frame else { return }
                DispatchQueue.main.async { self?.acceptStubbornSize(id, actual: actual) }
            }
        }
    }

    /// A window that refuses its size (a minimum width, a character grid) keeps the size it insists on,
    /// and its column widens to match so it never overlaps the next one. No fighting, no twitching.
    private func acceptStubbornSize(_ id: WindowID, actual: CGRect) {
        guard running, !animator.isRunning, let w = windows[id], let expected = applied[id] else { return }
        guard !actual.isClose(to: expected, tolerance: 2) else {
            sizeRetried.remove(id)
            return
        }
        // A window caught mid-change (just dropped, still finishing a resize) gets one more try
        // before we decide it really refuses that size.
        if !sizeRetried.contains(id) {
            sizeRetried.insert(id)
            AXWorker.shared.setFrame(w.element, window: id, pid: w.pid, frame: expected, resize: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.checkStubbornSizes([id]) }
            return
        }
        sizeRetried.remove(id)
        applied[id] = actual
        virtual[id] = virtual[id].map { CGRect(origin: $0.origin, size: actual.size) }
        // Only grow: a window wider than asked has a minimum size. Narrower is harmless.
        guard actual.width > expected.width + 2, let key = stripKeyOf[id], var strip = strips[key],
              let ci = strip.columnIndex(of: id), let d = displays.first(where: { $0.key == key }) else { return }
        let needed = Layout.fraction(forWidth: actual.width, inner: d.params.inner.width, gap: d.params.gap)
        guard needed > strip.columns[ci].width + 0.002 else { return }
        Log.write("window \(id) (\(w.bundleID)) insists on \(Int(actual.width)) pt, column widened")
        strip.columns[ci].width = needed
        strips[key] = strip
        layout(key, animated: true)
    }

    private func raiseTabbedActive(_ strip: Strip) {
        guard strip.columns.indices.contains(strip.focused), strip.columns[strip.focused].tabbed,
              let id = strip.focusedWindow else { return }
        windows[id]?.element.raise()
    }

    func updateBorder() {
        guard running, settings.focusBorder, let (_, id) = AX.focusedWindow(), present.contains(id),
              let frame = applied[id] else {
            border.hide()
            return
        }
        border.show(frameAX: frame, width: settings.borderWidth)
    }

    // MARK: Actions

    func perform(_ action: Action) {
        if action == .toggleEnabled {
            toggle()
            return
        }
        guard running else { return }
        springs.removeAll()
        focusWhenSettled.removeAll()
        syncFocus(layout: false)
        guard let key = activeKey(), var strip = strips[key] else {
            Log.write("action \(action.rawValue): no strip")
            return
        }
        Log.write("action \(action.rawValue) focused=\(strip.focused)")
        let before = strip.focusedWindow
        var reveal = true
        var focusChanged = false

        switch action {
        case .focusLeft: focusChanged = strip.focusNeighbor(-1, present: present)
        case .focusRight: focusChanged = strip.focusNeighbor(1, present: present)
        case .focusUp: focusChanged = strip.focusInStack(-1, present: present)
        case .focusDown: focusChanged = strip.focusInStack(1, present: present)
        case .moveLeft: _ = strip.moveColumn(-1, present: present)
        case .moveRight: _ = strip.moveColumn(1, present: present)
        case .moveUp: _ = strip.moveInStack(-1)
        case .moveDown: _ = strip.moveInStack(1)
        case .focusFirst: focusChanged = strip.focusEdge(last: false, present: present)
        case .focusLast: focusChanged = strip.focusEdge(last: true, present: present)
        case .cycleWidth: _ = strip.cycleWidth(presets: settings.presets)
        case .fullWidth: _ = strip.toggleFullWidth()
        case .wider: _ = strip.adjustWidth(by: 0.1)
        case .narrower: _ = strip.adjustWidth(by: -0.1)
        case .taller: _ = strip.adjustHeight(factor: 1.25)
        case .shorter: _ = strip.adjustHeight(factor: 0.8)
        case .equalizeHeights: _ = strip.equalizeHeights()
        case .pinLeft: _ = strip.togglePin(.left)
        case .pinRight: _ = strip.togglePin(.right)
        case .stackLeft: _ = strip.stackIntoNeighbor(-1, present: present)
        case .stackRight: _ = strip.stackIntoNeighbor(1, present: present)
        case .popLeft: _ = strip.popOut(-1)
        case .popRight: _ = strip.popOut(1)
        case .toggleTabbed: _ = strip.toggleTabbed()
        case .centre:
            if let d = displays.first(where: { $0.key == key }) {
                let g = Layout.geometry(strip, present: present, d.params)
                strip.scroll = Layout.centreScroll(g, focused: strip.focused, current: strip.scroll)
                reveal = false
            }
        case .sendToNextDisplay:
            sendToNextDisplay(from: key)
            return
        case .toggleFloat:
            toggleFloat()
            return
        case .toggleEnabled:
            return
        default:
            if let n = action.jumpNumber { focusChanged = strip.focusNumber(n, present: present) }
        }

        strips[key] = strip
        if focusChanged || strip.focusedWindow != before, let id = strip.focusedWindow { focus(id) }
        layout(key, animated: true, reveal: reveal)
        showIndicator(key)
        saveSession()
    }

    private func sendToNextDisplay(from key: String) {
        guard displays.count > 1, let i = displays.firstIndex(where: { $0.key == key }),
              let id = strips[key]?.focusedWindow else { return }
        let next = displays[(i + 1) % displays.count].key
        strips[key]?.remove(id)
        virtual[id] = nil
        add(id, to: next)
        if var s = strips[next], let ci = s.columnIndex(of: id) {
            s.focused = ci
            strips[next] = s
        }
        layout(key, animated: true)
        layout(next, animated: false)
        focus(id)
        showIndicator(next)
    }

    private func toggleFloat() {
        guard let (el, id) = AX.focusedWindow() else { return }
        if userFloating.contains(id) {
            userFloating.remove(id)
            rejected[id] = nil
            reconcile()
            return
        }
        guard let key = stripKeyOf[id], let d = displays.first(where: { $0.key == key }) else { return }
        userFloating.insert(id)
        drop(id)
        present.remove(id)
        // Float it in the middle of the screen, a little smaller, on top of the strip.
        let a = d.params.area
        let f = CGRect(x: a.midX - a.width * 0.3, y: a.minY + a.height * 0.12, width: a.width * 0.6, height: a.height * 0.76)
        el.setFrame(f.integral, resize: true)
        el.raise()
        layout(key, animated: true)
        updateBorder()
    }

    // MARK: Trackpad and mouse

    /// A strip gliding to rest after a swipe. Critically damped: no wobble, and it starts at the
    /// speed the fingers had, so the motion carries on instead of restarting from a standstill.
    private struct ScrollSpring {
        static let omega = 24.0
        let from: Double
        let target: Double
        let velocity: Double
        let start: CFTimeInterval

        func value(at t: Double) -> (x: Double, v: Double) {
            let a = from - target, b = velocity + Self.omega * a
            let e = exp(-Self.omega * t)
            return (target + (a + b * t) * e, (b - Self.omega * (a + b * t)) * e)
        }
    }

    private var springs: [String: ScrollSpring] = [:]
    private var focusWhenSettled: [String: WindowID] = [:]
    private var lastTick: CFTimeInterval = 0
    /// Strips whose scroll changed since the last screen refresh.
    private var dirtyStrips = Set<String>()
    private lazy var clock = FrameClock { [weak self] in self?.frameTick() }

    /// Scrolls the strip under the mouse. Windows move on the next screen refresh, once per frame,
    /// however many trackpad events came in meanwhile.
    func scroll(by delta: Double) {
        guard running, let d = display(containing: mouseLocationAX), var strip = strips[d.key] else { return }
        springs[d.key] = nil
        focusWhenSettled[d.key] = nil
        let g = Layout.geometry(strip, present: present, d.params)
        // Past either end the strip resists, like a rubber band.
        let next = strip.scroll + delta
        let step = next < 0 || next > g.maxScroll ? delta * 0.35 : delta
        let overscroll = g.scrollWidth * 0.12
        strip.scroll = min(max(strip.scroll + step, -overscroll), g.maxScroll + overscroll)
        strips[d.key] = strip
        dirtyStrips.insert(d.key)
        clock.start()
    }

    /// How far the strip travels for a swipe across the whole trackpad, in screen widths.
    private let swipeGain = 1.2

    /// A trackpad swipe moved by `fraction` of the trackpad's width (negative = fingers went left).
    /// The strip follows the fingers: fingers to the left bring in the windows on the right.
    func swipe(by fraction: Double) {
        guard running, let d = display(containing: mouseLocationAX) else { return }
        let sign: Double = settings.invertScroll ? 1 : -1
        scroll(by: sign * fraction * d.params.inner.width * swipeGain)
    }

    /// Fingers lifted: a flick carries on to the next column or two, a slow release settles nearby.
    func endSwipe(velocity: Double) {
        guard running, let d = display(containing: mouseLocationAX) else { return }
        let sign: Double = settings.invertScroll ? 1 : -1
        endScroll(fling: sign * velocity * d.params.inner.width * swipeGain)
        Log.write("swipe ended (speed \(String(format: "%.1f", velocity))), focused column \(strips[d.key]?.focused ?? -1)")
    }

    /// After a swipe, settles on the nearest column and focuses it. `fling` is the strip's speed
    /// when the fingers let go, in points per second; the strip coasts that way before settling.
    func endScroll(fling: Double = 0) {
        guard running, let d = display(containing: mouseLocationAX), var strip = strips[d.key] else { return }
        let g = Layout.geometry(strip, present: present, d.params)
        let coast = max(-g.scrollWidth, min(g.scrollWidth, fling * 0.2))
        guard let snap = Layout.snap(g, scroll: strip.scroll + coast, focused: strip.focused, mode: settings.centreMode) else { return }
        let changed = snap.focused != strip.focused
        strip.focused = snap.focused
        strips[d.key] = strip
        guard settings.animate else {
            strip.scroll = snap.scroll
            strips[d.key] = strip
            dirtyStrips.insert(d.key)
            clock.start()
            if changed, let id = strip.focusedWindow { focus(id) }
            return
        }
        // Activating an app keeps it busy for a moment, and a busy app moves its window late.
        // So the new window gets focus once the strip has come to rest, not while it glides.
        if changed, let id = strip.focusedWindow { focusWhenSettled[d.key] = id }
        // Too much speed for the distance left would overshoot the column: cap it.
        let limit = ScrollSpring.omega * abs(snap.scroll - strip.scroll) * 1.2
        springs[d.key] = ScrollSpring(from: strip.scroll, target: snap.scroll,
                                      velocity: max(-limit, min(limit, fling)), start: CACurrentMediaTime())
        clock.start()
    }

    /// Called on every screen refresh while a strip is being swiped or is gliding to rest.
    private func frameTick() {
        let now = CACurrentMediaTime()
        if lastTick > 0, now - lastTick > 0.05, !dirtyStrips.isEmpty || !springs.isEmpty {
            Log.write("frame late: \(Int((now - lastTick) * 1000)) ms since the previous one")
        }
        lastTick = now
        var settled: [String] = []
        for (key, spring) in springs {
            guard var strip = strips[key] else {
                springs[key] = nil
                continue
            }
            let (x, v) = spring.value(at: now - spring.start)
            let done = abs(x - spring.target) < 1.5 && abs(v) < 60
            strip.scroll = done ? spring.target : x
            strips[key] = strip
            dirtyStrips.insert(key)
            if done {
                springs[key] = nil
                settled.append(key)
            }
        }
        let dirty = dirtyStrips
        dirtyStrips.removeAll()
        for key in dirty {
            placeStrip(key)
            showIndicator(key)
        }
        for key in settled {
            if let id = focusWhenSettled.removeValue(forKey: key) { focus(id) }
            animationFinished(strips[key]?.columns.flatMap(\.windows) ?? [])
            saveSession()
        }
        if springs.isEmpty && dirty.isEmpty {
            clock.stop()
            lastTick = 0
        }
    }

    /// A window moved or resized while the mouse is down: the user is dragging it. Follow the drag,
    /// showing where the window would land, until the mouse comes up.
    func windowMoved(_ element: AXUIElement) {
        guard running, !animator.isRunning, CACurrentMediaTime() > ignoreMovesUntil,
              NSEvent.pressedMouseButtons & 1 != 0, let id = element.windowID, windows[id] != nil else { return }
        guard dragTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            if NSEvent.pressedMouseButtons & 1 == 0 {
                t.invalidate()
                self.dragTimer = nil
                self.dropPreview.hide()
                // Let macOS finish the drag before the window gets its new place and size.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.finishDrag(id) }
            } else if let drop = self.pendingDrop(for: id) {
                self.dropPreview.show(frameAX: drop.frame, below: id)
            } else {
                self.dropPreview.hide()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        dragTimer = timer
    }

    /// What letting go of a dragged window right now would do: the strip it lands on, the drop,
    /// and the frame it would end up with. Nil while the window is being resized rather than moved,
    /// or when the drop would put it back where it was.
    private func pendingDrop(for id: WindowID) -> (key: String, drop: Drop, frame: CGRect)? {
        guard let source = stripKeyOf[id], let old = applied[id], let now = WindowList.bounds(of: id) else { return nil }
        guard abs(now.width - old.width) <= 4, abs(now.height - old.height) <= 4,
              abs(now.minX - old.minX) > 4 || abs(now.minY - old.minY) > 4 else { return nil }
        let mouse = mouseLocationAX
        guard let d = display(containing: mouse) else { return nil }
        let strip = strips[d.key] ?? Strip()
        var frames = Layout.frames(strip, present: present, d.params, geometry: Layout.geometry(strip, present: present, d.params), scroll: strip.scroll)
        frames[id] = nil
        let drop = Layout.dropTarget(at: mouse, moving: id, in: strip, frames: frames)

        // Try it on a copy to see where the window would end up once the strip has settled.
        var result = strip
        if d.key == source {
            guard result.move(id, to: drop) else { return nil }
        } else {
            let width = strips[source].flatMap { s in s.columnIndex(of: id).map { s.columns[$0].width } } ?? settings.defaultWidth
            result.place(id, at: drop, width: width)
        }
        let shown = present.union([id])
        let g = Layout.geometry(result, present: shown, d.params)
        let scroll = Layout.revealScroll(g, focused: result.focused, current: strip.scroll, mode: settings.centreMode)
        guard let frame = Layout.frames(result, present: shown, d.params, geometry: g, scroll: scroll)[id] else { return nil }
        return (d.key, drop, frame)
    }

    private func finishDrag(_ id: WindowID) {
        guard let w = windows[id], let frame = w.element.frame, let old = applied[id],
              let key = stripKeyOf[id], var strip = strips[key], let d = displays.first(where: { $0.key == key }),
              let ci = strip.columnIndex(of: id) else { return }

        if abs(frame.width - old.width) > 4 || abs(frame.height - old.height) > 4 {
            // Resized by hand: the column adopts the new width.
            strip.columns[ci].width = Layout.fraction(forWidth: frame.width, inner: d.params.inner.width, gap: d.params.gap)
            strip.columns[ci].widthBeforeFull = nil
            strips[key] = strip
        } else if let landing = pendingDrop(for: id) {
            // Dragged by its title bar: into a stack, or as a column of its own, wherever it was dropped.
            if landing.key == key {
                strip.move(id, to: landing.drop)
                strips[key] = strip
            } else {
                let width = strip.columns[ci].width
                strips[key]?.remove(id)
                var target = strips[landing.key] ?? Strip()
                target.place(id, at: landing.drop, width: width)
                strips[landing.key] = target
                stripKeyOf[id] = landing.key
                applied[id] = frame
                virtual[id] = frame
                layout(key, animated: true)
                layout(landing.key, animated: true)
                saveSession()
                return
            }
        }
        applied[id] = frame
        virtual[id] = frame
        layout(key, animated: true)
        saveSession()
    }

    /// A column dragged in the strip indicator was dropped onto another column (merge into its
    /// stack) or between two (reorder).
    private func dropColumn(_ from: Int, _ drop: StripBarView.BarDrop, in key: String) {
        guard var strip = strips[key], strip.columns.indices.contains(from) else { return }
        let target: Drop
        switch drop {
        case .stack(let into):
            guard strip.columns.indices.contains(into) else { return }
            target = .stack(column: strip.columns[into].id, before: nil)
        case .before(let column):
            target = .column(before: column.flatMap { strip.columns.indices.contains($0) ? strip.columns[$0].id : nil })
        }
        guard strip.move(column: strip.columns[from].id, to: target) else { return }
        strips[key] = strip
        if let id = strip.focusedWindow { focus(id) }
        layout(key, animated: true)
        showIndicator(key)
        saveSession()
    }

    // MARK: AX notifications

    func handle(_ notification: String, _ element: AXUIElement) {
        guard running else { return }
        switch notification {
        case kAXWindowCreatedNotification:
            // New windows often appear on screen a beat after they are created: look again shortly.
            scheduleReconcile(after: 0.08)
            for delay in [0.35, 0.9] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.reconcile() }
            }
        case kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification:
            syncFocus(reported: element.windowID)
            scheduleReconcile(after: 0.15)
        case kAXWindowMovedNotification, kAXWindowResizedNotification:
            windowMoved(element)
        default:
            scheduleReconcile(after: 0.05)
        }
    }

    // MARK: Indicator and session

    func showIndicator(_ key: String) {
        guard settings.showIndicator, let strip = strips[key], let d = displays.first(where: { $0.key == key }) else { return }
        let g = Layout.geometry(strip, present: present, d.params)
        indicator.show(key: key, strip: strip, present: present, windows: windows, geometry: g, params: d.params,
                       holdWhile: settings.modifiers.flags)
    }

    private func saveSession() {
        session.scheduleSave { [weak self] in
            guard let self else { return [:] }
            var out: [String: [SessionStore.SavedColumn]] = [:]
            for w in self.windows.values where self.present.contains(w.id) { w.title = w.element.title }
            for (key, strip) in self.strips where !strip.columns.isEmpty {
                out[key] = strip.columns.map { c in
                    SessionStore.SavedColumn(
                        items: c.windows.compactMap { id in self.windows[id].map { SessionStore.Item(bundleID: $0.bundleID, title: $0.title) } },
                        width: c.width, tabbed: c.tabbed, pinned: c.pinned)
                }
            }
            return out
        }
    }
}

extension Notification.Name {
    static let rubanStateChanged = Notification.Name("RubanStateChanged")
}

/// One AXObserver per app, delivering window events on the main run loop.
final class AppObserver {
    let pid: pid_t
    private var observer: AXObserver?
    private var watched = Set<WindowID>()

    init?(pid: pid_t) {
        self.pid = pid
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, _ in
            WindowManager.shared.handle(notification as String, element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else { return nil }
        observer = obs
        let app = AXUIElementCreateApplication(pid)
        for n in [kAXWindowCreatedNotification, kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                  kAXApplicationHiddenNotification, kAXApplicationShownNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
    }

    func watch(_ window: AXUIElement) {
        guard let observer, let id = window.windowID, !watched.contains(id) else { return }
        watched.insert(id)
        for n in [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
                  kAXWindowMovedNotification, kAXWindowResizedNotification] {
            AXObserverAddNotification(observer, window, n as CFString, nil)
        }
    }

    func invalidate() {
        guard let observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        self.observer = nil
    }
}
