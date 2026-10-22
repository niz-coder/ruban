import AppKit
import Carbon

enum Action: String, CaseIterable {
    case focusLeft = "focus-left", focusRight = "focus-right", focusUp = "focus-up", focusDown = "focus-down"
    case moveLeft = "move-left", moveRight = "move-right", moveUp = "move-up", moveDown = "move-down"
    case focusFirst = "focus-first", focusLast = "focus-last"
    case jump1 = "jump-1", jump2 = "jump-2", jump3 = "jump-3", jump4 = "jump-4", jump5 = "jump-5"
    case jump6 = "jump-6", jump7 = "jump-7", jump8 = "jump-8", jump9 = "jump-9"
    case sendToNextDisplay = "send-to-next-display"
    case toggleEnabled = "toggle"
    case cycleWidth = "cycle-width", fullWidth = "full-width", centre = "centre"
    case wider, narrower, taller, shorter
    case equalizeHeights = "equalize-heights"
    case pinLeft = "pin-left", pinRight = "pin-right"
    case stackLeft = "stack-left", stackRight = "stack-right", popLeft = "pop-left", popRight = "pop-right"
    case toggleTabbed = "toggle-tabbed", toggleFloat = "toggle-float"

    var jumpNumber: Int? {
        guard rawValue.hasPrefix("jump-") else { return nil }
        return Int(rawValue.dropFirst(5))
    }

    var label: String {
        switch self {
        case .focusLeft: "Focus à gauche"
        case .focusRight: "Focus à droite"
        case .focusUp: "Focus en haut de la pile"
        case .focusDown: "Focus en bas de la pile"
        case .moveLeft: "Déplacer à gauche"
        case .moveRight: "Déplacer à droite"
        case .moveUp: "Monter dans la pile"
        case .moveDown: "Descendre dans la pile"
        case .focusFirst: "Première fenêtre"
        case .focusLast: "Dernière fenêtre"
        case .sendToNextDisplay: "Envoyer à l'écran suivant"
        case .toggleEnabled: "Activer / mettre en pause Ruban"
        case .cycleWidth: "Largeur suivante"
        case .fullWidth: "Pleine largeur"
        case .centre: "Centrer la colonne"
        case .wider: "Plus large"
        case .narrower: "Plus étroite"
        case .taller: "Plus haute"
        case .shorter: "Moins haute"
        case .equalizeHeights: "Égaliser les hauteurs"
        case .pinLeft: "Épingler au bord gauche"
        case .pinRight: "Épingler au bord droit"
        case .stackLeft: "Empiler dans la colonne de gauche"
        case .stackRight: "Empiler dans la colonne de droite"
        case .popLeft: "Sortir de la pile vers la gauche"
        case .popRight: "Sortir de la pile vers la droite"
        case .toggleTabbed: "Colonne en onglets"
        case .toggleFloat: "Flottante / tuilée"
        default: "Aller à la fenêtre \(jumpNumber ?? 0)"
        }
    }
}

/// A key, either by the character it types on the current layout (so AZERTY users get
/// the letter printed on the key) or by its physical position.
enum Key: Equatable {
    case char(String)
    case code(Int)
}

struct Shortcut {
    let action: Action
    let key: Key
    let shift: Bool
    let command: Bool

    init(_ action: Action, _ key: Key, shift: Bool = false, command: Bool = false) {
        self.action = action
        self.key = key
        self.shift = shift
        self.command = command
    }

    static let defaults: [Shortcut] = {
        var b: [Shortcut] = []
        let nav: [(Action, Action, String, Int)] = [
            (.focusLeft, .moveLeft, "h", kVK_LeftArrow),
            (.focusDown, .moveDown, "j", kVK_DownArrow),
            (.focusUp, .moveUp, "k", kVK_UpArrow),
            (.focusRight, .moveRight, "l", kVK_RightArrow),
        ]
        for (focus, move, letter, arrow) in nav {
            b.append(Shortcut(focus, .code(arrow)))
            b.append(Shortcut(focus, .char(letter)))
            b.append(Shortcut(move, .code(arrow), shift: true))
            b.append(Shortcut(move, .char(letter), shift: true))
        }
        b.append(Shortcut(.focusFirst, .code(kVK_LeftArrow), command: true))
        b.append(Shortcut(.focusLast, .code(kVK_RightArrow), command: true))
        let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5, kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        let jumps: [Action] = [.jump1, .jump2, .jump3, .jump4, .jump5, .jump6, .jump7, .jump8, .jump9]
        for (code, action) in zip(digits, jumps) { b.append(Shortcut(action, .code(code))) }
        b += [
            Shortcut(.sendToNextDisplay, .char("n")),
            Shortcut(.toggleEnabled, .char("q")),
            Shortcut(.cycleWidth, .char("r")),
            Shortcut(.fullWidth, .char("f")),
            Shortcut(.centre, .char("c")),
            Shortcut(.wider, .char("=")),
            Shortcut(.narrower, .char("-")),
            Shortcut(.taller, .char("="), shift: true),
            Shortcut(.shorter, .char("-"), shift: true),
            Shortcut(.equalizeHeights, .code(kVK_ANSI_0)),
            Shortcut(.pinLeft, .char("p")),
            Shortcut(.pinRight, .char("p"), shift: true),
            // The two keys right of P: ] and [ on US keyboards, $ and ^ on a French one.
            Shortcut(.stackLeft, .code(kVK_ANSI_RightBracket)),
            Shortcut(.stackRight, .code(kVK_ANSI_LeftBracket)),
            Shortcut(.popRight, .code(kVK_ANSI_RightBracket), shift: true),
            Shortcut(.popLeft, .code(kVK_ANSI_LeftBracket), shift: true),
            Shortcut(.toggleTabbed, .char("t"), shift: true),
            Shortcut(.toggleFloat, .char("t")),
        ]
        return b
    }()
}

