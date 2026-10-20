import AppKit
import Combine
import RubanCore

/// User preferences, stored in UserDefaults. Every change applies at once: there is no Save button.
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Called after any change that affects the layout.
    var onLayoutChange: (() -> Void)?
    /// Called when the rules for which windows tile change.
    var onRulesChange: (() -> Void)?
    var onShortcutsChange: (() -> Void)?

    @Published var gap: Double { didSet { d.set(gap, forKey: "gap"); onLayoutChange?() } }
    @Published var defaultWidth: Double { didSet { d.set(defaultWidth, forKey: "defaultWidth") } }
    @Published var presetsText: String { didSet { d.set(presetsText, forKey: "presets") } }
    @Published var centreMode: CentreMode { didSet { d.set(centreMode.rawValue, forKey: "centreMode"); onLayoutChange?() } }
    @Published var animate: Bool { didSet { d.set(animate, forKey: "animate") } }
    @Published var animationDuration: Double { didSet { d.set(animationDuration, forKey: "animationDuration") } }
    @Published var showIndicator: Bool { didSet { d.set(showIndicator, forKey: "showIndicator") } }
    @Published var focusBorder: Bool { didSet { d.set(focusBorder, forKey: "focusBorder"); onLayoutChange?() } }
    @Published var borderWidth: Double { didSet { d.set(borderWidth, forKey: "borderWidth"); onLayoutChange?() } }
    @Published var floatApps: [String] { didSet { d.set(floatApps, forKey: "floatApps"); onRulesChange?() } }
    @Published var modifiers: ModifierPreset { didSet { d.set(modifiers.rawValue, forKey: "modifiers"); onShortcutsChange?() } }
    @Published var scrollWithModifiers: Bool { didSet { d.set(scrollWithModifiers, forKey: "scrollWithModifiers") } }
    /// Fingers for the trackpad swipe: 3, 4, or 0 for off.
    @Published var swipeFingers: Int { didSet { d.set(swipeFingers, forKey: "swipeFingers"); TrackpadSwipe.shared.start(fingers: swipeFingers) } }
    @Published var invertScroll: Bool { didSet { d.set(invertScroll, forKey: "invertScroll") } }
    @Published var restoreSession: Bool { didSet { d.set(restoreSession, forKey: "restoreSession") } }
    @Published var onboarded: Bool { didSet { d.set(onboarded, forKey: "onboarded") } }

    private init() {
        d.register(defaults: [
            "gap": 8.0,
            "defaultWidth": 0.5,
            "presets": "33, 50, 66",
            "centreMode": CentreMode.never.rawValue,
            "animate": true,
            "animationDuration": 0.22,
            "showIndicator": true,
            "focusBorder": false,
            "borderWidth": 3.0,
            "floatApps": ["com.apple.systempreferences", "com.apple.calculator", "com.apple.ScreenContinuity"],
            "modifiers": ModifierPreset.controlOption.rawValue,
            "scrollWithModifiers": true,
            "swipeFingers": 3,
            "invertScroll": false,
            "restoreSession": true,
            "onboarded": false,
        ])
        gap = d.double(forKey: "gap")
        defaultWidth = d.double(forKey: "defaultWidth")
        presetsText = d.string(forKey: "presets") ?? "33, 50, 66"
        centreMode = CentreMode(rawValue: d.string(forKey: "centreMode") ?? "") ?? .never
        animate = d.bool(forKey: "animate")
        animationDuration = d.double(forKey: "animationDuration")
        showIndicator = d.bool(forKey: "showIndicator")
        focusBorder = d.bool(forKey: "focusBorder")
        borderWidth = d.double(forKey: "borderWidth")
        floatApps = d.stringArray(forKey: "floatApps") ?? []
        modifiers = ModifierPreset(rawValue: d.string(forKey: "modifiers") ?? "") ?? .controlOption
        scrollWithModifiers = d.bool(forKey: "scrollWithModifiers")
        swipeFingers = d.integer(forKey: "swipeFingers")
        invertScroll = d.bool(forKey: "invertScroll")
        restoreSession = d.bool(forKey: "restoreSession")
        onboarded = d.bool(forKey: "onboarded")
    }

    /// Width presets as fractions, parsed from "33, 50, 66" (percentages).
    var presets: [Double] {
        let values = presetsText
            .split(whereSeparator: { ",; ".contains($0) })
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")) }
            .filter { $0 >= 10 && $0 <= 100 }
            .map { $0 >= 99.5 ? 1 : $0 / 100 }
        let fixed = values.map { v -> Double in
            // 33 and 66 mean thirds.
            if abs(v - 0.33) < 0.006 { return 1.0 / 3 }
            if abs(v - 0.66) < 0.006 || abs(v - 0.67) < 0.006 { return 2.0 / 3 }
            return v
        }
        return fixed.isEmpty ? [1.0 / 3, 0.5, 2.0 / 3] : Array(Set(fixed)).sorted()
    }
}
