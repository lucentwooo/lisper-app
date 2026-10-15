import Foundation

/// Pure policy: which saved-audio files have aged out. The app side supplies
/// (filename, modified-date) pairs; this returns the names to delete.
public enum AudioRetention {
    public static func expired(files: [(name: String, modified: Date)],
                               now: Date, ttlDays: Int) -> [String] {
        let cutoff = now.addingTimeInterval(-Double(ttlDays) * 86_400)
        return files.filter { $0.modified < cutoff }.map { $0.name }
    }
}
