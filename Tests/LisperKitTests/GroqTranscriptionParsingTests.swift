import Testing
@testable import LisperKit

struct GroqTranscriptionParsingTests {
    @Test func parsesVerboseJsonSegmentsAndFiltersLoop() throws {
        let json = Data("""
        {
          "task": "transcribe", "language": "english", "duration": 4.2,
          "text": "Hello there. Crap lid mace crap lid mace.",
          "segments": [
            {"id":0,"start":0.0,"end":2.0,"text":" Hello there.","avg_logprob":-0.25,"compression_ratio":1.3,"no_speech_prob":0.01},
            {"id":1,"start":2.0,"end":4.0,"text":" Crap lid mace crap lid mace.","avg_logprob":-1.6,"compression_ratio":3.1,"no_speech_prob":0.8}
          ]
        }
        """.utf8)
        let r = try #require(GroqClient.parseTranscription(json))
        #expect(r.segments.count == 2)
        #expect(r.segments[0].avgLogprob == -0.25)
        #expect(r.segments[1].compressionRatio == 3.1)
        #expect(r.segments[1].noSpeechProb == 0.8)
        #expect(r.segments[1].start == 2.0)
        // End-to-end: the noisy/loopy second segment is dropped, the good first kept.
        #expect(SegmentConfidenceFilter.filter(r.segments) == "Hello there.")
    }

    @Test func missingSegmentSignalsDefaultToKeep() throws {
        // A segment lacking the quality fields must NOT be dropped (defaults = keep).
        let json = Data(#"{"text":"just words","segments":[{"text":" just words"}]}"#.utf8)
        let r = try #require(GroqClient.parseTranscription(json))
        #expect(r.segments.count == 1)
        #expect(!SegmentConfidenceFilter.isHallucinated(r.segments[0]))
        #expect(SegmentConfidenceFilter.filter(r.segments) == "just words")
    }

    @Test func noSegmentsArrayFallsBackToText() throws {
        let r = try #require(GroqClient.parseTranscription(Data(#"{"text":"plain text only"}"#.utf8)))
        #expect(r.segments.isEmpty)
        #expect(r.text == "plain text only")
    }

    @Test func garbageReturnsNil() {
        #expect(GroqClient.parseTranscription(Data("not json".utf8)) == nil)
    }

    // Safety: if the segment shape is unexpected (here, segments missing the required
    // `text`), we must still recover the top-level transcript rather than fail the request.
    @Test func malformedSegmentsStillReturnsFullText() throws {
        let json = Data(#"{"text":"the whole thing","segments":[{"start":0.0,"end":1.0}]}"#.utf8)
        let r = try #require(GroqClient.parseTranscription(json))
        #expect(r.text == "the whole thing")
        #expect(r.segments.isEmpty)   // unparseable segments → no filtering, text preserved
    }
}
