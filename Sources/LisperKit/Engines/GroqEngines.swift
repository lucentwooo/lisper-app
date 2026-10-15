import Foundation

/// The one Groq call GroqWhisperEngine makes — a seam so its retry and ending-check logic can
/// be tested without the network.
protocol WhisperTranscriber: Sendable {
    func transcribe(wav: Data, model: String, prompt: String?,
                    language: String?, temperature: Double) async throws -> WhisperResult
}

extension GroqClient: WhisperTranscriber {}

public struct GroqWhisperEngine: TranscriptionEngine {
    public let name = "groq"
    let client: any WhisperTranscriber
    let model: String
    /// BCP-47 language hint (e.g. "en"). Empty string lets Whisper auto-detect.
    let language: String
    let guardLog: GuardLog?
    /// Second model that transcribes the same clip to catch an ending `model` dropped (see
    /// EndingRecovery). nil = no check.
    let endingCheckModel: String?
    /// How long the paste may wait for the check once the primary is done. The check runs
    /// alongside the primary on a faster model, so it is normally finished first.
    let endingCheckGraceSeconds: Double
    /// Longer takes skip the check: two uploads of a long WAV share the uplink, and on a slow one
    /// the primary could miss its 120 s request budget. Every recovered ending was in a take < 47 s.
    static let endingCheckMaxSeconds: Double = 60

    public init(client: GroqClient, model: String, language: String = "en", guardLog: GuardLog? = nil,
                endingCheckModel: String? = nil) {
        self.init(transcriber: client, model: model, language: language, guardLog: guardLog,
                  endingCheckModel: endingCheckModel)
    }

    init(transcriber: any WhisperTranscriber, model: String, language: String, guardLog: GuardLog?,
         endingCheckModel: String?, endingCheckGraceSeconds: Double = 1.5) {
        self.client = transcriber; self.model = model; self.language = language; self.guardLog = guardLog
        self.endingCheckModel = endingCheckModel; self.endingCheckGraceSeconds = endingCheckGraceSeconds
    }

