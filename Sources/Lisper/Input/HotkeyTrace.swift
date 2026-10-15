// Sources/Lisper/Input/HotkeyTrace.swift
// DIAGNOSTIC INSTRUMENTATION — retained deliberately for the hotkey verification pass; remove
// (or put behind a debug gate) once that pass is signed off.
// Writes a monotonic-timestamped trace of the Fn→Space-lock→Fn-stop gesture path to a file,
// because the unified log is unreliable here (Buddhist calendar; NSLog stored <private>).
// The file is TRUNCATED once per app launch, so it only ever holds the current run — an
// append-forever log grows unbounded and mixes runs, which is exactly what made the last
// trace hard to read.
// Read with:  cat /tmp/lisper-hotkey.log
import Foundation

enum HotkeyTrace {
    static let path = "/tmp/lisper-hotkey.log"
    private static let queue = DispatchQueue(label: "lisper.hotkeytrace")
    /// Guarded by `queue` — the first write of the process starts a fresh file.
    private static var didTruncate = false

    static func log(_ message: String) {
        let line = String(format: "%.3f %@\n", ProcessInfo.processInfo.systemUptime, message)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if !didTruncate {
                didTruncate = true
                try? Data().write(to: URL(fileURLWithPath: path))
            }
            if let h = FileHandle(forWritingAtPath: path) {
                h.seekToEndOfFile(); h.write(data); try? h.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}
