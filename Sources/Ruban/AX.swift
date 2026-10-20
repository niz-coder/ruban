import AppKit
import ApplicationServices
import RubanCore

// Private but long-standing: every macOS window manager uses it to map an AX element to its CGWindowID.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

enum AX {
    static func isTrusted(prompt: Bool = false) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// The window that has keyboard focus, as seen by the frontmost app.
    static func focusedWindow() -> (AXUIElement, WindowID)? {
        // The system-wide element is updated as soon as focus moves; NSWorkspace's frontmost app can lag.
        if let app = AXUIElementCreateSystemWide().element(kAXFocusedApplicationAttribute),
           let w = app.element(kAXFocusedWindowAttribute), let id = w.windowID {
            return (w, id)
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let w = axApp.element(kAXFocusedWindowAttribute), let id = w.windowID else { return nil }
        return (w, id)
    }
}

extension AXUIElement {
    func value(_ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &v) == .success else { return nil }
        return v
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let v = value(attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    func string(_ attribute: String) -> String? { value(attribute) as? String }
    func bool(_ attribute: String) -> Bool? { value(attribute) as? Bool }

    var windows: [AXUIElement] { (value(kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String { string(kAXTitleAttribute) ?? "" }
    var isMinimized: Bool { bool(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { bool("AXFullScreen") ?? false }

    var windowID: WindowID? {
        var id: CGWindowID = 0
        guard _AXUIElementGetWindow(self, &id) == .success, id != 0 else { return nil }
        return id
    }

    var position: CGPoint? {
        guard let v = value(kAXPositionAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    var size: CGSize? {
        guard let v = value(kAXSizeAttribute), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    var frame: CGRect? {
        guard let p = position, let s = size else { return nil }
        return CGRect(origin: p, size: s)
    }

    func isSettable(_ attribute: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(self, attribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> Bool {
        AXUIElementSetAttributeValue(self, attribute as CFString, value) == .success
    }

    func setPosition(_ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { set(kAXPositionAttribute, v) }
    }

    func setSize(_ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { set(kAXSizeAttribute, v) }
    }

    /// macOS clamps a size against the current position, so size → position → size lands the frame reliably.
    func setFrame(_ frame: CGRect, resize: Bool) {
        if resize { setSize(frame.size) }
        setPosition(frame.origin)
        if resize { setSize(frame.size) }
    }

    func raise() { AXUIElementPerformAction(self, kAXRaiseAction as CFString) }
}

/// The handful of private SkyLight calls window managers rely on, looked up at runtime so a
/// missing symbol degrades gracefully instead of crashing.
enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, in h: UnsafeMutableRawPointer? = handle) -> T? {
        guard let p = dlsym(h ?? UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias DisplaySpace = @convention(c) (Int32, CFString) -> UInt64
    private typealias SetFront = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32) -> Int32
    private typealias PostEvent = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt8>) -> Int32
    private typealias ProcessForPID = @convention(c) (pid_t, UnsafeMutableRawPointer) -> OSStatus

    private static let mainConnection: MainConnection? = symbol("SLSMainConnectionID")
    private static let displaySpace: DisplaySpace? = symbol("SLSManagedDisplayGetCurrentSpace")
    private static let setFront: SetFront? = symbol("_SLPSSetFrontProcessWithOptions")
    private static let postEvent: PostEvent? = symbol("SLPSPostEventRecordTo")
    private static let processForPID: ProcessForPID? = symbol("GetProcessForPID", in: nil)

    static func currentSpace(displayUUID: String) -> UInt64 {
        guard let mainConnection, let displaySpace else { return 0 }
        return displaySpace(mainConnection(), displayUUID as CFString)
    }

    /// Brings one specific window to the front and gives it keyboard focus, the way yabai and AeroSpace do.
    static func focus(pid: pid_t, window: WindowID) -> Bool {
        guard let processForPID, let setFront, let postEvent else { return false }
        var psn = [UInt32](repeating: 0, count: 2)
        let ok = psn.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress, processForPID(pid, base) == noErr else { return false }
            _ = setFront(base, window, 0x200) // kCPSUserGenerated
            var id = window
            for kind: UInt8 in [0x01, 0x02] {
                var bytes = [UInt8](repeating: 0, count: 0xf8)
                bytes[0x04] = 0xf8
                bytes[0x08] = kind
                bytes[0x3a] = 0x10
                for i in 0x20..<0x30 { bytes[i] = 0xff }
                withUnsafeBytes(of: &id) { idBytes in
                    for (k, b) in idBytes.enumerated() { bytes[0x3c + k] = b }
                }
                _ = bytes.withUnsafeMutableBufferPointer { postEvent(base, $0.baseAddress!) }
            }
            return true
        }
        return ok
    }
}

enum WindowList {
    /// On-screen windows of the current Space with the pid that owns each.
    static func onScreenOwners() -> [WindowID: pid_t] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [WindowID: pid_t] = [:]
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            if let n = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32 { out[n] = pid }
        }
        return out
    }

    /// Every window that still exists, on any Space.
    static func all() -> Set<WindowID> { ids([.optionAll]) }

    private static func ids(_ options: CGWindowListOption) -> Set<WindowID> {
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out = Set<WindowID>()
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            if let n = info[kCGWindowNumber as String] as? UInt32 { out.insert(n) }
        }
        return out
    }
}

extension CGRect {
    func isClose(to other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    var uuidString: String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return "\(displayID)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Converts a Cocoa rect (bottom-left origin) to the Accessibility space (top-left of the main display).
    static func toAX(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? r.maxY
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func toCocoa(_ r: CGRect) -> CGRect { toAX(r) } // the flip is its own inverse
}
