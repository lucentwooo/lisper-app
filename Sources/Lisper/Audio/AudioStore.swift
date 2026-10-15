// Sources/Lisper/Audio/AudioStore.swift
import Foundation
import LisperKit

/// Persists per-session audio as WAV under Application Support/Lisper/audio,
/// and purges files older than the retention window. Best-effort: every method
/// swallows errors — audio is a debugging aid, never the dictation contract.
enum AudioStore {
    static let ttlDays = 7

    static func dir() -> URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lisper/audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func url(for sessionId: Int64) -> URL {
        dir().appendingPathComponent("\(sessionId).wav")
    }

    static func save(_ audio: CapturedAudio, sessionId: Int64) {
        let wav = WavEncoder.encode(audio)
        try? wav.write(to: url(for: sessionId))
    }

    static func exists(sessionId: Int64) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sessionId).path)
    }

    static func purgeExpired(now: Date = Date()) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir().path) else { return }
        let files: [(name: String, modified: Date)] = names.compactMap { name in
            let p = dir().appendingPathComponent(name).path
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let mod = attrs[.modificationDate] as? Date else { return nil }
            return (name, mod)
        }
        for name in AudioRetention.expired(files: files, now: now, ttlDays: ttlDays) {
            try? fm.removeItem(at: dir().appendingPathComponent(name))
        }
    }
}
