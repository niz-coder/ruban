import AppKit
import Carbon
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var permissionTimer: Timer?
    private let wm = WindowManager.shared
    private let settings = Settings.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.4)
        Guardian.spawn()
        setupStatusItem()

        Hotkeys.shared.onAction = { [weak self] action in
            self?.wm.perform(action)
            self?.refreshStatus()
        }
        Hotkeys.shared.register(settings.modifiers)
        settings.onShortcutsChange = { [weak self] in Hotkeys.shared.register(self?.settings.modifiers ?? .controlOption) }
        settings.onLayoutChange = { [weak self] in self?.wm.relayout() }
        settings.onRulesChange = { [weak self] in
            guard let self, self.wm.running else { return }
            self.wm.needsFullScan = true
            self.wm.reconcile()
        }
        // Follow keyboard layout switches (AZERTY ↔ QWERTY) so letters stay on the right keys.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
                                                            object: nil, queue: .main) { [weak self] _ in
            Hotkeys.shared.register(self?.settings.modifiers ?? .controlOption)
        }
        NotificationCenter.default.addObserver(forName: .rubanStateChanged, object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatus()
        }

        if AX.isTrusted(prompt: true) {
            startTiling()
        } else {
            waitForPermission()
        }
        if !settings.onboarded || !AX.isTrusted() {
            settings.onboarded = true
            showSettings()
        }
        refreshStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        wm.stop(exiting: true)
        Guardian.markCleanExit()
    }

    private func startTiling() {
        wm.start() // also installs the scroll tap when it has something to do
        TrackpadSwipe.shared.start(fingers: settings.swipeFingers)
        refreshStatus()
    }

    /// macOS gives no callback when the Accessibility switch flips, so check every second.
    private func waitForPermission() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard AX.isTrusted() else { return }
            t.invalidate()
            self?.permissionTimer = nil
            self?.startTiling()
            AppState.shared.refresh()
        }
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func refreshStatus() {
        let running = wm.running
        let name = running ? "rectangle.split.3x1.fill" : "rectangle.split.3x1"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "Ruban")
        img?.isTemplate = true
        statusItem.button?.image = img
        statusItem.button?.appearsDisabled = !running || wm.trustLost
        AppState.shared.refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let m = settings.modifiers.symbol
        let trusted = AX.isTrusted()
        let state = !trusted
            ? (wm.running ? "Ruban a perdu l'autorisation Accessibilité" : "Ruban attend l'autorisation Accessibilité")
            : (wm.running ? "Ruban est actif" : "Ruban est en pause")
        menu.addItem(note(state))
        if wm.running && !trusted {
            menu.addItem(note("Les fenêtres garées reviendront dès qu'elle sera rendue."))
        } else if wm.running {
            let count = wm.present.count
            menu.addItem(note("\(count) fenêtre\(count > 1 ? "s" : "") sur la bande"))
        }
        if wm.running && wm.swipeConflict && settings.swipeFingers > 0 {
            let it = item("Balayage à \(settings.swipeFingers) doigts laissé à macOS…", #selector(showGestureSettings))
            it.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Attention")
            menu.addItem(it)
        }
        menu.addItem(.separator())

        if !trusted {
            menu.addItem(item("Autoriser l'accessibilité…", #selector(openAccessibility)))
        } else {
            menu.addItem(item(wm.running ? "Mettre en pause  (\(m)Q)" : "Activer  (\(m)Q)", #selector(toggleRunning)))
        }
        menu.addItem(.separator())
        let actions: [(String, Action)] = [
            ("Largeur suivante  (\(m)R)", .cycleWidth),
            ("Pleine largeur  (\(m)F)", .fullWidth),
            ("Centrer la colonne  (\(m)C)", .centre),
            ("Épingler à gauche  (\(m)P)", .pinLeft),
            ("Colonne en onglets  (\(m)⇧T)", .toggleTabbed),
            ("Faire flotter la fenêtre  (\(m)T)", .toggleFloat),
        ]
        for (title, action) in actions {
            let it = item(title, #selector(runAction(_:)))
            it.representedObject = action.rawValue
            it.isEnabled = wm.running
            menu.addItem(it)
        }
        menu.addItem(.separator())
        menu.addItem(item("Réglages…", #selector(showSettings), key: ","))
        menu.addItem(item("Quitter Ruban", #selector(quit), key: "q"))
    }

    private func note(_ title: String) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
        it.target = self
        return it
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = Action(rawValue: raw) else { return }
        // Let the menu close and focus return to the window first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.wm.perform(action) }
    }

    @objc private func toggleRunning() {
        wm.toggle()
        if wm.running { TrackpadSwipe.shared.start(fingers: settings.swipeFingers) }
        refreshStatus()
    }

    @objc private func openAccessibility() {
        _ = AX.isTrusted(prompt: true)
        AX.openAccessibilitySettings()
        waitForPermission()
    }

    @objc func showSettings() {
        openSettings(tab: nil)
    }

    /// The trackpad settings, where the gesture conflict is explained with a way to fix it.
    @objc func showGestureSettings() {
        openSettings(tab: 2)
    }

    func openSettings(tab: Int?) {
        if let tab { SettingsNavigation.shared.tab = tab }
        if settingsWindow == nil {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 620, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Réglages de Ruban"
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        AppState.shared.refresh()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: URL scheme: ruban://focus-right, ruban://cycle-width …

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: s) else { return }
        let name = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        switch name {
        case "settings": showSettings()
        case "start": if !wm.running { toggleRunning() }
        case "stop": if wm.running { toggleRunning() }
        default:
            if let action = Action(rawValue: name) {
                wm.perform(action)
            } else {
                Log.write("url: no action named \"\(name)\" (\(s))")
            }
        }
        refreshStatus()
    }
}
