import AppKit
import RubanCore
import SwiftUI

/// Developer aid: `Ruban --snapshot <dir>` draws the settings tabs and a sample strip indicator
/// into PNG files, without touching any window, then exits.
enum Snapshot {
    static func run(into dir: String) {
        Hotkeys.shared.register(Settings.shared.modifiers)
        for tab in 0..<5 {
            let view = NSHostingView(rootView: SettingsView(tab: tab))
            view.frame = CGRect(x: 0, y: 0, width: 620, height: 600)
            write(view, to: "\(dir)/settings-\(tab).png")
        }

        var strip = Strip()
        for id: WindowID in 1...5 { strip.insert(id, width: [0.5, 1.0 / 3, 0.5, 2.0 / 3, 0.5][Int(id) - 1], after: strip.columns.isEmpty ? nil : strip.columns.count - 1) }
        strip.focused = 2
        let bar = StripBarView()
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.icon != nil }
        bar.tiles = strip.columns.enumerated().map { i, c in
            .init(column: i, width: c.width, icons: [apps[i % max(apps.count, 1)].icon!], count: 1,
                  focused: i == 2, visible: (1...3).contains(i), pinned: i == 0, tabbed: false)
        }
        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: bar.fittingSize))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        bar.frame = effect.bounds
        effect.addSubview(bar)
        write(effect, to: "\(dir)/indicator.png")
    }

    private static func write(_ view: NSView, to path: String) {
        let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
