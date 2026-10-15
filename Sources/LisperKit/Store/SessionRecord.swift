import Foundation
import GRDB

public struct SessionRecord: Codable, Equatable, Identifiable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "sessions"

    public var id: Int64?
    public var startedAt: Date
    public var durationSeconds: Double
    public var appBundleID: String
    public var appName: String
    public var rawTranscript: String
    public var cleanedText: String
    public var wordCount: Int
    public var fillerCount: Int
    public var fillersJSON: [String: Int]
    public var wpm: Double
    public var engineUsed: String      // "groq" | "apple"
    public var cleanupUsed: String     // "llm" | "rules" | "none"
    public var inserted: Bool

    public init(id: Int64?, startedAt: Date, durationSeconds: Double, appBundleID: String,
                appName: String, rawTranscript: String, cleanedText: String, wordCount: Int,
                fillerCount: Int, fillersJSON: [String: Int], wpm: Double,
                engineUsed: String, cleanupUsed: String, inserted: Bool) {
        self.id = id; self.startedAt = startedAt; self.durationSeconds = durationSeconds
        self.appBundleID = appBundleID; self.appName = appName
        self.rawTranscript = rawTranscript; self.cleanedText = cleanedText
        self.wordCount = wordCount; self.fillerCount = fillerCount
        self.fillersJSON = fillersJSON; self.wpm = wpm
        self.engineUsed = engineUsed; self.cleanupUsed = cleanupUsed; self.inserted = inserted
    }

    // Store fillersJSON as a JSON string column
    public func encode(to container: inout PersistenceContainer) {
        container["id"] = id
        container["startedAt"] = startedAt
        container["durationSeconds"] = durationSeconds
        container["appBundleID"] = appBundleID
        container["appName"] = appName
        container["rawTranscript"] = rawTranscript
        container["cleanedText"] = cleanedText
        container["wordCount"] = wordCount
        container["fillerCount"] = fillerCount
        container["fillersJSON"] = (try? JSONEncoder().encode(fillersJSON)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        container["wpm"] = wpm
        container["engineUsed"] = engineUsed
        container["cleanupUsed"] = cleanupUsed
        container["inserted"] = inserted
    }

    public init(row: Row) {
        id = row["id"]; startedAt = row["startedAt"]; durationSeconds = row["durationSeconds"]
        appBundleID = row["appBundleID"]; appName = row["appName"]
        rawTranscript = row["rawTranscript"]; cleanedText = row["cleanedText"]
        wordCount = row["wordCount"]; fillerCount = row["fillerCount"]
        let json: String = row["fillersJSON"] ?? "{}"
        fillersJSON = (try? JSONDecoder().decode([String: Int].self, from: Data(json.utf8))) ?? [:]
        wpm = row["wpm"]; engineUsed = row["engineUsed"]; cleanupUsed = row["cleanupUsed"]
        inserted = row["inserted"]
    }

    public mutating func didInsert(_ success: InsertionSuccess) { id = success.rowID }
}
