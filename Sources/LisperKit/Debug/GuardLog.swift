import Foundation

/// Thread-safe, per-dictation collector of guard-event names (e.g. "silence",
/// "hallucination", "retry", "vocabEcho"). Shared between the pipeline and the
/// engine for one dictation, then read once to build the debug record.
public final class GuardLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    public init() {}

    public func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        if !events.contains(name) { events.append(name) }
    }

    public func all() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}
