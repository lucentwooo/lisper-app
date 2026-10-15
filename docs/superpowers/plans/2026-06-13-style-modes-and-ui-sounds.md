# Style Modes + UI Sound Family Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-app tone system with a global Formal/Casual style setting (casual keeps swears verbatim, formal removes them), replace the sub-bass UI cues with an Apple-style pitched three-sound family (start/lock/cancel), re-fix the Fn language-switcher bug, and update CLAUDE.md.

**Architecture:** LisperKit gains `StyleMode` (settings + cleanup prompt); the per-app `ToneHint`/`ToneRules` layer is deleted in three green commits (add → rewire → remove). Sounds stay app-side in `UISounds.swift`, synthesized at 48 kHz with a shared struck-bar voice and a Schroeder reverb; candidates are rendered to WAVs via a `--render-sounds` flag for a user audition checkpoint. The Fn bug is a systematic-debugging task with a lead hypothesis (ByHost preference domain).

**Tech Stack:** Swift 5 mode SPM, Swift Testing (`swift run LisperKitTests` — NEVER `swift test`, it silently runs nothing on this machine; `--filter` unsupported, always full suite), AppKit/SwiftUI, NSSound + `WavEncoder`.

**Spec:** `docs/superpowers/specs/2026-06-13-style-modes-and-ui-sounds.md`

---

### Task 1: `StyleMode` setting with migration-safe decoding

`AppSettings` uses synthesized Codable and `SettingsStore` silently resets to defaults when decoding throws — so adding a key requires tolerant decoding or every user setting resets. This task adds `StyleMode` + `styleMode` and makes `AppSettings` decode missing keys to defaults. `toneRules` stays for now (removed in Task 3) so every commit keeps the app fully working.

**Files:**
- Modify: `Sources/LisperKit/Settings/AppSettings.swift`
- Test: `Tests/LisperKitTests/SettingsTests.swift`

- [ ] **Step 1: Write the failing tests**

Append inside `@Suite struct SettingsTests` in `Tests/LisperKitTests/SettingsTests.swift`:

```swift
    @Test func testStyleModeDefaultsToCasual() {
        #expect(AppSettings().styleMode == .casual)
    }

    @Test func testStyleModeRoundTripThroughStore() {
        let defaults = UserDefaults(suiteName: "lisper-style-tests")!
        defaults.removePersistentDomain(forName: "lisper-style-tests")
        let store = SettingsStore(defaults: defaults)
        var s = store.settings
        s.styleMode = .formal
        store.save(s)
        #expect(SettingsStore(defaults: defaults).settings.styleMode == .formal)
    }

    /// A v0.1-era blob (has toneRules, lacks styleMode) must decode without
    /// resetting the user's other settings.
    @Test func testLegacyBlobDecodesWithDefaults() throws {
        let legacy = """
        {"hotkey":"rightCommand","hotkeyMode":"hold","sttEngine":"groq",\
        "llmCleanupEnabled":true,"groqWhisperModel":"whisper-large-v3-turbo",\
        "groqChatModel":"llama-3.3-70b-versatile",\
        "groqBaseURL":"https://api.groq.com/openai/v1",\
        "dictionaryTerms":["Lucent"],"customFillers":[],\
        "toneRules":{"rules":{"com.example":"casual"}},\
        "retention":"forever","launchAtLogin":false,"onboardingComplete":true}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: legacy)
        #expect(s.styleMode == .casual)
        #expect(s.hotkey == .rightCommand)
        #expect(s.dictionaryTerms == ["Lucent"])
        #expect(s.onboardingComplete)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run LisperKitTests`
