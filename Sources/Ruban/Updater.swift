import AppKit
import RubanCore
import Security
import SwiftUI

/// Keeps Ruban up to date from its GitHub releases, with no framework to ship.
///
/// Once a day, or when asked, it reads the latest release of the repository named in Info.plist
/// (`RubanUpdateRepository`). A newer version is offered in a small window and in the menu.
/// Installing downloads the release's zip and checks that the app inside is Ruban, the version
/// announced, and signed exactly like this copy: same certificate, nothing altered. A short script
/// then waits for Ruban to quit, swaps the two apps and opens the new one. Quitting brings every
/// window back first, and the new Ruban puts the strip back the way it was.
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available
        case downloading(Double)
        case installing
        case failed(String)
    }

    /// The parts of a GitHub release the updater reads.
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let body: String?
        let htmlUrl: URL
        let assets: [Asset]

        var version: Version? { Version(tagName) }
    }

    @Published private(set) var phase = Phase.idle
    /// The newer release the last check found.
    @Published private(set) var available: Release?

    let current = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init)
    private let repository = Bundle.main.object(forInfoDictionaryKey: "RubanUpdateRepository") as? String
    /// A copy built from source and run outside its app bundle has nothing to compare or replace.
    var isEnabled: Bool { repository != nil && current != nil }

    private var window: NSWindow?
    private var timer: Timer?
    private var download: URLSessionDownloadTask?
    private var progress: NSKeyValueObservation?
    private static let lastCheckKey = "lastUpdateCheck"

    private var busy: Bool {
        switch phase {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    // MARK: Checking

    /// Checks once a day while the setting is on, the first time half a minute after launch.
    func start() {
        guard isEnabled else { return }
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        timer.tolerance = 600
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard Settings.shared.checkForUpdates, !busy, available == nil else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        check(manual: false)
    }

    /// Asks GitHub for the latest release. A check asked for shows its outcome, whatever it is;
    /// a daily one only speaks up when there is something new.
    func check(manual: Bool) {
        guard let repository, let current, let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            if manual { fail("Cette copie de Ruban ne sait pas où chercher ses mises à jour : elle a été lancée hors de son app.") }
            return
        }
        if busy {
            if manual { showWindow(activate: true) }
            return
        }
        if manual {
            phase = .checking
            showWindow(activate: true)
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Ruban/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = data.flatMap { try? decoder.decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                self.checked(release, status: status, error: error, current: current, manual: manual)
            }
        }.resume()
    }

    private func checked(_ release: Release?, status: Int, error: Error?, current: Version, manual: Bool) {
        guard let release, let version = release.version else {
            let why = error?.localizedDescription
                ?? (status == 404 ? "aucune version n'est encore publiée." : "GitHub a répondu de façon inattendue (\(status)).")
            Log.write("update check failed: \(why)")
            if manual { fail("Impossible de savoir s'il existe une version plus récente : \(why)") } else { phase = .idle }
            return
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        guard version > current else {
            available = nil
            phase = manual ? .upToDate : .idle
            return
        }
        Log.write("update: \(version) is available (this is \(current))")
        available = release
        phase = .available
        // Found on its own: shown, but without taking the keyboard from whatever you are doing.
        showWindow(activate: manual)
    }

    // MARK: Installing

    func install() {
        guard let release = available, let version = release.version, !busy else { return }
        let app = Bundle.main.bundleURL
        let folder = app.deletingLastPathComponent()
        if app.path.contains("/AppTranslocation/") {
            return fail("macOS fait tourner Ruban depuis un emplacement temporaire. Déplace Ruban dans ton dossier Applications, ouvre-le de là, puis réessaie.")
        }
        guard FileManager.default.isWritableFile(atPath: folder.path) else {
            return fail("Ruban ne peut pas se remplacer dans « \(folder.path) ». Mets-le dans un dossier Applications qui t'appartient, puis réessaie.")
        }
        guard let requirement = Self.ownRequirement() else {
            return fail("Cette copie de Ruban n'a pas de signature stable, donc rien ne permet de vérifier une mise à jour. Télécharge la nouvelle version depuis sa page.")
        }
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            return fail("Cette version ne contient pas d'app à installer.")
        }
        phase = .downloading(0)
        let task = URLSession.shared.downloadTask(with: asset.browserDownloadUrl) { file, response, error in
            // The downloaded file is deleted when this returns: everything happens here, off the main thread.
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            do {
                guard let file, error == nil, status == 200 else {
                    if (error as? URLError)?.code == .cancelled { return }
                    throw UpdateError("Le téléchargement a échoué : \(error?.localizedDescription ?? "GitHub a répondu \(status).")")
                }
                let work = try Self.emptyWorkFolder()
                let zip = work.appendingPathComponent(asset.name)
                try FileManager.default.moveItem(at: file, to: zip)
                DispatchQueue.main.async { self.phase = .installing }
                let unpacked = work.appendingPathComponent("unpacked")
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                let new = unpacked.appendingPathComponent(app.lastPathComponent)
                try Self.vet(new, version: version, requirement: requirement)
                DispatchQueue.main.async { self.handOver(to: new, work: work, version: version) }
            } catch {
                DispatchQueue.main.async { self.fail(error.localizedDescription) }
            }
        }
        progress = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
            DispatchQueue.main.async {
                guard let self, case .downloading = self.phase else { return }
                self.phase = .downloading(p.fractionCompleted)
            }
        }
        download = task
        task.resume()
    }

    func cancelDownload() {
        download?.cancel()
        download = nil
        progress = nil
        phase = .available
    }

    /// Starts the script that swaps the two apps once Ruban has quit, then quits.
    private func handOver(to new: URL, work: URL, version: Version) {
        let script = """
            while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
            old="$2.old"
            rm -rf "$old"
            if mv "$2" "$old"; then
              if /usr/bin/ditto "$3" "$2"; then rm -rf "$old"
              else rm -rf "$2"; mv "$old" "$2"; echo "$(date +%T) update: could not copy the new app, kept the old one" >> "$5"
              fi
            fi
            rm -rf "$4"
            /usr/bin/open "$2"
            """
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Ruban.log").path
        guard Spawn.detached(["/bin/sh", "-c", script, "sh", String(getpid()), Bundle.main.bundleURL.path, new.path, work.path, log],
                             newSession: true) != nil else {
            return fail("Ruban n'a pas pu lancer l'installation.")
        }
        Log.write("update: installing \(version), Ruban quits and comes back")
        Log.flush()
        NSApp.terminate(nil)
    }

    private func fail(_ message: String) {
        download = nil
        progress = nil
        phase = .failed(message)
        showWindow(activate: true)
    }

    // MARK: Checks on the downloaded app

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// The app must be Ruban, the version announced, and signed exactly like this copy.
    static func vet(_ app: URL, version: Version, requirement: SecRequirement) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let found = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(Version.init),
              found == version else {
            throw UpdateError("L'archive téléchargée ne contient pas Ruban \(version) : rien n'a été installé.")
        }
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: SecCSFlags.RawValue(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw UpdateError("Cette mise à jour n'est pas signée comme ta copie de Ruban : elle n'a pas été installée.")
        }
    }

    /// What this copy's signature requires of itself, or nil for an ad hoc signature: that one
    /// names this exact build, which no other version can match.
    static func ownRequirement() -> SecRequirement? {
        var me: SecCode?, staticMe: SecStaticCode?, requirement: SecRequirement?, text: CFString?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text,
              !(text as String).hasPrefix("cdhash") else { return nil }
        return requirement
    }

    private static func emptyWorkFolder() throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let work = caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Ruban", isDirectory: true)
            .appendingPathComponent("Update", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return work
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("L'archive téléchargée est illisible : rien n'a été installé.") }
    }

    // MARK: Window

    func showWindow(activate: Bool) {
        let w = window ?? makeWindow()
        if !w.isVisible { w.center() }
        if activate {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
    }

    func closeWindow() {
        window?.close()
        if case .downloading = phase { return }
        if case .installing = phase { return }
        phase = available == nil ? .idle : .available
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: UpdateView(updater: self))
        hosting.sizingOptions = .preferredContentSize
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable]
        w.title = "Mise à jour de Ruban"
        w.isReleasedWhenClosed = false
        window = w
        return w
    }

    /// For `--snapshot`: shows a state without asking GitHub anything.
    func preview(_ phase: Phase, release: Release?) {
        self.phase = phase
        available = release
    }
}

