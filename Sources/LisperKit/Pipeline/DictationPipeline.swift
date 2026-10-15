import Foundation

public enum PipelineError: Error, Equatable {
    case tooShort
    /// Every engine ran and heard no speech — an accidental tap, not a connection problem.
    case noSpeech
    case allEnginesFailed(String)
}

public struct DictationOutcome: Sendable {
    public let rawTranscript: String
    public let cleanedText: String
    public let engineUsed: String
    public let cleanupUsed: String
    public let stats: TranscriptStats
    public let session: SessionRecord
    public let rms: Double
    public let guardsFired: [String]
    /// Set when LLM cleanup failed for a reason the user can fix (see CleanupFailureNotice).
    public let cleanupNotice: String?
}

/// Orchestrates: audio -> STT (with fallback) -> cleanup (with fallback) -> stats -> persist.
public final class DictationPipeline: @unchecked Sendable {
    private let primarySTT: TranscriptionEngine?
    private let fallbackSTT: TranscriptionEngine?
    private let llmCleanup: CleanupEngine?
    private let ruleCleanup: CleanupEngine
    private let database: LisperDatabase
    private let debugLog: DebugLog?
    private let guardLog: GuardLog?
    private let trimmer: VoiceActivityTrimmer?

    public init(primarySTT: TranscriptionEngine?, fallbackSTT: TranscriptionEngine?,
                llmCleanup: CleanupEngine?, ruleCleanup: CleanupEngine, database: LisperDatabase,
                debugLog: DebugLog? = nil, guardLog: GuardLog? = nil,
                trimmer: VoiceActivityTrimmer? = nil) {
        self.primarySTT = primarySTT; self.fallbackSTT = fallbackSTT
        self.llmCleanup = llmCleanup; self.ruleCleanup = ruleCleanup; self.database = database
        self.debugLog = debugLog; self.guardLog = guardLog; self.trimmer = trimmer
    }

