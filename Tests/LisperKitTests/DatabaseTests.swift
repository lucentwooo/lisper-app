import Testing
import GRDB
@testable import LisperKit

@Suite struct DatabaseTests {
    func makeDB() throws -> LisperDatabase { try LisperDatabase(queue: DatabaseQueue()) }

    func makeSession(daysAgo: Int = 0) -> SessionRecord {
        let stats = TranscriptStats.compute(
            raw: "um hello there um", durationSeconds: 5, customFillers: [])
        return SessionRecord(
            id: nil,
            startedAt: Date().addingTimeInterval(Double(-daysAgo) * 86400),
            durationSeconds: 5,
            appBundleID: "com.apple.TextEdit", appName: "TextEdit",
            rawTranscript: "um hello there um", cleanedText: "Hello there.",
            wordCount: stats.wordCount, fillerCount: stats.fillerCount,
            fillersJSON: stats.fillerCounts, wpm: stats.wordsPerMinute,
            engineUsed: "groq", cleanupUsed: "llm", inserted: true)
    }

    @Test func testSaveAndFetchRecent() throws {
        let db = try makeDB()
        _ = try db.save(session: makeSession())
        let all = try db.recentSessions(limit: 10)
        #expect(all.count == 1)
        #expect(all[0].cleanedText == "Hello there.")
        #expect(all[0].fillersJSON["um"] == 2)
    }

    @Test func testSearch() throws {
        let db = try makeDB()
        _ = try db.save(session: makeSession())
        #expect(try db.searchSessions(query: "hello").count == 1)
        #expect(try db.searchSessions(query: "zebra").count == 0)
        #expect(try db.searchSessions(query: "%").count == 0)  // literal % not in any transcript
    }

    @Test func testPruneRespectsRetention() throws {
        let db = try makeDB()
        _ = try db.save(session: makeSession(daysAgo: 100))
        _ = try db.save(session: makeSession(daysAgo: 1))
        try db.prune(retention: .days90)
        #expect(try db.recentSessions(limit: 10).count == 1)
        try db.prune(retention: .forever)
        #expect(try db.recentSessions(limit: 10).count == 1)
    }

    @Test func testDailyAggregates() throws {
        let db = try makeDB()
        _ = try db.save(session: makeSession(daysAgo: 0))
        _ = try db.save(session: makeSession(daysAgo: 0))
        _ = try db.save(session: makeSession(daysAgo: 3))
        let days = try db.dailyAggregates(daysBack: 7)
        #expect(days.count == 2)
        let today = days.last!
        #expect(today.sessionCount == 2)
        #expect(today.totalWords == 8)
        #expect(today.fillersPer100Words > 0)
    }

    @Test func testSaveReturnsIdAndUpdateWorks() throws {
        let db = try makeDB()
        let saved = try db.save(session: makeSession())
        #expect(saved.id != nil)
        var changed = saved
        changed.cleanedText = "Edited."
        let updated = try db.save(session: changed)
        #expect(updated.id == saved.id)
        let fetched = try db.recentSessions(limit: 5)
        #expect(fetched.count == 1)
        #expect(fetched[0].cleanedText == "Edited.")
    }

    @Test func testLifetimeStatsAndStreak() throws {
        let db = try makeDB()
        for daysAgo in [0, 0, 1, 3] { _ = try db.save(session: makeSession(daysAgo: daysAgo)) }
        let stats = try db.lifetimeStats()
        #expect(stats.totalWords == 16)      // 4 words × 4 sessions
        #expect(stats.sessionCount == 4)
        #expect(abs(stats.avgWPM - 48) < 0.01)  // 16 words over 20s
        #expect(stats.dayStreak == 2)        // today + yesterday, gap at day 2
    }

    @Test func testLifetimeStatsEmpty() throws {
        let db = try makeDB()
        let stats = try db.lifetimeStats()
        #expect(stats.totalWords == 0 && stats.dayStreak == 0 && stats.avgWPM == 0)
    }

}