/// The update window: what is new, and one clear thing to do about it.
struct UpdateView: View {
    @ObservedObject var updater: Updater

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                if !subtitle.isEmpty {
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if showsNotes, let notes = updater.available?.body, !notes.isEmpty {
                    let text = Text(Self.render(notes)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                    // Short notes take the room they need; long ones scroll.
                    ViewThatFits(in: .vertical) {
                        text.fixedSize(horizontal: false, vertical: true)
                        ScrollView { text }
                    }
                    .frame(maxHeight: 170)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                }
                switch updater.phase {
                case .downloading(let done):
                    ProgressView(value: done)
                case .checking, .installing:
                    ProgressView().controlSize(.small)
                default:
                    EmptyView()
                }
                HStack {
                    Spacer()
                    buttons
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .frame(width: 500)
    }

    private var version: String { updater.available?.version?.description ?? "" }
    private var current: String { updater.current?.description ?? "?" }

    private var showsNotes: Bool {
        switch updater.phase {
        case .available, .downloading, .installing: true
        default: false
        }
    }

    private var title: String {
        switch updater.phase {
        case .idle: "Ruban \(current)"
        case .checking: "Recherche d'une mise à jour…"
        case .upToDate: "Ruban est à jour"
        case .available: "Ruban \(version) est disponible"
        case .downloading: "Téléchargement de Ruban \(version)…"
        case .installing: "Installation de Ruban \(version)…"
        case .failed: "La mise à jour n'a pas abouti"
        }
    }

    private var subtitle: String {
        switch updater.phase {
        case .upToDate: "Tu as la dernière version, la \(current)."
        case .available: "Tu as la \(current). Ruban se ferme, se met à jour et se rouvre : tes fenêtres reviennent à leur place."
        case .installing: "Vérification de la signature, puis Ruban se relance."
        case .failed(let message): message
        default: ""
        }
    }

    @ViewBuilder private var buttons: some View {
        switch updater.phase {
        case .available:
            Button("Plus tard") { updater.closeWindow() }
                .keyboardShortcut(.cancelAction)
            Button("Installer et relancer") { updater.install() }
                .keyboardShortcut(.defaultAction)
        case .downloading:
            Button("Annuler") { updater.cancelDownload() }
                .keyboardShortcut(.cancelAction)
        case .installing:
            EmptyView()
        case .failed:
            if let page = updater.available?.htmlUrl {
                Button("Ouvrir la page de la version") { NSWorkspace.shared.open(page) }
            }
            Button("Fermer") { updater.closeWindow() }
                .keyboardShortcut(.defaultAction)
        default:
            Button("OK") { updater.closeWindow() }
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Release notes are Markdown: links and emphasis render, lines stay as written.
    static func render(_ notes: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: notes, options: options)) ?? AttributedString(notes)
    }
}
