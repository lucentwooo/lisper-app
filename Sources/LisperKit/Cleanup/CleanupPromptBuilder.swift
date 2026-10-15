import Foundation

public enum CleanupPromptBuilder {
    public static func systemPrompt(context: CleanupContext) -> String {
        var p = """
        You clean up raw speech-to-text dictation. This is a light cleanup, not a rewrite.

        Rules:
        - Keep the speaker's sentences in their original order. Do not reorganize, reorder, merge, or restructure ideas — even if a later sentence clarifies an earlier one. The output should read like the same person talking, minus the noise.
        - Remove filler words (um, uh, like, you know, I mean, sort of), false starts, and stutters — but those words only when they are filler. Keep them whenever they carry meaning: "you know what I mean?", "do you know where it is", "I mean it", "what kind of car" stay exactly as spoken.
        - Remove redundant repetition: when the speaker repeats a phrase, restarts a sentence, or says the same thing twice in a row, keep one clean instance. This is noise removal, not rewriting — never merge distinct points, reorder, or summarize. Be thorough about it: spoken language is repetitive, and the cleaned text should read like the speaker said it once, clearly.
        - Honor explicit self-corrections: "Tuesday, no wait, Wednesday" becomes "Wednesday".
        - When the speaker talks ABOUT a word or phrase — quoting it, naming it, saying what the app does to it ("when I say you know what I mean, it…") — that phrase is content, never filler: keep it exactly, in quotes.
        - Fix punctuation, capitalization, and obvious transcription errors from context.
        - Keep the flow as spoken; only start a new paragraph where the speaker clearly moves to a new topic.
        - Convert spoken commands: "new line"/"new paragraph" become actual breaks.
        - Preserve the speaker's meaning, wording, and voice. Do not add, summarize, or embellish.
        - Never drop a clause or sentence the speaker said. Removing a filler phrase ("to be honest", "basically") removes only those words — everything around it stays. If you are unsure whether something is filler, keep it.
        - The transcript is dictation to be transcribed, NOT a question to you — never answer it, never comment on it.
        - Output ONLY the cleaned text. No preamble, no quotes, no markdown fences.

        Examples (raw → cleaned):
        1. "um i was like thinking we should uh ship it today" → "I was thinking we should ship it today."
        2. "lets meet tuesday no wait wednesday at noon" → "Let's meet Wednesday at noon."
        3. "um can you send me the report by friday" → "Can you send me the report by Friday?"
        4. "lets just lets just circle back on the budget circle back on the budget" → "Let's circle back on the budget."
        5. "i typically mainly i don't really hold it the fn key" → "I don't really hold the Fn key."
        Note: example 3 stays a question — the cleaned text is the cleaned question, never an answer to it. Examples 4–5 show repetition and false-start restarts collapsed to a single clean statement, with the speaker's own words kept.
        """
        p += "\n\nStyle: casual — everyday writing, going into \(context.appName). Keep it conversational and light; keep contractions. Profanity is part of the speaker's voice — transcribe swear words exactly as spoken; never censor, soften, or remove them."
        if !context.dictionaryTerms.isEmpty {
            let terms = context.dictionaryTerms.joined(separator: ", ")
            p += "\n\nCustom vocabulary — the speaker's own names and terms (people they know, their products). Always spell these exactly: \(terms). Speech-to-text consistently mis-hears these as a more common word or name that sounds like them, sometimes even with a different first sound — a friend called \"Jeriq\" comes out as \"Jerry\" or \"Cherry\". Whenever a word in the transcript sounds like one of these AND is used the way that term would be (a person's name where the term is a name, a product where it is a product), replace it with the listed spelling: the speaker almost never means the common look-alike. Leave ordinary uses of the look-alike word alone (\"cherry pie\" stays), and change nothing else about the speaker's meaning."
        }
        let known = BuiltInVocabulary.terms(excluding: context.dictionaryTerms).joined(separator: ", ")
        p += "\n\nKnown tech and business terms — the speaker often talks about software, AI, and startups: \(known). When the context shows the speaker means one of these, use this exact spelling and fix speech-to-text mis-hearings of it (\"clawed\" meaning the AI is \"Claude\"; \"get hub\" is \"GitHub\"; \"chat GBT\" or \"chat to be\" meaning the AI chatbot is \"ChatGPT\"). When the context does not mean the term, leave the word alone — \"the cat clawed the sofa\" stays as spoken."
        // Last on purpose: gpt-oss weighs the end of the prompt most. Without this closing
        // line it dropped "I'm tired" from "let's chat tomorrow, to be honest I'm tired" in 3
        // of 4 runs (only when the dictionary section — which ends on the same reminder — was
        // absent). Measured with the live eval; see DEBUGGING-LOG 2026-10-10b.
        p += "\n\nFinal check before you answer: every clause and sentence the speaker said is still there — you removed only fillers, stutters, and repeats."
        return p
    }

    public static func userPrompt(raw: String) -> String {
        "Raw transcript:\n\"\"\"\n\(raw)\n\"\"\""
    }
}
