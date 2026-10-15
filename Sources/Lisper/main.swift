import AppKit

// Audition mode: render the candidate UI cues as WAVs and exit (no app launch).
if let i = CommandLine.arguments.firstIndex(of: "--render-sounds") {
    let dir = CommandLine.arguments.count > i + 1
        ? CommandLine.arguments[i + 1] : "/tmp/lisper-sounds"
    try! UISounds.renderAuditionWAVs(to: URL(fileURLWithPath: dir))
    print("Rendered candidate cues to \(dir)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // Dock icon + ⌘Tab; menu-bar item stays
let delegate = AppDelegate()
app.delegate = delegate
app.run()
