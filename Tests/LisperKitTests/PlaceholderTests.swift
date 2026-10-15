import Testing
@testable import LisperKit

@Suite struct PlaceholderTests {
    @Test func testVersion() { #expect(LisperKitInfo.version == "0.1.0") }
}
