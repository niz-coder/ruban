import AppKit

let app = NSApplication.shared

if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
    Snapshot.run(into: CommandLine.arguments[i + 1])
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// Killed from the terminal or by launchd: bring parked windows back on screen before leaving.
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT, SIGHUP] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    source.setEventHandler {
        WindowManager.shared.stop()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

app.run()
