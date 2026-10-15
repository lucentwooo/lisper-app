import Testing
@testable import LisperKit

@Suite struct AudioRetentionTests {
    @Test func testExpiredOlderThanTTL() {
        let now = Date(timeIntervalSince1970: 10 * 86_400) // day 10
        let files: [(name: String, modified: Date)] = [
            ("1.wav", Date(timeIntervalSince1970: 2 * 86_400)),  // 8 days old -> expired
            ("2.wav", Date(timeIntervalSince1970: 5 * 86_400)),  // 5 days old -> keep
            ("3.wav", Date(timeIntervalSince1970: 9.5 * 86_400)),// ~12h old  -> keep
        ]
        let expired = AudioRetention.expired(files: files, now: now, ttlDays: 7)
        #expect(expired == ["1.wav"])
    }
}