Expected: compile error — `styleMode` does not exist on `AppSettings`. (A compile failure is this suite's "failing test" state.)

- [ ] **Step 3: Implement**

In `Sources/LisperKit/Settings/AppSettings.swift`, add the enum above `AppSettings` (next to the other settings enums):

```swift
public enum StyleMode: String, Codable, CaseIterable, Sendable {
    case formal, casual
}
```

Then replace the whole `AppSettings` struct with:

```swift
public struct AppSettings: Codable, Equatable, Sendable {
    public var hotkey: HotkeyChoice = .fn
    public var hotkeyMode: HotkeyMode = .hold
    public var sttEngine: STTEngineChoice = .groq
    public var llmCleanupEnabled: Bool = true
    public var groqWhisperModel: String = "whisper-large-v3-turbo"
    public var groqChatModel: String = "llama-3.3-70b-versatile"
    public var groqBaseURL: String = "https://api.groq.com/openai/v1"
    public var dictionaryTerms: [String] = []
    public var customFillers: [String] = []
    public var toneRules: ToneRules = .standard
    public var styleMode: StyleMode = .casual
    public var retention: RetentionPolicy = .forever
    public var launchAtLogin: Bool = false
    public var onboardingComplete: Bool = false
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case hotkey, hotkeyMode, sttEngine, llmCleanupEnabled
        case groqWhisperModel, groqChatModel, groqBaseURL
        case dictionaryTerms, customFillers, toneRules, styleMode
        case retention, launchAtLogin, onboardingComplete
    }

    /// Tolerant decoding: a stored blob from any prior version decodes with
    /// defaults for missing keys instead of throwing (SettingsStore resets
    /// EVERYTHING to defaults on a decode error).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        hotkey = try c.decodeIfPresent(HotkeyChoice.self, forKey: .hotkey) ?? d.hotkey
        hotkeyMode = try c.decodeIfPresent(HotkeyMode.self, forKey: .hotkeyMode) ?? d.hotkeyMode
        sttEngine = try c.decodeIfPresent(STTEngineChoice.self, forKey: .sttEngine) ?? d.sttEngine
        llmCleanupEnabled = try c.decodeIfPresent(Bool.self, forKey: .llmCleanupEnabled) ?? d.llmCleanupEnabled
        groqWhisperModel = try c.decodeIfPresent(String.self, forKey: .groqWhisperModel) ?? d.groqWhisperModel
        groqChatModel = try c.decodeIfPresent(String.self, forKey: .groqChatModel) ?? d.groqChatModel
        groqBaseURL = try c.decodeIfPresent(String.self, forKey: .groqBaseURL) ?? d.groqBaseURL
        dictionaryTerms = try c.decodeIfPresent([String].self, forKey: .dictionaryTerms) ?? d.dictionaryTerms
        customFillers = try c.decodeIfPresent([String].self, forKey: .customFillers) ?? d.customFillers
        toneRules = try c.decodeIfPresent(ToneRules.self, forKey: .toneRules) ?? d.toneRules
        styleMode = try c.decodeIfPresent(StyleMode.self, forKey: .styleMode) ?? d.styleMode
        retention = try c.decodeIfPresent(RetentionPolicy.self, forKey: .retention) ?? d.retention
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        onboardingComplete = try c.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? d.onboardingComplete
    }
}
```

(`SettingsStore` below the struct is unchanged.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift run LisperKitTests`
Expected: all tests PASS (including the three new ones).

- [ ] **Step 5: Verify the app target still builds**

Run: `swift build`
Expected: Build complete, no errors.

- [ ] **Step 6: Commit**

```bash
git add Sources/LisperKit/Settings/AppSettings.swift Tests/LisperKitTests/SettingsTests.swift
git commit -m "feat: StyleMode setting with migration-safe AppSettings decoding"
```

---

### Task 2: Cleanup prompt switches on style; swear policy per mode

`CleanupContext` swaps `tone: ToneHint` for `style: StyleMode`; the prompt builder gets the two-case style block. `ToneHint` itself stays in the file this task (still referenced by `ToneRules`/`SettingsView` until Task 3).

**Files:**
- Modify: `Sources/LisperKit/Cleanup/CleanupContext.swift`
- Modify: `Sources/LisperKit/Cleanup/CleanupPromptBuilder.swift`
- Modify: `Sources/Lisper/AppEnvironment.swift:35-41`
- Test: `Tests/LisperKitTests/PromptBuilderTests.swift`, `Tests/LisperKitTests/PipelineFallbackTests.swift:31`

- [ ] **Step 1: Rewrite the prompt tests (failing)**

Replace the entire contents of `Tests/LisperKitTests/PromptBuilderTests.swift` with:

```swift
import Testing
@testable import LisperKit

@Suite struct PromptBuilderTests {
    @Test func testCasualKeepsProfanityVerbatim() {
        let ctx = CleanupContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                                 style: .casual, dictionaryTerms: ["Lucent", "BetterYourAds"])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("exactly as spoken"))
        #expect(sys.contains("never censor"))
        #expect(sys.lowercased().contains("casual"))
        #expect(sys.contains("Lucent, BetterYourAds"))
    }

    @Test func testFormalRemovesProfanity() {
        let ctx = CleanupContext(appName: "Pages", bundleID: "com.apple.iWork.Pages",
                                 style: .formal, dictionaryTerms: [])
        let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
        #expect(sys.contains("Remove profanity entirely"))
        #expect(sys.lowercased().contains("formal"))
        #expect(!sys.contains("Custom vocabulary"))   // no dictionary section when empty
    }

    /// The meaning-preservation contract holds in BOTH styles.
    @Test func testBothStylesKeepCoreContract() {
        for style in StyleMode.allCases {
            let ctx = CleanupContext(appName: "Notes", bundleID: "com.apple.Notes",
                                     style: style, dictionaryTerms: [])
            let sys = CleanupPromptBuilder.systemPrompt(context: ctx)
            #expect(sys.contains("filler"))
            #expect(sys.contains("never answer"))
            #expect(sys.contains("original order"))
            #expect(sys.contains("Do not reorganize"))
            #expect(sys.contains("light cleanup, not a rewrite"))
        }
    }

    @Test func testUserPromptWrapsTranscript() {
        let user = CleanupPromptBuilder.userPrompt(raw: "um hello world")
        #expect(user.contains("um hello world"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift run LisperKitTests`
Expected: compile error — `CleanupContext` has no `style:` initializer parameter.

- [ ] **Step 3: Implement the context + prompt changes**

`Sources/LisperKit/Cleanup/CleanupContext.swift` — replace `CleanupContext` (keep `ToneHint` in the file untouched for now):

```swift
public struct CleanupContext: Sendable {
    public let appName: String
    public let bundleID: String
    public let style: StyleMode
    public let dictionaryTerms: [String]
    public init(appName: String, bundleID: String, style: StyleMode, dictionaryTerms: [String]) {
        self.appName = appName; self.bundleID = bundleID
        self.style = style; self.dictionaryTerms = dictionaryTerms
    }
}
```

`Sources/LisperKit/Cleanup/CleanupPromptBuilder.swift` — replace the `switch context.tone { ... }` block (lines 19-28) with:

```swift
        switch context.style {
        case .casual:
            p += "\n\nStyle: casual — everyday writing, going into \(context.appName). Keep it conversational and light; keep contractions. Profanity is part of the speaker's voice — transcribe swear words exactly as spoken; never censor, soften, or remove them."
        case .formal:
            p += "\n\nStyle: formal — public-facing writing (copy, scripts, email), going into \(context.appName). Use complete, well-structured sentences and a polished tone. Remove profanity entirely while preserving the sentence's meaning."
        }
```

`Tests/LisperKitTests/PipelineFallbackTests.swift:31` — update `ctx()`:

```swift
    func ctx() -> CleanupContext {
        CleanupContext(appName: "TextEdit", bundleID: "com.apple.TextEdit", style: .casual, dictionaryTerms: [])
    }
```

`Sources/Lisper/AppEnvironment.swift` — update `cleanupContext()`:

```swift
    func cleanupContext() -> CleanupContext {
        let s = settingsStore.settings
        let front = TextInserter.frontmostApp()
        return CleanupContext(appName: front.name, bundleID: front.bundleID,
                              style: s.styleMode,
                              dictionaryTerms: s.dictionaryTerms)
    }
```

- [ ] **Step 4: Run tests + full build**

Run: `swift run LisperKitTests` → all PASS.
Run: `swift build` → Build complete (SettingsView still compiles because `ToneHint`/`ToneRules` still exist).

- [ ] **Step 5: Commit**

```bash
git add Sources/LisperKit/Cleanup/CleanupContext.swift Sources/LisperKit/Cleanup/CleanupPromptBuilder.swift Sources/Lisper/AppEnvironment.swift Tests/LisperKitTests/PromptBuilderTests.swift Tests/LisperKitTests/PipelineFallbackTests.swift
git commit -m "feat: cleanup prompt driven by global style mode with explicit swear policy"
```

---

### Task 3: Style cards UI; delete the per-app tone system

**Files:**
- Modify: `Sources/Lisper/UI/Main/SettingsView.swift` (replace "Tone per app" section, lines 61-64, and delete `ToneRulesEditor`, lines 101-139)
- Modify: `Sources/LisperKit/Settings/AppSettings.swift` (drop `toneRules`)
- Modify: `Sources/LisperKit/Cleanup/CleanupContext.swift` (drop `ToneHint`)
- Delete: `Sources/LisperKit/Cleanup/ToneRules.swift`
- Test: `Tests/LisperKitTests/SettingsTests.swift` (drop `toneRules` assertions)

- [ ] **Step 1: Remove tone from the kit + tests**

- Delete `Sources/LisperKit/Cleanup/ToneRules.swift` (`git rm Sources/LisperKit/Cleanup/ToneRules.swift`).
- In `Sources/LisperKit/Cleanup/CleanupContext.swift`, delete the `ToneHint` enum (the file keeps only `CleanupContext`).
- In `Sources/LisperKit/Settings/AppSettings.swift`, delete the `public var toneRules: ToneRules = .standard` property, the `toneRules` case in `CodingKeys`, and the `toneRules = ...` line in `init(from:)`. (Stored blobs containing `toneRules` keep decoding — unknown keys are ignored.)
- In `Tests/LisperKitTests/SettingsTests.swift`, in `testRoundTripThroughStore`, delete the lines `s.toneRules.rules["com.example"] = .casual` and `#expect(reloaded.toneRules.tone(forBundleID: "com.example") == .casual)`.

- [ ] **Step 2: Run kit tests**

Run: `swift run LisperKitTests`
Expected: all PASS. (`swift build` would still fail — SettingsView references `ToneRulesEditor`; fixed next step.)

- [ ] **Step 3: Replace the settings section with style cards**

In `Sources/Lisper/UI/Main/SettingsView.swift`, replace the "Tone per app" section (lines 61-64):

```swift
                HairlineSection(label: "Style",
                                desc: "How dictation is cleaned up, everywhere you type.") {
                        Text("You said: “um this is fucking awesome, we should uh ship it”")
                            .font(.system(size: 11)).italic()
                            .foregroundColor(Theme.textTertiary)
                        StyleCard(
                            title: "Casual",
                            blurb: "Everyday messages and notes. Keeps your voice — swearing included.",
                            example: "This is fucking awesome, we should ship it.",
                            selected: model.settings.styleMode == .casual) {
                            model.settings.styleMode = .casual
                        }
                        StyleCard(
                            title: "Formal",
                            blurb: "Public-facing writing — copy, scripts, emails. Polished, no profanity.",
                            example: "This is awesome. We should ship it.",
                            selected: model.settings.styleMode == .formal) {
                            model.settings.styleMode = .formal
                        }
                }
```

Replace the whole `ToneRulesEditor` struct (lines 101-139) with:

```swift
/// Wispr-style selectable mode card: title + checkmark, one-line description,
/// and an example of the cleaned output.
struct StyleCard: View {
    let title: String
    let blurb: String
    let example: String
    let selected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundColor(selected ? Theme.accent : Theme.textFaint)
                }
                Text(blurb).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                Text("“\(example)”").font(.system(size: 11)).italic()
                    .foregroundColor(selected ? Theme.textPrimary : Theme.textTertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(selected ? 0.07 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .stroke(selected ? Theme.accent.opacity(0.6) : Theme.hairline, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 4: Full build + tests**

Run: `swift build` → Build complete.
Run: `swift run LisperKitTests` → all PASS.

- [ ] **Step 5: Visual check**

Run: `./scripts/run.sh`, open the main window → Settings. Verify: "Style" section shows the two cards, Casual pre-selected (accent ring + filled check), clicking Formal flips selection and persists across an app relaunch.

- [ ] **Step 6: Commit**

```bash
git add -A Sources Tests
git commit -m "feat: formal/casual style cards replace per-app tone rules"
```

---

### Task 4: Pitched UI cue synthesis + audition candidates

Replaces the sub-bass `UISounds` with a 48 kHz struck-bar synth: one shared voice per candidate family, three cues (start = rising fifth, lock = 1-5-8 arpeggio with lush tail, cancel = falling fifth, dry/darker). Family A wires in immediately so the app keeps sounds; `--render-sounds` dumps all three families as WAVs for the audition. Lock gets its sound call site now.

App target only — no unit tests per the LisperKit boundary.

**Files:**
- Rewrite: `Sources/Lisper/Audio/UISounds.swift`
- Modify: `Sources/Lisper/main.swift`
- Modify: `Sources/Lisper/AppDelegate.swift:120-125` (`lockRecording()`)

- [ ] **Step 1: Rewrite UISounds.swift**

Replace the entire contents of `Sources/Lisper/Audio/UISounds.swift` with:

```swift
// Sources/Lisper/Audio/UISounds.swift
import AppKit
import LisperKit

/// Pitched UI cues — an Apple-style "earcon family": one synthesized
/// struck-bar voice shared by all three cues, meaning carried by pitch
/// contour, note count, and tail length (research: WWDC17 "Designing Sound",
/// Brewster earcon guidelines; spec 2026-06-13-style-modes-and-ui-sounds).
///
///   start  — two notes rising a perfect fifth (G4→D5), short near-dry tail
///            (the mic opens with it; the cue must not bleed into capture).
///   lock   — the start motif affirmed: 1-5-8 arpeggio (G4-D5-G5) with the
///            longest decay and the lush reverb tail (long release reads as
///            "confirmed").
///   cancel — falling fifth (D5→G4), darker and dry — dismissed, not an error.
///
/// Rendered once at first use at 48 kHz as in-memory WAVs, peak-normalized
/// to ≈ −16 dBFS, played via NSSound at low volume.
enum UISounds {
    private static let volume: Float = 0.35
    private static let rate = 48_000.0

    // Note frequencies (Hz)
    private static let g4 = 392.00, d5 = 587.33, g5 = 783.99

    static let start: NSSound? = wrap(renderStart(voice: chosenFamily.voice))
    static let lock: NSSound? = wrap(renderLock(voice: chosenFamily.voice))
    static let cancel: NSSound? = wrap(renderCancel(voice: chosenFamily.voice))

    static func playStart() { play(start) }
    static func playLock() { play(lock) }
    static func playCancel() { play(cancel) }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()          // restart cleanly if still tailing off
        sound.volume = volume
        sound.play()
    }

    // MARK: - Voice (one struck-bar instrument per family)

    /// Additive struck-bar: sine partials with per-partial exponential decay.
    /// `gain` is linear; `decayMul` scales the family decay rate so upper
    /// partials die faster (what makes mallet timbres warm, not buzzy).
    struct Voice {
        var partials: [(ratio: Double, gain: Double, decayMul: Double)]
        var attack: Double   // seconds to full level (2-5 ms = percussive)
        var decay: Double    // fundamental exp decay rate, 1/s
    }

    struct Family {
        let key: String      // filename slug for audition WAVs
        let voice: Voice
    }

    /// Candidate families for the audition. After the user picks, point
    /// `chosenFamily` at the winner and delete the others.
    static let families: [Family] = [
        // A "glass" — pure harmonic stack, fast-decaying uppers. Clean, modern.
        Family(key: "a-glass", voice: Voice(
            partials: [(1, 1.0, 1.0), (2, 0.40, 1.6), (3, 0.18, 2.2), (4, 0.08, 3.0)],
            attack: 0.003, decay: 9)),
        // B "marimba" — tuned-bar partials (1:4:10), woodier and rounder.
        Family(key: "b-marimba", voice: Voice(
            partials: [(1, 1.0, 1.0), (4, 0.25, 2.5), (10, 0.06, 4.0)],
            attack: 0.002, decay: 8)),
        // C "kalimba" — slight inharmonicity, mellow, softest attack.
        Family(key: "c-kalimba", voice: Voice(
            partials: [(1, 1.0, 1.0), (2.0, 0.30, 1.8), (5.4, 0.10, 3.5)],
            attack: 0.004, decay: 7)),
    ]

    static let chosenFamily = families[0]

    // MARK: - The three cues

    /// First note slightly accented, per earcon guidelines — reads as one gesture.
    private static func renderStart(voice: Voice) -> [Float] {
        var buf = [Float](repeating: 0, count: Int(rate * 0.32))
        renderNote(into: &buf, voice: voice, freq: g4, at: 0.00, amp: 0.50)
        renderNote(into: &buf, voice: voice, freq: d5, at: 0.09, amp: 0.42)
        return finished(reverb(buf, wet: 0.12, tailSeconds: 0.10))
    }

    private static func renderLock(voice: Voice) -> [Float] {
        var slow = voice; slow.decay = voice.decay * 0.7   // longest release = "confirmed"
        var buf = [Float](repeating: 0, count: Int(rate * 0.40))
        renderNote(into: &buf, voice: slow, freq: g4, at: 0.00, amp: 0.50)
        renderNote(into: &buf, voice: slow, freq: d5, at: 0.09, amp: 0.40)
        renderNote(into: &buf, voice: slow, freq: g5, at: 0.18, amp: 0.45)
        return finished(reverb(buf, wet: 0.35, tailSeconds: 0.25))
    }

    private static func renderCancel(voice: Voice) -> [Float] {
        // Darker: halve the upper partials (lower spectral centroid = neutral, not harsh).
        var dark = voice
        dark.partials = voice.partials.enumerated().map { i, p in
            (p.ratio, i == 0 ? p.gain : p.gain * 0.5, p.decayMul)
        }
        dark.attack = voice.attack * 2
        var buf = [Float](repeating: 0, count: Int(rate * 0.22))
        renderNote(into: &buf, voice: dark, freq: d5, at: 0.00, amp: 0.46)
        renderNote(into: &buf, voice: dark, freq: g4, at: 0.08, amp: 0.40)
        return finished(buf)   // dry
    }

    // MARK: - DSP

    private static func renderNote(into buf: inout [Float], voice: Voice,
                                   freq: Double, at offset: Double, amp: Double) {
        let startIndex = Int(offset * rate)
        for i in startIndex..<buf.count {
            let time = Double(i - startIndex) / rate
            let attack = min(1.0, time / voice.attack)
            var s = 0.0
            for p in voice.partials {
                s += p.gain * sin(2 * .pi * freq * p.ratio * time)
                     * exp(-time * voice.decay * p.decayMul)
            }
            buf[i] += Float(s * amp * attack)
        }
    }

    /// Schroeder reverb: 4 feedback combs (mutually-prime delays, RT60 450 ms)
    /// into 2 allpass diffusers, mixed wet/dry.
    private static func reverb(_ dry: [Float], wet: Double, tailSeconds: Double) -> [Float] {
        guard wet > 0 else { return dry }
        let x = dry + [Float](repeating: 0, count: Int(rate * tailSeconds))
        var sum = [Float](repeating: 0, count: x.count)
        for delayMs in [29.7, 37.1, 41.1, 43.7] {
            let d = Int(rate * delayMs / 1000)
            let g = Float(pow(0.001, delayMs / 450.0))
            var comb = [Float](repeating: 0, count: x.count)
            for i in 0..<x.count {
                comb[i] = x[i] + (i >= d ? comb[i - d] * g : 0)
            }
            for i in 0..<x.count { sum[i] += comb[i] * 0.25 }
        }
        for delayMs in [5.0, 1.7] {
            let d = Int(rate * delayMs / 1000)
            let g: Float = 0.7
            var out = [Float](repeating: 0, count: sum.count)
            for i in 0..<sum.count {
                let xin = sum[i]
                let dIn = i >= d ? sum[i - d] : 0
                let dOut = i >= d ? out[i - d] : 0
                out[i] = -g * xin + dIn + g * dOut
            }
            sum = out
        }
        var out = x
        for i in 0..<out.count { out[i] = x[i] * Float(1 - wet) + sum[i] * Float(wet) }
        return out
    }

    /// Finish quality: peak-normalize to ≈ −16 dBFS and fade the last 15 ms
    /// to true zero (no truncated tails, no clicks).
    private static func finished(_ samples: [Float]) -> [Float] {
        var out = samples
        let peak = out.map(abs).max() ?? 0
        if peak > 0 {
            let target: Float = 0.158   // −16 dBFS
            for i in 0..<out.count { out[i] *= target / peak }
        }
        let n = min(out.count, Int(rate * 0.015))
        for k in 0..<n {
            out[out.count - n + k] *= Float(1 - Double(k + 1) / Double(n))
        }
        return out
    }

    private static func wrap(_ samples: [Float]) -> NSSound? {
        NSSound(data: WavEncoder.encode(CapturedAudio(samples: samples, sampleRate: rate)))
    }

    // MARK: - Audition

    /// Renders every candidate family's three cues as WAVs for listening
    /// (`Lisper --render-sounds [dir]`). Same synthesis code that ships.
    static func renderAuditionWAVs(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for family in families {
            let cues: [(String, [Float])] = [
                ("start", renderStart(voice: family.voice)),
                ("lock", renderLock(voice: family.voice)),
                ("cancel", renderCancel(voice: family.voice)),
            ]
            for (name, samples) in cues {
                let data = WavEncoder.encode(CapturedAudio(samples: samples, sampleRate: rate))
                try data.write(to: dir.appendingPathComponent("\(family.key)-\(name).wav"))
            }
        }
    }
}
```

- [ ] **Step 2: Add the render flag to main.swift**

Replace `Sources/Lisper/main.swift` with:

```swift
import AppKit

// Audition mode: render the candidate UI cues as WAVs and exit (no app launch).
if let i = CommandLine.arguments.firstIndex(of: "--render-sounds") {
    let dir = CommandLine.arguments.count > i + 1
        ? CommandLine.arguments[i + 1] : "/tmp/lisper-sounds"
    try! UISounds.renderAuditionWAVs(to: URL(fileURLWithPath: dir))
    print("Rendered candidate cues to \(dir)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)   // Dock icon + ⌘Tab; menu-bar item stays
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

- [ ] **Step 3: Give lock its sound**

In `Sources/Lisper/AppDelegate.swift`, `lockRecording()` (line ~120), add the play call:

```swift
    /// Space while holding the hotkey: keep recording hands-free until the next press.
    private func lockRecording() {
        guard recorder.isRecording, !recordingLocked else { return }
        recordingLocked = true
        recordKeys.onSpace = nil   // Space types normally again during the locked take
        pill.model.locked = true
        UISounds.playLock()
    }
```

- [ ] **Step 4: Build and render**

Run: `swift build` → Build complete.
Run: `swift run Lisper --render-sounds /tmp/lisper-sounds` → prints `Rendered candidate cues to /tmp/lisper-sounds`; `ls /tmp/lisper-sounds` shows 9 WAVs (3 families × start/lock/cancel).

Sanity-listen yourself: `afplay /tmp/lisper-sounds/a-glass-start.wav` etc. — check for clicks, clipping, or silence before handing to the user.

- [ ] **Step 5: Commit**

```bash
git add Sources/Lisper/Audio/UISounds.swift Sources/Lisper/main.swift Sources/Lisper/AppDelegate.swift
git commit -m "feat: pitched UI cue family (start/lock/cancel) with audition candidates"
```

---

### Task 5: Audition checkpoint + wire the chosen family

**⛔ STOP — user input required.** Do not proceed past Step 1 without Lucent's pick.

**Files:**
- Modify: `Sources/Lisper/Audio/UISounds.swift`

- [ ] **Step 1: Run the audition**

Tell Lucent the files are in `/tmp/lisper-sounds` and have him listen per family, in cue order:

```bash
for f in a-glass b-marimba c-kalimba; do
  echo "== $f =="; afplay /tmp/lisper-sounds/$f-start.wav; sleep 0.4
  afplay /tmp/lisper-sounds/$f-lock.wav; sleep 0.4
  afplay /tmp/lisper-sounds/$f-cancel.wav; sleep 1
done
```

Ask which family wins (and whether any cue needs tweaking — brighter/darker, longer/shorter tail, register up/down). Iterate on parameters and re-render until he's happy.

- [ ] **Step 2: Wire the winner, delete the losers**

In `UISounds.swift`: set the winning family's `Voice` as the single voice (inline it), delete the `families` array, `Family` struct, and `chosenFamily`; have `renderAuditionWAVs` render just the shipped three cues (keep the flag — it's the iteration tool). Apply any parameter tweaks from the audition.

- [ ] **Step 3: Live volume check**

Run: `./scripts/run.sh`. Dictate: hold Fn (start cue), press Space (lock cue), Esc (cancel cue). Verify the cues are clearly audible but quiet at normal system volume, and that a transcription of a quiet utterance right after the start cue doesn't contain artifacts. Adjust `volume` (0.2–0.5 range) to taste with Lucent.

- [ ] **Step 4: Commit**

```bash
git add Sources/Lisper/Audio/UISounds.swift
git commit -m "feat: ship the chosen UI cue family"
```

---

### Task 6: Fn language-switcher bug (systematic debugging)

**REQUIRED SUB-SKILL:** `superpowers:systematic-debugging`. Pressing Fn still opens the macOS input-source switcher despite `FnKeyGuard` (writes `AppleFnUsageType = 0` to `com.apple.HIToolbox` + force-quits `TextInputSwitcher`/`TextInputMenuAgent`). Do NOT jump to a fix — gather evidence first.

**Files:**
- Likely modify: `Sources/Lisper/Input/FnKeyGuard.swift`

- [ ] **Step 1: Reproduce + gather evidence**

With `dist/Lisper.app` running and hotkey = Fn, press Fn. While the bug reproduces, collect:

```bash
defaults read com.apple.HIToolbox AppleFnUsageType            # AnyHost value
defaults -currentHost read com.apple.HIToolbox AppleFnUsageType   # ByHost value
pgrep -fl 'TextInputSwitcher|TextInputMenuAgent'
```

Also check System Settings → Keyboard → "Press 🌐 key to" — what does the UI say while Lisper runs?

- [ ] **Step 2: Test hypotheses in order, cheapest first**

1. **H1 — ByHost domain shadowing (lead hypothesis).** HIToolbox preferences are often per-host. `FnKeyGuard` reads/writes via `CFPreferencesCopyAppValue`/`SetAppValue` (AnyHost). If the ByHost domain holds a non-zero value, agents see it, and `mute()`'s early-return (`current != 0 else { return }`) can also be fooled into never firing. Evidence: Step 1's two `defaults` reads disagree, ByHost ≠ 0.
2. **H2 — agents not actually restarting.** `forceTerminate()` returns a `Bool` we ignore. Evidence: `pgrep` PIDs unchanged after `FnKeyGuard.mute()` runs. Test: `killall TextInputSwitcher TextInputMenuAgent` manually with pref = 0 → does the bug stop?
3. **H3 — a different agent owns the Globe menu on this macOS.** Evidence: pref correct in both domains, agents restarted, bug persists. Investigate: `log stream --predicate 'eventMessage CONTAINS[c] "fn" OR processImagePath CONTAINS[c] "TextInput"' --info` while pressing Fn to find the responsible process.
4. **H4 — last resort: swallow Fn at the event-tap level.** Only if the preference route is a dead end: an active CGEventTap on `flagsChanged` that consumes bare-Fn events while Lisper runs (Accessibility is already granted for paste). This changes `FnKeyGuard`'s whole approach — stop and discuss with Lucent before building it.

- [ ] **Step 3: Implement the verified fix**

If H1 is confirmed (most likely), make `FnKeyGuard` read and write **both** domains:

```swift
    private static func readCurrent() -> Int? {
        // ByHost shadows AnyHost for HIToolbox; check it first.
        let byHost = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser,
                                            kCFPreferencesCurrentHost) as? Int
        let anyHost = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser,
                                             kCFPreferencesAnyHost) as? Int
        return byHost ?? anyHost
    }

    static func mute() {
        let current = readCurrent()
        guard current != 0 else { return }   // already "Do Nothing" everywhere
        if UserDefaults.standard.object(forKey: savedKey) == nil {
            UserDefaults.standard.set(current ?? wasUnset, forKey: savedKey)
        }
        write(0)
    }

    private static func write(_ value: Int?) {
        let v = value.map { $0 as CFNumber }
        CFPreferencesSetValue(key, v, domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSetValue(key, v, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        relaunchGlobeKeyAgents()
    }
```

(`restore()` already routes through `write(_:)`; update its doc comment if the mechanism changed. If a different hypothesis won, implement that fix instead — but only after the evidence names it.)

- [ ] **Step 4: Verify acceptance**

`./scripts/run.sh`, then: press/hold Fn repeatedly — dictation starts, the input-source switcher and emoji picker NEVER appear. Quit Lisper → Fn behavior restored to the saved value. Relaunch → muted again. (Logout/login check happens in Lucent's next smoke test; note it for him.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Lisper/Input/FnKeyGuard.swift
git commit -m "fix: Fn guard covers the ByHost preference domain"
```

(Adjust the message to describe the actual root cause found.)

---

### Task 7: CLAUDE.md reflects the full-app reality

**Files:**
- Modify: `CLAUDE.md` (and the matching line in `docs/superpowers/specs/2026-06-12-lisper-design.md` is historical — leave it)

- [ ] **Step 1: Update the description**

In `CLAUDE.md` "What this is", replace the first sentence:

> Lisper is a personal macOS menu-bar voice-dictation app (a Wispr Flow clone): hold Fn anywhere → speak → Groq Whisper transcribes → Groq LLM cleans → text is pasted at the cursor.

with:

> Lisper is a personal macOS voice-dictation app (a Wispr Flow clone) — a full windowed app (History, Coach, Dictionary, Settings) plus a menu-bar item and floating recording pill: hold Fn anywhere → speak → Groq Whisper transcribes → Groq LLM cleans → text is pasted at the cursor.

In "Architecture", update the LisperKit description "tone rules + prompt builder" → "style-mode prompt builder", since the tone system no longer exists.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md reflects full-app structure and style modes"
```