enum ModifierPreset: String, CaseIterable, Identifiable {
    case controlOption, controlOptionCommand

    var id: String { rawValue }
    var carbon: UInt32 {
        switch self {
        case .controlOption: UInt32(controlKey | optionKey)
        case .controlOptionCommand: UInt32(controlKey | optionKey | cmdKey)
        }
    }
    var flags: NSEvent.ModifierFlags {
        switch self {
        case .controlOption: [.control, .option]
        case .controlOptionCommand: [.control, .option, .command]
        }
    }
    var symbol: String {
        switch self {
        case .controlOption: "⌃⌥"
        case .controlOptionCommand: "⌃⌥⌘"
        }
    }
}

enum KeyboardLayout {
    /// Maps each character of the current layout to the key code that types it.
    static func characterMap() -> [String: Int] {
        var map: [String: Int] = [:]
        for code in 0..<128 {
            if let s = character(for: code), map[s] == nil { map[s] = code }
        }
        return map
    }

    static func character(for code: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var dead: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let s = String(utf16CodeUnits: chars, count: length).lowercased()
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
        }
    }

    static func label(for code: Int) -> String {
        switch code {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: return (character(for: code) ?? "?").uppercased()
        }
    }
}

final class Hotkeys {
    static let shared = Hotkeys()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: Action] = [:]
    private var handlerInstalled = false
    var onAction: ((Action) -> Void)?

    /// Every registered shortcut, for the settings window: (action, display string).
    private(set) var registered: [(Action, String)] = []
    /// Shortcuts that could not be registered, and why, for the settings window.
    private(set) var unavailable: [(action: Action, keys: String, reason: String)] = []

    func register(_ preset: ModifierPreset) {
        unregisterAll()
        installHandler()
        let chars = KeyboardLayout.characterMap()
        var taken = Set<UInt64>()
        var nextID: UInt32 = 1
        for b in Shortcut.defaults {
            var text = preset.symbol
            if b.command && preset != .controlOptionCommand { text += "⌘" }
            if b.shift { text += "⇧" }
            let code: Int
            switch b.key {
            case .code(let c): code = c
            case .char(let ch):
                guard let c = chars[ch] else {
                    unavailable.append((b.action, text + " " + ch.uppercased(), "Cette touche n'existe pas sur ta disposition de clavier."))
                    continue
                }
                code = c
            }
            text += " " + KeyboardLayout.label(for: code)
            var mods = preset.carbon
            if b.shift { mods |= UInt32(shiftKey) }
            if b.command { mods |= UInt32(cmdKey) }
            let k = UInt64(code) << 32 | UInt64(mods)
            guard !taken.contains(k) else {
                unavailable.append((b.action, text, "Même combinaison qu'un autre raccourci avec \(preset.symbol)."))
                continue
            }
            taken.insert(k)

            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x5242_414E), id: nextID) // 'RBAN'
            let status = RegisterEventHotKey(UInt32(code), mods, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[nextID] = b.action
                registered.append((b.action, text))
            } else {
                unavailable.append((b.action, text, "macOS a refusé de l'enregistrer."))
            }
            nextID += 1
        }
        Log.write("hotkeys: \(refs.count) registered with \(preset.symbol)"
                  + unavailable.map { ", \($0.action.rawValue) \($0.keys) unavailable" }.joined())
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
        registered.removeAll()
        unavailable.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        Log.write("hotkey \(action.rawValue)")
        onAction?(action)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard status == noErr else { return status }
            let id = hk.id
            DispatchQueue.main.async { Hotkeys.shared.fire(id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
