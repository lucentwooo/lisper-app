import Foundation

/// Detects Whisper's degenerate repetition / hallucination loops — the failure
/// mode where noisy or low-confidence audio yields a short token sequence
/// repeated many times (e.g. "VHL VAR GEMETSUI VHL VAR GEMETSUI ..."). Real
/// dictation almost never repeats an exact multi-word phrase several times, so
/// a high repeat count is a reliable signal that the transcript is garbage.
public enum HallucinationGuard {
    public static func isLikelyHallucination(_ text: String) -> Bool {
        let words = text
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" })
            .map(String.init)
        guard words.count >= 8 else { return false }

        // Single-token spam: one word dominates the whole clip.
        var unigram: [String: Int] = [:]
        for w in words { unigram[w, default: 0] += 1 }
        if let top = unigram.values.max(),
           Double(top) / Double(words.count) >= 0.6 {
            return true
        }

        // Repeated 2–4 word phrases. A genuine Whisper loop repeats ONE phrase
        // until it fills most of the clip; long casual speech merely sprinkles a
        // filler phrase ("you know", "so like") a handful of times across hundreds
        // of words. So key on COVERAGE — how much of the transcript the repeats
        // actually consume — not a raw repeat count. An absolute "4 times" rule
        // wrongly flags rambling dictation, which is exactly Lisper's audience.
        for n in 2...4 where words.count >= n * 2 {
            var counts: [String: Int] = [:]
            var i = 0
            while i + n <= words.count {
                counts[words[i..<i+n].joined(separator: " "), default: 0] += 1
                i += 1
            }
            if let top = counts.values.max(), top >= 3 {
                let coverage = Double(top * n) / Double(words.count)
                if coverage >= 0.5 { return true }
            }
        }
        return false
    }

    /// Excises *localized* back-to-back repetition loops while keeping the
    /// surrounding good speech. `isLikelyHallucination` only catches loops that
    /// dominate the whole clip (coverage ≥ 0.5); a Whisper loop tacked onto the end
    /// of a long, otherwise-perfect transcript (e.g. "…LisperYourAds ×10") is well
    /// under that bar, so it slips through and gets pasted verbatim. The defining
    /// trait of a loop is *immediate* repetition — a phrase repeated back-to-back —
    /// which cleanly separates it from fillers sprinkled across a ramble (not
    /// adjacent) and from real emphatic doubling ("no no", "go go go", ≤3×).
    ///
    /// Any phrase (1–4 words) repeated back-to-back is collapsed to a single copy:
    /// a unigram needs ≥4 consecutive hits (so emphatic "go go go" survives), a
    /// multi-word phrase needs ≥3. Punctuation is ignored when matching but the
    /// original tokens are preserved in the output.
    public static func collapseRepetitionLoops(_ text: String) -> String {
        let tokens = text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).map(String.init)
        guard tokens.count >= 4 else { return text }

