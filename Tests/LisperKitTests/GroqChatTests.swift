import Foundation
import Testing
@testable import LisperKit

@Suite struct GroqChatTests {
    private func messages(_ p: [String: Any]) -> [[String: String]] {
        p["messages"] as? [[String: String]] ?? []
    }

    /// gpt-oss is a reasoning model: without a low effort it spends seconds thinking about a
    /// one-line cleanup, and its reasoning must stay out of the response we paste.
    @Test func reasoningModelGetsLowEffortAndNoReasoningText() {
        let p = GroqClient.chatPayload(system: "S", user: "U", model: "openai/gpt-oss-120b",
                                       maxTokens: 4096, temperature: 0.2)
        #expect(p["reasoning_effort"] as? String == "low")
        #expect(p["include_reasoning"] as? Bool == false)
        #expect(p["max_completion_tokens"] as? Int == 4096)
        #expect(messages(p).map { $0["role"] } == ["system", "user"])
    }

    /// Groq rejects reasoning parameters on non-reasoning models — never send them there.
    @Test func nonReasoningModelGetsNoReasoningParams() {
        let p = GroqClient.chatPayload(system: "S", user: "U", model: "some/other-model",
                                       maxTokens: 4096, temperature: 0.2)
        #expect(p["reasoning_effort"] == nil)
        #expect(p["include_reasoning"] == nil)
        #expect(p["model"] as? String == "some/other-model")
    }

    @Test func parsesContentAndIgnoresReasoningField() throws {
        let json = #"{"choices":[{"message":{"role":"assistant","content":"  Hello there.  ","reasoning":"thinking..."},"finish_reason":"stop"}]}"#
        #expect(try GroqClient.parseChat(Data(json.utf8), status: 200) == "Hello there.")
    }

    /// Output cut off by the token limit is a truncated transcript — pasting it silently drops
    /// the end of what the user said. Throw so the pipeline falls back to the full rule cleanup.
    @Test func truncatedCompletionThrows() {
        let json = #"{"choices":[{"message":{"content":"I was saying that we"},"finish_reason":"length"}]}"#
        #expect(throws: EngineError.self) { try GroqClient.parseChat(Data(json.utf8), status: 200) }
    }

    @Test func malformedResponseThrows() {
        #expect(throws: EngineError.self) { try GroqClient.parseChat(Data("nope".utf8), status: 200) }
    }
}
