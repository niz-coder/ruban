import AppKit
import RubanCore
import ServiceManagement
import SwiftUI

/// Live app state the settings window reflects.
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var running = false
    @Published var trusted = AX.isTrusted()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Why opening at login did not take, when macOS refused it or waits for the user's approval.
    @Published var loginProblem: String?

    func refresh() {
        running = WindowManager.shared.running
        trusted = AX.isTrusted()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if SMAppService.mainApp.status == .requiresApproval { loginProblem = Self.awaitingApproval }
    }

    private static let awaitingApproval = "macOS attend ton accord pour ouvrir Ruban au démarrage."

    func setLaunchAtLogin(_ on: Bool) {
        loginProblem = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("launch at login: \(error)")
            loginProblem = "macOS a refusé : \(error.localizedDescription)"
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if on, status == .requiresApproval { loginProblem = Self.awaitingApproval }
    }
}

/// Which settings tab shows. It outlives the window, so the settings open where you left them.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab = 0
}

struct SettingsView: View {
    @ObservedObject var nav = SettingsNavigation.shared

    init(tab: Int? = nil) {
        if let tab { SettingsNavigation.shared.tab = tab }
    }

    var body: some View {
        TabView(selection: $nav.tab) {
            GeneralTab().tabItem { Label("Général", systemImage: "gearshape") }.tag(0)
            LayoutTab().tabItem { Label("Disposition", systemImage: "rectangle.split.3x1") }.tag(1)
            ShortcutsTab().tabItem { Label("Raccourcis", systemImage: "keyboard") }.tag(2)
            RulesTab().tabItem { Label("Apps", systemImage: "macwindow.on.rectangle") }.tag(3)
            SetupTab().tabItem { Label("Mac Setup", systemImage: "checkmark.shield") }.tag(4)
        }
        .frame(width: 620, height: 600)
    }
}

// MARK: - Général

private struct GeneralTab: View {
    @ObservedObject var state = AppState.shared
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Ruban").font(.title2.bold())
                        Text("Toutes tes fenêtres côte à côte sur une bande sans fin. Rien ne se chevauche, rien ne rétrécit : tu fais défiler.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("État") {
                PermissionRow(trusted: state.trusted)
                Toggle("Ruban actif", isOn: runningBinding)
                    .disabled(!state.trusted)
                Toggle("Ouvrir au démarrage du Mac", isOn: loginBinding)
                if let problem = state.loginProblem {
                    Problem(text: problem) {
                        Button("Ouvrir les réglages") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Restaurer l'ordre des colonnes au lancement", isOn: $s.restoreSession)
            }

            Section("Les cinq raccourcis à connaître") {
                Essential(keys: "\(s.modifiers.symbol) ← →", text: "Passer d'une fenêtre à l'autre (ou H / L)")
                Essential(keys: "\(s.modifiers.symbol)⇧ ← →", text: "Déplacer la fenêtre sur la bande")
                Essential(keys: "\(s.modifiers.symbol) R", text: "Changer de largeur (33 · 50 · 66 %)")
                Essential(keys: "\(s.modifiers.symbol) F", text: "Pleine largeur, et retour")
                Essential(keys: s.swipeFingers > 0 ? "Glisser à \(s.swipeFingers) doigts" : "\(s.modifiers.symbol) + défilement",
                          text: "Faire défiler la bande au trackpad")
            }
        }
        .formStyle(.grouped)
        .onAppear { state.refresh() }
    }

    private var runningBinding: Binding<Bool> {
        Binding(get: { state.running }, set: { on in
            if on != WindowManager.shared.running { WindowManager.shared.toggle() }
            state.refresh()
        })
    }

    private var loginBinding: Binding<Bool> {
        Binding(get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) })
    }
}

