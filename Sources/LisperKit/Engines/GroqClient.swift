import Foundation

/// Minimal OpenAI-compatible client (Groq default) for transcription + chat.
public struct GroqClient: Sendable {
    public let baseURL: String
    public let apiKey: String
    /// Idle (inter-byte) timeout, not a total-request budget — URLRequest.timeoutInterval
    /// semantics. Spec §9 nominally says 8s; 10s chosen for headroom on slower links.
    public var timeout: TimeInterval = 10

    public init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL; self.apiKey = apiKey
    }

    public func transcribe(wav: Data, model: String, prompt: String?,
                           language: String? = nil, temperature: Double = 0) async throws -> WhisperResult {
        guard let url = URL(string: "\(baseURL)/audio/transcriptions") else {
            throw EngineError.network("bad base URL")
        }
        let boundary = "lisper-\(UUID().uuidString)"
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8)
        }
        field("model", model)
        // verbose_json returns per-segment quality signals (avg_logprob, no_speech_prob,
        // compression_ratio) so we can drop hallucinated segments at the source.
        field("response_format", "verbose_json")
        field("temperature", String(temperature))
        // Pinning the language keeps Whisper from drifting off its lock on noisy
        // audio (the coffee-shop hallucination). Empty == let Whisper auto-detect.
        if let language, !language.isEmpty { field("language", language) }
        if let prompt, !prompt.isEmpty { field("prompt", prompt) }
        body.append(contentsOf: "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(wav)
        body.append(contentsOf: "\r\n--\(boundary)--\r\n".utf8)
        req.httpBody = body

        let (data, resp) = try await send(req)
        guard let result = Self.parseTranscription(data) else {
            throw EngineError.badResponse(resp, String(data: data, encoding: .utf8) ?? "")
        }
        return result
    }

    /// Parse a Groq/OpenAI `verbose_json` transcription. Missing per-segment signals
    /// default to "keep" values (confident, non-silent, low compression) so absent data
    /// never causes a segment to be dropped. Extracted for unit testing.
    static func parseTranscription(_ data: Data) -> WhisperResult? {
        // Decode the top-level text first and segments SEPARATELY: if the segment shape
        // ever differs from expectation, we still return the full transcript (no filtering)
        // instead of failing the whole request and forcing a fallback. The only hard failure
        // is a missing/malformed top-level `text`.
        struct TextOnly: Decodable { let text: String }
        guard let base = try? JSONDecoder().decode(TextOnly.self, from: data) else { return nil }

        struct SegsWrap: Decodable {
            struct Seg: Decodable {
                let text: String
                let avg_logprob: Double?
                let compression_ratio: Double?
                let no_speech_prob: Double?
                let start: Double?
            }
            let segments: [Seg]?
        }
        let segs = (try? JSONDecoder().decode(SegsWrap.self, from: data))?.segments ?? []
        let mapped = segs.map {
            WhisperSegment(text: $0.text,
                           avgLogprob: $0.avg_logprob ?? 0,
                           noSpeechProb: $0.no_speech_prob ?? 0,
                           compressionRatio: $0.compression_ratio ?? 0,
                           start: $0.start)
        }
        return WhisperResult(text: base.text, segments: mapped)
    }

    public func chat(system: String, user: String, model: String, maxTokens: Int = 4096,
                     temperature: Double = 0.2) async throws -> String {
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw EngineError.network("bad base URL")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: Self.chatPayload(
            system: system, user: user, model: model, maxTokens: maxTokens, temperature: temperature))
        let (data, status) = try await send(req)
        return try Self.parseChat(data, status: status)
    }

    /// gpt-oss models reason before answering. A cleanup needs almost none, so ask for the
    /// lowest effort (latency), and keep the reasoning text out of the response entirely.
    /// Groq rejects these parameters on non-reasoning models, so they are sent only here.
    static func chatPayload(system: String, user: String, model: String, maxTokens: Int,
                            temperature: Double) -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "temperature": temperature,
            "max_completion_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        if model.hasPrefix("openai/gpt-oss") {
            payload["reasoning_effort"] = "low"
            payload["include_reasoning"] = false
        }
        return payload
    }

    /// The first choice's content, trimmed. A completion cut off by the token limit
    /// (`finish_reason: "length"`) is a truncated transcript and throws — pasting it would
    /// silently drop the end of what the user said. Extracted for unit testing.
    static func parseChat(_ data: Data, status: Int) throws -> String {
        struct R: Decodable {
            struct Choice: Decodable {
                struct Msg: Decodable { let content: String? }
                let message: Msg
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard let choice = (try? JSONDecoder().decode(R.self, from: data))?.choices.first,
              let content = choice.message.content else {
            throw EngineError.badResponse(status, String(data: data, encoding: .utf8) ?? "")
        }
        if choice.finish_reason == "length" {
            throw EngineError.badResponse(status, "completion truncated (finish_reason=length)")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Idle timeout 10s (inter-byte), hard total budget 120s — long enough for a
    /// 5-minute WAV upload on a slow uplink, finite so `processing` always clears.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    private func send(_ req: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await Self.session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw EngineError.badResponse(status, String(data: data, encoding: .utf8) ?? "")
            }
            return (data, status)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled { throw CancellationError() }
        catch let e as EngineError { throw e }
        catch { throw EngineError.network(error.localizedDescription) }
    }
}