    /// `heldSeconds` is how long the key was held when the recorder also captured a short tail
    /// after the stop press (nil = the whole clip). The "too short" gate, the coach stats, rms
    /// and the saved duration use it, so the tail can't rescue an accidental tap or skew WPM.
    public func process(audio: CapturedAudio, context: CleanupContext,
                        customFillers: [String], heldSeconds: Double? = nil) async throws -> DictationOutcome {
        let startedAt = Date()
        let duration = min(heldSeconds ?? audio.durationSeconds, audio.durationSeconds)
        // `rms`/duration always describe the ORIGINAL capture — the coach stats,
        // session record, and debug log must reflect what the user actually said
        // over the full time they held the key, never the trimmed span. VAD
        // trimming changes only which bytes we upload to Whisper (see below); it
        // must NOT alter any reported/persisted number, or short utterances would
        // trim to a sliver and inflate WPM.
        let heldSamples = Int((duration * audio.sampleRate).rounded())
        let rms = Double(AudioGate.rms(Array(audio.samples.prefix(heldSamples))))

        // Helper: write one debug record (best-effort) then return/throw.
        func emit(sessionId: Int64?, engine: String, cleanup: String,
                  raw: String, cleaned: String, error: String?, cleanupError: String? = nil) {
            let rec = DictationDebugRecord(
                timestamp: startedAt, sessionId: sessionId,
                durationSeconds: duration, rms: rms,
                engineUsed: engine, cleanupUsed: cleanup,
                rawTranscript: raw, cleanedText: cleaned,
                guardsFired: guardLog?.all() ?? [],
                latencyMs: Int(Date().timeIntervalSince(startedAt) * 1000),
                error: error, cleanupError: cleanupError)
            try? debugLog?.append(rec)
        }

        guard duration >= 0.4 else {
            emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: "tooShort")
            throw PipelineError.tooShort
        }
        // Silence in == hallucinated text out. Drop it before Whisper sees it. Judged on the held
        // take: speech said only after the stop press doesn't make a silent take worth sending.
        guard !AudioGate.isLikelySilent(CapturedAudio(samples: Array(audio.samples.prefix(heldSamples)),
                                                      sampleRate: audio.sampleRate)) else {
            guardLog?.record("silence")
            emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: "tooShort")
            throw PipelineError.tooShort
        }

        // `workingAudio` is the clip we upload to Whisper — and ONLY that. After
        // VAD trimming it is the speech-bearing span plus at most 1 s after it; the long
        // dead air Whisper would otherwise hallucinate over is gone. It feeds NO metric:
        // duration/rms/stats above and the session below all use the held part of `audio`.
        var workingAudio = audio

        // Proactively trim leading/trailing non-speech so Whisper never sees the long
        // dead air that triggers silence hallucinations (and so we upload less).
        // Runs after the cheap duration/whole-clip-silence gates above.
        if let trimmer {
            // Tell the trimmer where the press was, so the stop key's click isn't speech.
            let trimmed = trimmer.trim(CapturedAudio(samples: workingAudio.samples,
                                                     sampleRate: workingAudio.sampleRate,
                                                     heldSeconds: duration))
            if trimmed.samples.isEmpty {
                // Nothing speech-like survived — treat exactly like gated silence.
                guardLog?.record("trimmedToSilence")
                emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: "tooShort")
                throw PipelineError.tooShort
            }
            if trimmed.samples.count < workingAudio.samples.count {
                guardLog?.record("vadTrimmed")
            }
            workingAudio = trimmed
        }

        // 1) Transcribe with fallback.
        // The vocabulary prompt is Whisper's hallucination fuel — it primes the decoder
        // toward the dictionary tokens and loops on them on any low-confidence frame, even
        // mid-speech (e.g. a "LisperYourAds…" burst when you actually say those product
        // names). When an LLM cleanup is configured it already enforces spelling
        // ("always spell these exactly: …" in CleanupPromptBuilder), so withhold the prompt
        // from Whisper and let the LLM own proper-noun spelling — the same split Wispr Flow
        // uses. Only fall back to priming Whisper when there is no LLM downstream to fix it.
        // (Trade-off: a short utterance takes the rule fast path, so a proper noun spoken in
        // <fastPathMaxWords words may not be re-cased — a rare cosmetic miss vs. losing whole
        // takes to loops.)
        let whisperPromptTerms = llmCleanup == nil ? context.dictionaryTerms : []
        var raw: String? = nil
        var engineUsed = ""
        var lastError = "no engines configured"
        var allHeardNothing = true
        let engines = [primarySTT, fallbackSTT].compactMap { $0 }
        for (idx, engine) in engines.enumerated() {
            do {
                raw = try await engine.transcribe(audio: workingAudio, dictionaryTerms: whisperPromptTerms)
                engineUsed = engine.name
                if idx > 0 { guardLog?.record("sttFallback") }
                break
            } catch {
                lastError = "\(engine.name): \(error)"
                if (error as? EngineError) != .emptyTranscript { allHeardNothing = false }
            }
        }
        guard let transcribed = raw, !transcribed.isEmpty else {
            emit(sessionId: nil, engine: "", cleanup: "", raw: "", cleaned: "", error: lastError)
            if !engines.isEmpty, allHeardNothing { throw PipelineError.noSpeech }
            throw PipelineError.allEnginesFailed(lastError)
        }
        // Two-stage trailing-garbage cleanup. The engine's whole-clip guard only
        // catches loops that DOMINATE the transcript; a hallucination burst tacked
        // onto an otherwise-good long take slips under that bar. First excise a
        // trailing burst — a vocab-prompt echo and/or degenerate loop appended after
        // the real speech (reported session 205: "…futuristic FowlerAds, Lisper,
        // Crap, Lid, Mace, Crap, Lid, Mace…"). This MUST run before the collapse pass,
        // which would otherwise trim the loop to a single copy and erase the
        // repetition signature the burst detector keys on. Then collapse any
        // remaining mid-transcript back-to-back loop to one copy. Both keep the good
        // text rather than pasting spam or discarding a whole transcript.
        let excised = HallucinationGuard.exciseTrailingHallucination(
            transcribed, dictionaryTerms: context.dictionaryTerms)
        if excised != transcribed { guardLog?.record("excisedTrailingHallucination") }
        let rawTranscript = HallucinationGuard.collapseRepetitionLoops(excised)
        if rawTranscript != excised { guardLog?.record("collapsedLoop") }

        // 2) Clean — skip the LLM round-trip for short utterances the rules handle instantly,
        // UNLESS a custom dictionary is set: the LLM is the only stage that applies phonetic
        // spelling corrections (e.g. "Jerry" -> "Jeriq"), so a short take with a dictionary
        // must still get it. Whisper no longer receives the vocab prompt, so this is the only
        // place those corrections can happen.
        var cleaned: String
        var cleanupUsed: String
        var cleanupError: String? = nil
        var cleanupNotice: String? = nil
        let canFastPath = CleanupRouter.shouldUseRuleFastPath(raw: rawTranscript)
            && context.dictionaryTerms.isEmpty
        if let llm = llmCleanup, !canFastPath {
            do {
                cleaned = try await llm.clean(raw: rawTranscript, context: context)
                cleanupUsed = llm.name
            } catch {
                cleaned = try await ruleCleanup.clean(raw: rawTranscript, context: context)
                cleanupUsed = ruleCleanup.name
                guardLog?.record("cleanupFallback")
                cleanupError = String(String(describing: error).prefix(500))
                cleanupNotice = CleanupFailureNotice.message(for: error)
            }
        } else {
            if llmCleanup != nil { guardLog?.record("fastPathCleanup") }  // LLM available but skipped for a short utterance
            cleaned = try await ruleCleanup.clean(raw: rawTranscript, context: context)
            cleanupUsed = ruleCleanup.name
        }

        // 3) Stats on RAW speech (the coach's source of truth). Duration is the
        // ORIGINAL capture, not the trimmed clip, so WPM reflects how long the
        // user actually spoke (a short "yes" that trims to a sliver must not
        // explode to 200+ WPM).
        let stats = TranscriptStats.compute(raw: rawTranscript,
                                            durationSeconds: duration,
                                            customFillers: customFillers)

        // 4) Persist
        let session = SessionRecord(
            id: nil, startedAt: startedAt, durationSeconds: duration,
            appBundleID: context.bundleID, appName: context.appName,
            rawTranscript: rawTranscript, cleanedText: cleaned,
            wordCount: stats.wordCount, fillerCount: stats.fillerCount,
            fillersJSON: stats.fillerCounts, wpm: stats.wordsPerMinute,
            engineUsed: engineUsed, cleanupUsed: cleanupUsed, inserted: true)
        // History is a side-effect; the dictation is the product. A failed write (disk full,
        // DB locked by a second instance) must not throw away a finished transcription.
        let saved: SessionRecord
        do {
            saved = try database.save(session: session)
        } catch {
            guardLog?.record("historyWriteFailed")
            saved = session
        }

        emit(sessionId: saved.id, engine: engineUsed, cleanup: cleanupUsed,
             raw: rawTranscript, cleaned: cleaned, error: nil, cleanupError: cleanupError)

        return DictationOutcome(rawTranscript: rawTranscript, cleanedText: cleaned,
                                engineUsed: engineUsed, cleanupUsed: cleanupUsed,
                                stats: stats, session: saved,
                                rms: rms, guardsFired: guardLog?.all() ?? [],
                                cleanupNotice: cleanupNotice)
    }
}