private struct PermissionRow: View {
    let trusted: Bool
    var body: some View {
        if trusted {
            Label("Accessibilité autorisée", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            HStack {
                Label("Ruban a besoin de l'autorisation Accessibilité pour déplacer les fenêtres.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Ouvrir les réglages") { AX.openAccessibilitySettings() }
            }
        }
    }
}

/// Something that did not work, said where it happened: the icon carries the colour, the text
/// stays readable, and the way out sits beside it.
private struct Problem<Action: View>: View {
    let text: String
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Label {
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Spacer()
            action()
        }
    }
}

extension Problem where Action == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

private struct Essential: View {
    let keys: String
    let text: String
    var body: some View {
        HStack {
            Text(keys).font(.system(.body, design: .rounded).monospaced()).frame(width: 190, alignment: .leading)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Disposition

private struct LayoutTab: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section("Espacement") {
                HStack {
                    Slider(value: $s.gap, in: 0...32, step: 1) { Text("Écart entre les fenêtres") }
                    Text("\(Int(s.gap)) px").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                Text("S'applique aussi aux bords de l'écran. Les fenêtres se placent au-dessus du Dock, jamais dessous.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Largeurs") {
                Picker("Largeur d'une nouvelle fenêtre", selection: $s.defaultWidth) {
                    Text("1/3").tag(1.0 / 3)
                    Text("1/2").tag(0.5)
                    Text("2/3").tag(2.0 / 3)
                    Text("Pleine").tag(1.0)
                }
                TextField("Largeurs prédéfinies (%)", text: $s.presetsText)
                let ignored = s.ignoredPresets
                if !ignored.isEmpty {
                    Problem(text: "Ignoré : \(ignored.map { "« \($0) »" }.joined(separator: ", ")). Chaque largeur est un pourcentage entre 10 et 100."
                        + (s.usesDefaultPresets ? " En attendant, \(s.modifiers.symbol) R parcourt 33, 50 et 66 %." : ""))
                }
                Text("Ce que parcourt \(s.modifiers.symbol) R, par exemple « 25, 33, 50, 66, 75 ».")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Centrer la colonne active", selection: $s.centreMode) {
                    Text("Jamais").tag(CentreMode.never)
                    Text("Si la bande déborde").tag(CentreMode.onOverflow)
                    Text("Toujours").tag(CentreMode.always)
                }
            }
            Section("Animation et repères") {
                Toggle("Animer les déplacements", isOn: $s.animate)
                if s.animate {
                    HStack {
                        Slider(value: $s.animationDuration, in: 0.08...0.5) { Text("Durée") }
                        Text("\(Int(s.animationDuration * 1000)) ms").monospacedDigit().frame(width: 56, alignment: .trailing)
                    }
                }
                Toggle("Afficher l'indicateur de bande", isOn: $s.showIndicator)
                Toggle("Bordure autour de la fenêtre active", isOn: $s.focusBorder)
                if s.focusBorder {
                    HStack {
                        Slider(value: $s.borderWidth, in: 1...8, step: 1) { Text("Épaisseur") }
                        Text("\(Int(s.borderWidth)) px").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Raccourcis

private struct ShortcutsTab: View {
    @ObservedObject var s = Settings.shared
    @State private var rows: [(Action, String)] = Hotkeys.shared.registered
    @State private var unavailable = Hotkeys.shared.unavailable

    var body: some View {
        Form {
            Section {
                Picker("Touches de base", selection: $s.modifiers) {
                    ForEach(ModifierPreset.allCases) { p in Text(p.symbol).tag(p) }
                }
                .onChange(of: s.modifiers) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { reload() }
                }
            } footer: {
                Text("⌥ seul reste à macOS (saut de mot, caractères comme ç ou ®). Les lettres suivent ta disposition de clavier : sur AZERTY, ⌃⌥Q est bien la touche Q.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Faire glisser la bande avec", selection: $s.swipeFingers) {
                    Text("3 doigts").tag(3)
                    Text("4 doigts").tag(4)
                    Text("Désactivé").tag(0)
                }
                if let conflict = MacSetup.swipeConflict(fingers: s.swipeFingers) {
                    Label(conflict + " En attendant, Ruban laisse ce geste à macOS.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Ouvrir les réglages du trackpad") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Trackpad-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                Toggle("\(s.modifiers.symbol) + défilement à deux doigts aussi", isOn: $s.scrollWithModifiers)
                Toggle("Inverser le sens", isOn: $s.invertScroll)
            } header: {
                Text("Trackpad")
            } footer: {
                Text("La bande suit tes doigts, puis se cale sur la colonne la plus proche. Un geste rapide file jusqu'à la colonne suivante.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !unavailable.isEmpty {
                Section("Raccourcis indisponibles") {
                    ForEach(Array(unavailable.enumerated()), id: \.offset) { _, u in
                        HStack(alignment: .firstTextBaseline) {
                            Problem(text: "\(u.action.label) — \(u.reason)")
                            Text(u.keys).font(.system(.body, design: .rounded).monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Tous les raccourcis") {
                ForEach(Array(grouped.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0)
                        Spacer()
                        Text(row.1).font(.system(.body, design: .rounded).monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { reload() }
    }

    private func reload() {
        rows = Hotkeys.shared.registered
        unavailable = Hotkeys.shared.unavailable
    }

    /// One line per action, all its key combinations side by side.
    private var grouped: [(String, String)] {
        var order: [Action] = []
        var keys: [Action: [String]] = [:]
        for (a, k) in rows {
            if keys[a] == nil { order.append(a) }
            keys[a, default: []].append(k)
        }
        let jumps = order.filter { $0.jumpNumber != nil }
        var out = order.filter { $0.jumpNumber == nil }.map { ($0.label, keys[$0]!.joined(separator: "   ")) }
        if let first = jumps.first, let last = jumps.last, let k1 = keys[first]?.first, let k9 = keys[last]?.first {
            out.insert(("Aller à la fenêtre 1 à 9", "\(k1) … \(k9.split(separator: " ").last ?? "")"), at: min(10, out.count))
        }
        return out
    }
}

// MARK: - Apps

private struct RulesTab: View {
    @ObservedObject var s = Settings.shared
    @State private var selection: String?

    var body: some View {
        Form {
            Section {
                ForEach(s.floatApps, id: \.self) { id in
                    HStack {
                        AppIcon(bundleID: id)
                        Text(appName(id))
                        Spacer()
                        Text(id).font(.caption).foregroundStyle(.secondary)
                        Button {
                            s.floatApps.removeAll { $0 == id }
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Ajouter une app…") {
                    ForEach(candidates, id: \.self) { id in
                        Button(appName(id)) { s.floatApps.append(id) }
                    }
                }
            } header: {
                Text("Apps qui flottent")
            } footer: {
                Text("Leurs fenêtres restent libres au-dessus de la bande. Les dialogues, Coup d'œil et les fenêtres de taille fixe (Calculette…) flottent déjà tout seuls. \(Settings.shared.modifiers.symbol) T fait flotter ou re-tuile la fenêtre active.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var candidates: [String] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { !s.floatApps.contains($0) && $0 != Bundle.main.bundleIdentifier }
            .sorted { appName($0).localizedCaseInsensitiveCompare(appName($1)) == .orderedAscending }
    }
}

private func appName(_ bundleID: String) -> String {
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID
}

private struct AppIcon: View {
    let bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
        } else {
            Image(systemName: "app").frame(width: 20, height: 20)
        }
    }
}

// MARK: - Mac Setup

private struct SetupTab: View {
    @State private var checks: [MacSetup.Check] = MacSetup.run()

    var body: some View {
        Form {
            Section {
                ForEach(checks) { c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: c.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(c.ok ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title)
                            if !c.ok { Text(c.advice).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
            } header: {
                Text("Vérification du Mac")
            } footer: {
                Button("Vérifier à nouveau") { checks = MacSetup.run() }
            }
        }
        .formStyle(.grouped)
        .onAppear { checks = MacSetup.run() }
    }
}

enum MacSetup {
    struct Check: Identifiable {
        let id = UUID()
        let title: String
        let ok: Bool
        let advice: String
    }

    static let rivals: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.crowdcafe.windowmagnet": "Magnet",
        "bobko.aerospace": "AeroSpace",
        "com.amethyst.Amethyst": "Amethyst",
        "com.MrKai77.Loop": "Loop",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.manytricks.Moom": "Moom",
        "com.mizage.Divvy": "Divvy",
    ]

    /// Why a sideways swipe with this many fingers would also trigger something in macOS, or nil if it is free.
    static func swipeConflict(fingers: Int) -> String? {
        guard fingers == 3 || fingers == 4 else { return nil }
        let domains = ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
        let key = fingers == 3 ? "TrackpadThreeFingerHorizSwipeGesture" : "TrackpadFourFingerHorizSwipeGesture"
        let used = domains.contains { (UserDefaults(suiteName: $0)?.object(forKey: key) as? Int ?? 0) != 0 }
        let drag = fingers == 3 && domains.contains { UserDefaults(suiteName: $0)?.bool(forKey: "TrackpadThreeFingerDrag") == true }
        if drag {
            return "Le glisser à trois doigts (Accessibilité → Contrôle du pointeur) déplacerait les fenêtres en même temps. Désactive-le, ou choisis 4 doigts pour Ruban."
        }
        guard used else { return nil }
        let other = fingers == 3 ? "quatre" : "trois"
        return "macOS change aussi de bureau avec ce geste. Réglages Système → Trackpad → Plus de gestes → « Balayer entre les apps en plein écran » : choisis « \(other) doigts » ou désactive-le (et vérifie que « Balayer entre les pages » n'utilise pas \(fingers == 3 ? "trois" : "quatre") doigts)."
    }

    static func run() -> [Check] {
        var out: [Check] = []
        out.append(Check(title: "Autorisation Accessibilité", ok: AX.isTrusted(),
                         advice: "Réglages Système → Confidentialité et sécurité → Accessibilité → active Ruban."))
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let clash = running.compactMap { rivals[$0] }.filter { !$0.isEmpty }
        let yabai = NSWorkspace.shared.runningApplications.contains { $0.localizedName == "yabai" }
        let names = clash + (yabai ? ["yabai"] : [])
        out.append(Check(title: names.isEmpty ? "Aucun autre gestionnaire de fenêtres actif" : "Autre gestionnaire actif : \(names.joined(separator: ", "))",
                         ok: names.isEmpty,
                         advice: "Deux gestionnaires se disputent les mêmes fenêtres. Quitte l'autre app pendant que Ruban tourne."))
        let fingers = Settings.shared.swipeFingers
        if fingers > 0 {
            let conflict = swipeConflict(fingers: fingers)
            out.append(Check(title: conflict == nil ? "Glissé à \(fingers) doigts réservé à Ruban" : "macOS utilise aussi le glissé à \(fingers) doigts",
                             ok: conflict == nil, advice: conflict ?? ""))
        }
        let wm = UserDefaults(suiteName: "com.apple.WindowManager")
        let edgeTiling = wm?.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
        out.append(Check(title: "Tuilage de macOS en glissant vers les bords", ok: !edgeTiling,
                         advice: "Réglages Système → Bureau et Dock → Fenêtres : désactive « Faire glisser les fenêtres vers les bords de l'écran pour les juxtaposer », sinon macOS redimensionne quand tu réordonnes à la souris."))
        let stage = wm?.object(forKey: "GloballyEnabled") as? Bool ?? false
        out.append(Check(title: "Stage Manager désactivé", ok: !stage,
                         advice: "Stage Manager range les fenêtres à sa façon. Désactive-le dans le Centre de contrôle."))
        let dock = UserDefaults(suiteName: "com.apple.dock")
        let mru = dock?.object(forKey: "mru-spaces") as? Bool ?? true
        out.append(Check(title: "Ordre des Spaces fixe", ok: !mru,
                         advice: "Bureau et Dock → Mission Control : désactive « Réorganiser automatiquement les Spaces en fonction de votre utilisation la plus récente »."))
        return out
    }
}