        // Normalised view for comparison only (lowercased, stripped of punctuation).
        let norm = tokens.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }

        var out: [String] = []
        var i = 0
        while i < tokens.count {
            var collapsed = false
            // Smallest period first so a unigram loop is matched as a unigram, not as
            // a coincidental longer block (which would leave several copies behind).
            for n in 1...4 where i + n * 2 <= tokens.count {
                let block = Array(norm[i..<i+n])
                guard !block.allSatisfy({ $0.isEmpty }) else { continue }  // pure punctuation
                var reps = 1
                var j = i + n
                while j + n <= tokens.count, Array(norm[j..<j+n]) == block {
                    reps += 1; j += n
                }
                let threshold = (n == 1) ? 4 : 3
                if reps >= threshold {
                    out.append(contentsOf: tokens[i..<i+n])   // keep one copy
                    i = j                                      // skip the rest of the run
                    collapsed = true
                    break
                }
            }
            if !collapsed { out.append(tokens[i]); i += 1 }
        }
        return out.joined(separator: " ")
    }

    /// Excises a *trailing* Whisper hallucination burst — the failure mode where, on
    /// low-SNR audio, Whisper loses the real end of an utterance and appends garbage:
    /// a vocabulary-prompt echo and/or a degenerate repetition loop, e.g.
    /// "…futuristic FowlerAds, Lisper, Crap, Lid, Mace, Crap, Lid, Mace, Crap, Lid, Mace."
    /// (reported session 205). The whole-clip `isLikelyHallucination` can't fire — the
    /// good speech dominates the coverage — and `collapseRepetitionLoops` only trims the
    /// loop to one copy, so the burst still gets pasted at the cursor. This removes the
    /// WHOLE trailing burst while keeping the good prefix verbatim.
    ///
    /// Deliberately conservative so it never eats real speech: it fires only when a
    /// trailing back-to-back loop carries a hallucination *signature* — repeated ≥6×,
    /// OR a dictionary-term echo inside it, OR a list of different capitalised single
    /// words ("Crap, Lid, Mace"). Real repeats ("no, no, no, no.", "Bye. Bye. Bye.")
    /// and proper-noun endings are left for the gentler collapse pass.
    /// Once a burst is confirmed it also strips the burst's lead-in — the contiguous
    /// run of capitalised single-word fragments / dictionary-term echoes immediately
    /// before the loop ("FowlerAds, Lisper" ahead of the "Crap, Lid, Mace" loop).
    public static func exciseTrailingHallucination(_ text: String, dictionaryTerms: [String] = []) -> String {
        let tokens = text.split(whereSeparator: { $0 == " " || $0.isNewline || $0 == "\t" }).map(String.init)
        guard tokens.count >= 6 else { return text }
        let norm = tokens.map(squash)
        let termSet = Set(dictionaryTerms.map(squash).filter { !$0.isEmpty })

        // 1) Find a back-to-back loop anchored at the LAST token, keeping the candidate
        //    that reaches furthest back (removes the most garbage).
        let maxPeriod = min(8, tokens.count / 2)
        var loopStart = tokens.count   // == count means "no qualifying loop found"
        var garbageSignature = false   // the chosen loop is an echo / garbage-word list
        for p in 1...maxPeriod {
            let block = Array(norm[(tokens.count - p)..<tokens.count])
            if block.allSatisfy({ $0.isEmpty }) { continue }   // pure punctuation
            var reps = 1
            var start = tokens.count - p
            while start - p >= 0, Array(norm[(start - p)..<start]) == block {
                reps += 1; start -= p
            }
            guard reps >= (p == 1 ? 4 : 3) else { continue }

            // Hallucination signature — otherwise this is plausibly real emphasis. Real
            // speech ends in repeats too ("no, no, no, no.", "Bye. Bye. Bye. Bye.", a PIN
            // "1 1 1 1"), so a long run must be genuinely degenerate (≥6), and a capitalised
            // run only counts as garbage when it is a LIST of different words ("Crap, Lid,
            // Mace") — one capitalised word repeated is a goodbye, not a hallucination.
            let run = tokens[start..<tokens.count]
            let longRun = reps >= 6
            let vocabEcho = !termSet.isEmpty && !Set(block).isDisjoint(with: termSet)
            let capsList = p >= 2 && Set(block).count == p && run.allSatisfy(isCapitalizedSingleWord)
            guard longRun || vocabEcho || capsList else { continue }

            if start < loopStart {
                loopStart = start
                garbageSignature = vocabEcho || capsList
            }
        }
        guard loopStart < tokens.count else { return text }

        // 2) Walk further back over the burst LEAD-IN: capitalised single-word
        //    fragments and dictionary-term echoes that immediately precede the loop.
        //    Only for an echo / garbage-list burst — a plain degenerate loop has no lead-in,
        //    and walking back from it would eat the user's last real capitalised word.
        var cut = loopStart
        while garbageSignature, cut - 1 >= 0 {
            let prevIsEcho = !norm[cut - 1].isEmpty && termSet.contains(norm[cut - 1])
            guard isCapitalizedSingleWord(tokens[cut - 1]) || prevIsEcho else { break }
            cut -= 1
        }

        // Never delete everything — a burst with no good prefix is a whole-clip
        // hallucination; leave it for isLikelyHallucination / the engine fallback.
        guard cut > 0 else { return text }
        return tokens[0..<cut].joined(separator: " ")
    }

    /// Lowercased, letters+digits only — the comparison view used throughout.
    private static func squash(_ s: String) -> String {
        String(s.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A single capitalised alphabetic word (ignoring surrounding punctuation) —
    /// the shape Whisper emits when it spews a comma-list of garbage proper nouns.
    private static func isCapitalizedSingleWord(_ token: String) -> Bool {
        let core = token.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:\"'()[]"))
        guard let first = core.first, first.isUppercase, core.allSatisfy({ $0.isLetter }) else { return false }
        return true
    }
}
