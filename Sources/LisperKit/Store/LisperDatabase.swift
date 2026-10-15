import Foundation
import GRDB

public struct LifetimeStats: Equatable, Sendable {
    public let totalWords: Int
    public let sessionCount: Int
    public let avgWPM: Double
    public let dayStreak: Int
}

public struct DailyAggregate: Equatable {
    public let day: Date               // start of day
    public let sessionCount: Int
    public let totalWords: Int
    public let totalFillers: Int
    public let avgWPM: Double
    public var fillersPer100Words: Double {
        totalWords == 0 ? 0 : Double(totalFillers) / Double(totalWords) * 100
    }
}

public final class LisperDatabase: @unchecked Sendable {
    let queue: DatabaseQueue

    /// Production DB at ~/Library/Application Support/Lisper/lisper.sqlite
    public static func standard() throws -> LisperDatabase {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lisper", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabaseQueue(path: dir.appendingPathComponent("lisper.sqlite").path)
        return try LisperDatabase(queue: queue)
    }

    public init(queue: DatabaseQueue) throws {
        self.queue = queue
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "sessions") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("startedAt", .datetime).notNull().indexed()
                t.column("durationSeconds", .double).notNull()
                t.column("appBundleID", .text).notNull()
                t.column("appName", .text).notNull()
                t.column("rawTranscript", .text).notNull()
                t.column("cleanedText", .text).notNull()
                t.column("wordCount", .integer).notNull()
                t.column("fillerCount", .integer).notNull()
                t.column("fillersJSON", .text).notNull().defaults(to: "{}")
                t.column("wpm", .double).notNull()
                t.column("engineUsed", .text).notNull()
                t.column("cleanupUsed", .text).notNull()
                t.column("inserted", .boolean).notNull()
            }
            try db.create(table: "weekly_tips") { t in
                t.primaryKey("weekStart", .text)
                t.column("tipMarkdown", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2") { db in
            try db.create(table: "session_analyses") { t in
                t.primaryKey("sessionId", .integer)
                t.column("coherenceJSON", .text).notNull()
                t.column("flowOverall", .integer).notNull()
                t.column("flowJSON", .text).notNull()
                t.column("modelUsed", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
            }
            try db.create(table: "daily_insights") { t in
                t.primaryKey("day", .text)
                t.column("digestMarkdown", .text).notNull()
                t.column("metricsJSON", .text).notNull()
                t.column("generatedAt", .datetime).notNull()
                t.column("modelUsed", .text).notNull()
            }
        }
        try migrator.migrate(queue)
    }

    public func save(session: SessionRecord) throws -> SessionRecord {
        var s = session
        try queue.write { db in
            if s.id == nil { try s.insert(db) } else { try s.update(db) }
        }
        return s
    }

    public func recentSessions(limit: Int) throws -> [SessionRecord] {
        try queue.read {
            try SessionRecord.order(Column("startedAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func searchSessions(query: String, limit: Int = 200) throws -> [SessionRecord] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try queue.read {
            try SessionRecord
                .filter(Column("cleanedText").like("%\(escaped)%", escape: "\\")
                     || Column("rawTranscript").like("%\(escaped)%", escape: "\\"))
                .order(Column("startedAt").desc).limit(limit).fetchAll($0)
        }
    }

    public func sessions(since: Date) throws -> [SessionRecord] {
        try queue.read {
            try SessionRecord.filter(Column("startedAt") >= since)
                .order(Column("startedAt").asc).fetchAll($0)
        }
    }

    @discardableResult
    public func deleteSession(id: Int64) throws -> Bool {
        try queue.write { try SessionRecord.deleteOne($0, key: id) }
    }

    public func prune(retention: RetentionPolicy) throws {
        guard let days = retention.days else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date().addingTimeInterval(Double(-days) * 86400)
        _ = try queue.write { try SessionRecord.filter(Column("startedAt") < cutoff).deleteAll($0) }
    }

    public func dailyAggregates(daysBack: Int) throws -> [DailyAggregate] {
        let since = Calendar.current.startOfDay(
            for: Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date())
        let sessions = try self.sessions(since: since)
        let grouped = Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted().map { day in
            let group = grouped[day]!
            let words = group.reduce(0) { $0 + $1.wordCount }
            let fillers = group.reduce(0) { $0 + $1.fillerCount }
            let totalMinutes = group.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
            let avgWPM = totalMinutes > 0 ? Double(words) / totalMinutes : 0
            return DailyAggregate(day: day, sessionCount: group.count, totalWords: words,
                                  totalFillers: fillers, avgWPM: avgWPM)
        }
    }

    /// All-time totals for the Home stats rail, plus the consecutive-day streak
    /// (counting back from today; a streak survives if today has no session yet).
    public func lifetimeStats(calendar: Calendar = .current, now: Date = Date()) throws -> LifetimeStats {
        let sessions = try queue.read { try SessionRecord.fetchAll($0) }
        guard !sessions.isEmpty else { return LifetimeStats(totalWords: 0, sessionCount: 0, avgWPM: 0, dayStreak: 0) }
        let words = sessions.reduce(0) { $0 + $1.wordCount }
        let minutes = sessions.reduce(0.0) { $0 + $1.durationSeconds } / 60.0
        let days = Set(sessions.map { calendar.startOfDay(for: $0.startedAt) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor) ?? cursor
        }
        var streak = 0
        while days.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return LifetimeStats(totalWords: words, sessionCount: sessions.count,
                             avgWPM: minutes > 0 ? Double(words) / minutes : 0,
                             dayStreak: streak)
    }

}