    /// Whisper's `prompt` is preceding *context it tries to continue*, not a hidden
    /// instruction — any label here (e.g. "Vocabulary:") leaks verbatim into the
    /// transcript on low-confidence audio. Send only the bare terms as a hint.
    static func vocabularyPrompt(_ terms: [String]) -> String? {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ", ")
    }

    private static func squashed(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// On silent / near-silent audio Whisper has nothing to decode and just
    /// regurgitates its prompt — so the vocabulary list gets pasted verbatim.
    /// True when the transcript is made up entirely of dictionary terms.
    static func isVocabularyEcho(_ transcript: String, terms: [String]) -> Bool {
        let promptTerms = Set(terms.map(squashed).filter { !$0.isEmpty })
        guard !promptTerms.isEmpty else { return false }
        let spoken = transcript.split(separator: ",").map { squashed(String($0)) }.filter { !$0.isEmpty }
        guard !spoken.isEmpty else { return false }
        return spoken.allSatisfy { promptTerms.contains($0) }
    }

    public func transcribe(audio: CapturedAudio, dictionaryTerms: [String]) async throws -> String {
        let wav = WavEncoder.encode(audio)
        let prompt = Self.vocabularyPrompt(dictionaryTerms)
        let lang = language.isEmpty ? nil : language

        // Started first so it runs alongside the primary. No vocabulary prompt: its words are
        // only spliced in after the primary's, and a prompt is what Whisper echoes into silence.
        let checkModel = audio.durationSeconds <= Self.endingCheckMaxSeconds ? endingCheckModel : nil
        let check = checkModel.map { checkModel in
            Task { [client] in
                try? await client.transcribe(wav: wav, model: checkModel, prompt: nil,
                                             language: lang, temperature: 0)
            }
        }
        defer { check?.cancel() }

        let first = try await client.transcribe(wav: wav, model: model, prompt: prompt,
                                                language: lang, temperature: 0)
        var text = confidenceFiltered(first)
        if HallucinationGuard.isLikelyHallucination(text) {
            guardLog?.record("hallucination")
            // Whisper's temperature-fallback trick: a second pass at a higher
            // temperature usually breaks the repetition loop on noisy audio. Drop the
            // vocabulary prompt on the retry — on low-confidence audio Whisper
            // regurgitates its prompt, so re-sending it just feeds the same echo
            // (the "FowlerAds, Lisper, …" burst is the dictionary leaking back out).
            let retry = try await client.transcribe(wav: wav, model: model, prompt: nil,
                                                language: lang, temperature: 0.4)
            text = confidenceFiltered(retry)
            guardLog?.record("retry")
            // Still garbage — throw so the pipeline degrades to Apple's on-device
            // engine rather than pasting hallucinated text at the cursor.
            if HallucinationGuard.isLikelyHallucination(text) {
                throw EngineError.emptyTranscript
            }
        }
        // Don't paste the vocabulary list back when the mic heard nothing.
        if Self.isVocabularyEcho(text, terms: dictionaryTerms) {
            guardLog?.record("vocabEcho")
            throw EngineError.emptyTranscript
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw EngineError.emptyTranscript }
        guard let check else { return trimmed }
        return await withRecoveredEnding(trimmed, check: check, audio: audio)
    }

    /// `text` plus any ending the check model heard after it (EndingRecovery decides).
    private func withRecoveredEnding(_ text: String, check: Task<WhisperResult?, Never>,
                                     audio: CapturedAudio) async -> String {
        let result: WhisperResult
        switch await Self.value(of: check, within: endingCheckGraceSeconds) {
        case .timedOut: guardLog?.record("endingCheckTimedOut"); return text
        case .finished(nil): guardLog?.record("endingCheckFailed"); return text
        case .finished(let value?): result = value
        }
        // Only words that START before the last detected speech count. After it is the trimmer's
        // trailing pad — room tone, where Whisper invents "Thank you." (3137) — and without segment
        // times there is no telling the two apart, so nothing is recovered.
        let speechEnd = audio.speechEndSeconds ?? EnergyVoiceActivityTrimmer().speechEndSeconds(in: audio)
        let segments = result.segments.filter { !SegmentConfidenceFilter.isHallucinated($0) }
        guard let speechEnd, !result.segments.isEmpty, segments.allSatisfy({ $0.start != nil }) else { return text }
        let heard = segments.filter { ($0.start ?? .infinity) < speechEnd }
            .map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !HallucinationGuard.isLikelyHallucination(heard),
              let ending = EndingRecovery.missingEnding(primary: text, checker: heard)
        else { return text }
        guardLog?.record("endingRecovered")
        return text + " " + ending
    }

    enum CheckOutcome { case finished(WhisperResult?), timedOut }

    /// The task's value if it finishes within `seconds`; otherwise cancels it and reports a
    /// timeout. A hard deadline: it never waits on the request itself, so even a request that
    /// ignores cancellation can't hold up the paste.
    private static func value(of task: Task<WhisperResult?, Never>, within seconds: Double) async -> CheckOutcome {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
            let deadline = Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if once.claim() { task.cancel(); continuation.resume(returning: .timedOut) }
            }
            Task {
                let value = await task.value
                if once.claim() { deadline.cancel(); continuation.resume(returning: .finished(value)) }
            }
        }
    }

    /// Drop hallucinated segments using Whisper's own per-segment confidence signals
    /// (the verbose_json response). Falls back to the full text when no segment detail
    /// was returned. This catches silence tails and repetition loops at the source —
    /// before the output-side `HallucinationGuard` heuristics ever run.
    private func confidenceFiltered(_ r: WhisperResult) -> String {
        guard !r.segments.isEmpty else { return r.text }
        let kept = SegmentConfidenceFilter.filter(r.segments)
        if kept != r.text.trimmingCharacters(in: .whitespacesAndNewlines) {
            guardLog?.record("confidenceFiltered")
        }
        return kept
    }
}

/// Lets exactly one of several racing callers resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

public struct LLMCleanupEngine: CleanupEngine {
    public let name = "llm"
    let client: GroqClient
    let model: String

    public init(client: GroqClient, model: String) {
        self.client = client; self.model = model
    }

    public func clean(raw: String, context: CleanupContext) async throws -> String {
        let out = try await client.chat(
            system: CleanupPromptBuilder.systemPrompt(context: context),
            user: CleanupPromptBuilder.userPrompt(raw: raw),
            model: model)
        guard !out.isEmpty else { throw EngineError.emptyTranscript }
        return out
    }
}

public struct RuleCleanupEngine: CleanupEngine {
    public let name = "rules"
    public init() {}
    public func clean(raw: String, context: CleanupContext) async throws -> String {
        RuleBasedCleanup.clean(raw)
    }
}
