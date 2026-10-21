import AppKit
import ApplicationServices
import RubanCore

/// One look at which windows exist and which of them tile, taken away from the main thread.
///
/// Every question here goes to another process: the window server for the window lists and the
/// current Spaces, each app for its windows. When the window server struggles or an app is busy,
/// the answers can take seconds (half a minute once, under the lock screen). Asked on the main
/// thread, they froze the animations and, through the scroll tap, scrolling in every app.
struct WindowScan {
    struct App {
        let pid: pid_t
        let bundleID: String
        let isHidden: Bool
    }

    /// What the scan needs from the main thread, copied before it starts.
    struct Input {
        let generation: Int
        /// Ask every app for its windows, not only the apps showing a window not judged lately.
        let full: Bool
        let displayUUIDs: [String]
        let apps: [App]
        /// Windows already on a strip.
        let tracked: [WindowID: (element: AXUIElement, pid: pid_t)]
        let rejected: [WindowID: CFTimeInterval]
        let userFloating: Set<WindowID>
        let floatApps: Set<String>
    }

    /// Windows judged not tileable (dialogs, panels, full-screen windows) are judged again after
    /// this long: a window leaving full screen, or one its app finishes setting up, becomes tileable.
    static let rejudgeAfter = 3.0

    let input: Input
    let now: CFTimeInterval
    /// Current Space of each display, by display UUID.
    var spaces: [String: UInt64] = [:]
    /// Every window that still exists, on any Space.
    var existing = Set<WindowID>()
    /// Where the window server shows each on-screen window.
    var bounds: [WindowID: CGRect] = [:]
    var tileable: [WindowID: (element: AXUIElement, app: App)] = [:]
    /// Judged during this scan: tileable now, or not.
    var accepted = Set<WindowID>()
    var refused = Set<WindowID>()
    /// Frame and title of the tileable windows not tracked yet.
    var fresh: [WindowID: (frame: CGRect, title: String)] = [:]
    /// Tracked windows that are not tileable because they are minimised.
    var minimized = Set<WindowID>()
    var hiddenPIDs = Set<pid_t>()
    var livePIDs = Set<pid_t>()

    /// Off the main thread only: every call in here may wait on another process.
    static func run(_ input: Input) -> WindowScan {
        let started = CACurrentMediaTime()
        defer {
            let ms = Int((CACurrentMediaTime() - started) * 1000)
            if ms > 150 { Log.write("scan took \(ms) ms") }
        }
        var scan = WindowScan(input: input, now: started)
        for uuid in input.displayUUIDs { scan.spaces[uuid] = SkyLight.currentSpace(displayUUID: uuid) }
        let onScreen = WindowList.onScreen()
        var onScreenByPID: [pid_t: Set<WindowID>] = [:]
        for (id, w) in onScreen {
            onScreenByPID[w.pid, default: []].insert(id)
            scan.bounds[id] = w.bounds
        }
        scan.existing = WindowList.all()

        for app in input.apps {
            scan.livePIDs.insert(app.pid)
            let appStart = CACurrentMediaTime()
            defer {
                let ms = Int((CACurrentMediaTime() - appStart) * 1000)
                if ms > 250 { Log.write("  slow app \(app.bundleID.isEmpty ? "?" : app.bundleID): \(ms) ms") }
            }
            if app.isHidden {
                scan.hiddenPIDs.insert(app.pid)
                continue
            }
            guard let ids = onScreenByPID[app.pid], !ids.isEmpty else { continue }
            // Asking an app for its windows is a slow cross-process call. The window server's list is
            // nearly free, so only ask apps that show a window we have not judged yet.
            let unknown = ids.contains { input.tracked[$0] == nil && started - (input.rejected[$0] ?? 0) > rejudgeAfter }
            if !input.full && !unknown {
                for id in ids { if let w = input.tracked[id] { scan.tileable[id] = (w.element, app) } }
                continue
            }
            var seen = Set<WindowID>()
            for w in AXUIElementCreateApplication(app.pid).windows {
                guard let id = w.windowID, onScreen[id] != nil else { continue }
                seen.insert(id)
                if isTileable(w, app: app, id: id, input) {
                    scan.tileable[id] = (w, app)
                    scan.accepted.insert(id)
                } else {
                    scan.refused.insert(id)
                }
            }
            // On-screen windows the app does not list (overlays, helper panels) are never tiles.
            scan.refused.formUnion(ids.subtracting(seen).filter { input.tracked[$0] == nil })
        }

        // Tracked windows that stopped tiling here: a minimised one keeps its slot for when it returns.
        for (id, w) in input.tracked where scan.tileable[id] == nil && scan.existing.contains(id)
            && scan.livePIDs.contains(w.pid) && !scan.hiddenPIDs.contains(w.pid) && w.element.isMinimized {
            scan.minimized.insert(id)
        }
        for (id, entry) in scan.tileable where input.tracked[id] == nil {
            guard let frame = entry.element.frame else { continue }
            scan.fresh[id] = (frame, entry.element.title)
        }
        return scan
    }

    private static func isTileable(_ el: AXUIElement, app: App, id: WindowID, _ input: Input) -> Bool {
        if input.userFloating.contains(id) || input.floatApps.contains(app.bundleID) { return false }
        guard el.role == kAXWindowRole as String, el.subrole == kAXStandardWindowSubrole as String else { return false }
        guard !el.isMinimized, !el.isFullScreen else { return false }
        guard el.isSettable(kAXPositionAttribute), el.isSettable(kAXSizeAttribute) else { return false }
        guard let size = el.size, size.width >= 120, size.height >= 80 else { return false }
        // Fixed-size windows (Calculator, About boxes) float: their green button is disabled.
        if let zoom = el.element(kAXZoomButtonAttribute), zoom.bool(kAXEnabledAttribute) == false { return false }
        return true
    }
}
