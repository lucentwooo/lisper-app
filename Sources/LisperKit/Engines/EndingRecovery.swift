/// Recovers the end of a take that the primary Whisper model dropped.
///
/// Whisper large-v3 sometimes stops early, usually after a pause: the words are plainly in the
/// clip, but the transcript ends before them ("…so that I can easily" — "visually check them"
/// missing, session 3340) — on Groq, and reproducibly in local whisper.cpp. turbo, transcribing
/// the same clip, heard 7 of the 10 confirmed endings and 13 more dropped last words ("…good
/// luck on your" — "trip"). So a second model transcribes the clip alongside, and whatever it
/// heard AFTER the primary's last words is appended.
///
/// Deliberately conservative — a wrong splice would paste words twice, which is worse than the
/// original miss. It splices only when the primary's last few words occur exactly once in the
/// checker's transcript, and only where the primary's words would end; otherwise it returns nil.
public enum EndingRecovery {
    /// Fewest of the primary's last words that must match (all of them for a shorter take).
    static let minAnchorWords = 3
    /// Longest anchor tried while looking for a unique match.
    static let maxAnchorWords = 8

    /// The checker's words after the end of `primary`, or nil when nothing is missing or there is
    /// no unambiguous place to splice.
    public static func missingEnding(primary: String, checker: String) -> String? {
        let primaryWords = words(primary).map(\.key).filter { !$0.isEmpty }
        let checkerTokens = words(checker)
        // Indices of the checker tokens that are words (not bare punctuation like "...").
        let checkerWordIndices = checkerTokens.indices.filter { !checkerTokens[$0].key.isEmpty }
        let checkerWords = checkerWordIndices.map { checkerTokens[$0].key }
        guard !primaryWords.isEmpty, !checkerWords.isEmpty else { return nil }

        let shortest = min(minAnchorWords, primaryWords.count)
        let longest = min(maxAnchorWords, primaryWords.count)
        for length in shortest...longest {
            let anchor = Array(primaryWords.suffix(length))
            let matches = (0..<max(0, checkerWords.count - length + 1)).filter {
                Array(checkerWords[$0..<$0 + length]) == anchor
            }
            if matches.isEmpty { return nil }      // the endings disagree: no safe splice
            guard matches.count == 1, let start = matches.first else { continue }
            // The primary says this phrase twice: the match may be its first copy ("we test it
            // we test it"), and splicing there would paste everything between them again.
            guard occurrences(of: anchor, in: primaryWords) == 1 else { return nil }

            // Both models heard the same audio, so the anchor must end where the primary's words
            // do, give or take a few words of wording difference (28 real recoveries: -1 to +3).
            // Anywhere else it is a coincidental repeat of an earlier phrase. Landing EARLY is the
            // dangerous direction — everything after it would be pasted again — so it gets 1 word.
            let offset = start + length - primaryWords.count
            guard offset >= -1, offset <= max(4, primaryWords.count * 5 / 100) else { return nil }

            let lastAnchorToken = checkerWordIndices[start + length - 1]
            // A standalone punctuation token ("—") after the anchor is the primary's own.
            let ending = checkerTokens[(lastAnchorToken + 1)...].drop { $0.key.isEmpty }
            let endingWords = ending.map(\.key).filter { !$0.isEmpty }
            guard !endingWords.isEmpty,
                  !isOnlySilenceHallucinations(endingWords),
                  // "…see, right? Right. Right.": the checker echoing the primary's last words.
                  !endingWords.allSatisfy(Set(primaryWords.suffix(3)).contains),
                  // Starts with a phrase the primary already has: a repeated earlier sentence, or
                  // a splice that landed early and would paste the primary's own words again.
                  !(endingWords.count >= 2 && occurrences(of: Array(endingWords.prefix(3)), in: primaryWords) > 0)
            else { return nil }
            return ending.map(\.text).joined(separator: " ")
        }
        return nil
    }

    /// What Whisper says over room tone ("thank you" is ~25% of its hallucinations on non-speech),
    /// longest first. The main defence is timing — the engine only passes words that start
    /// before the last detected speech — this list is the backstop. Plain "thanks" and "thank you
    /// for your time" are not listed: people end messages with them.
    static let silenceHallucinations: [[String]] = [
        "subtitles by the amaraorg community", "thank you so much for watching",
        "thank you for watching", "thanks for watching", "thank you for listening",
        "please subscribe to my channel", "see you in the next video", "ill see you next time",
        "see you next time", "thank you very much", "thank you so much", "thank you guys",
        "please subscribe", "thank you", "goodbye", "bye bye", "byebye", "bye", "you",
    ].map { $0.split(separator: " ").map(String.init) }

    /// True when `words` is nothing but silence hallucinations, however many and joined by "and"
    /// ("Thank you. Thank you.", "Thanks for watching and see you next time.").
    private static func isOnlySilenceHallucinations(_ words: [String]) -> Bool {
        var i = 0
        var matchedAny = false
        while i < words.count {
            if matchedAny, words[i] == "and" { i += 1; continue }
            guard let phrase = silenceHallucinations.first(where: {
                i + $0.count <= words.count && Array(words[i..<i + $0.count]) == $0
            }) else { return false }
            i += phrase.count
            matchedAny = true
        }
        return matchedAny
    }

    private static func occurrences(of run: [String], in words: [String]) -> Int {
        guard !run.isEmpty, run.count <= words.count else { return 0 }
        return (0...(words.count - run.count)).filter { Array(words[$0..<$0 + run.count]) == run }.count
    }

    /// Whitespace-separated tokens, each with a comparison key: lowercased letters and digits
    /// only, so "over," matches "over." and "Atlas" matches "atlas". Sound annotations —
    /// "[Music]", "(upbeat music)", "*sigh*" — get an empty key: they don't count as words, but
    /// the text itself is never altered, so "(415) 555-1234" is pasted whole.
    private static func words(_ text: String) -> [(text: String, key: String)] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var keys = tokens.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }
        var i = 0
        while i < tokens.count {
            guard let end = annotationEnd(tokens, from: i) else { i += 1; continue }
            for j in i...end { keys[j] = "" }
            i = end + 1
        }
        return Array(zip(tokens, keys))
    }

    /// The index of the token closing a sound annotation that opens at `start`: up to 4 tokens
    /// from "[", "(" or "*" to the matching closer, with no digits. nil when none opens there.
    private static func annotationEnd(_ tokens: [String], from start: Int) -> Int? {
        let closers: [Character: Character] = ["[": "]", "(": ")", "*": "*"]
        guard let open = tokens[start].first, let close = closers[open] else { return nil }
        for j in start..<min(tokens.count, start + 4) {
            let token = tokens[j]
            if token.contains(where: \.isNumber) { return nil }
            let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
            if core.count > (j == start ? 1 : 0), core.last == close { return j }
        }
        return nil
    }
}
