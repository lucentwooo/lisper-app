# Lisper

Voice dictation for your Mac. Hold a key anywhere, speak, let go — and clean, punctuated text appears at your cursor, in any app. A free alternative to Wispr Flow that runs on your own Groq API key, so there's no subscription and no account with anyone but Groq.

- **Fast and accurate:** Groq's Whisper transcribes, then an AI model tidies the text (punctuation, capitals, dropped "um"s) without changing what you said.
- **Works everywhere:** Slack, Mail, Notes, your browser, your code editor — anywhere you can type.
- **Private:** no accounts, no analytics, nothing sent to the person who made it. Details in [PRIVACY.md](PRIVACY.md).
- **Works offline too:** without a key or internet it falls back to Apple's on-device speech recognition.

## Install

You need a Mac on **macOS 15 (Sequoia) or later**. Apple silicon and Intel both work.

1. Download **Lisper.zip** from the [latest release](../../releases/latest).
2. Double-click it to unzip, then drag **Lisper.app** into your **Applications** folder.
3. Open Lisper. macOS will warn that it can't verify the app — that's because it isn't from the App Store (see [why](#why-the-warning)). Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down to the message about Lisper, and click **Open Anyway**. Enter your password if asked. You only do this once.

   *Prefer Terminal?* `xattr -dr com.apple.quarantine /Applications/Lisper.app` does the same thing.

5. Lisper walks you through setup:
   - **Microphone** — so it can hear you while you hold the key.
   - **Accessibility** — so it can notice the hotkey and type into other apps.
   - **Your Groq API key** — see below.

## Get a Groq API key (free)

1. Go to [console.groq.com/keys](https://console.groq.com/keys) and sign up (Google sign-in works).
2. Click **Create API Key**, give it any name, and copy the key (it starts with `gsk_`).
3. Paste it into Lisper when asked, or later in **Settings → Engines**.

The key is stored in your Mac's Keychain and is only ever sent to Groq. Groq's free tier is usually enough for one person; if you add billing, heavy daily use costs roughly a dollar or two a month. You can skip the key entirely and Lisper will use Apple's on-device engine instead (lower quality, no AI cleanup).

## Using it

- **Dictate:** click into any text box, **hold Fn (🌐)**, speak, release.
- **Hands-free:** while holding Fn, tap **Space** — you can let go and keep talking. Press **Fn** again to finish.
- **Cancel:** press **Esc** while recording.
- **No text box?** If nothing was selected to type into, a **Copy** button pops up so you can paste the text wherever you like. Menu-bar icon → **Copy Last Dictation** works any time, and every dictation on the Home page has its own **Copy** button.
- **Change the key:** Settings → Hotkey lets you pick any key (handy on keyboards without Fn).
- **Main window:** click the menu-bar icon → Open Lisper for your history, a simple Insights page, your Dictionary (names and words it should always spell your way), and Settings.

If Fn opens the emoji picker or switches language, set **System Settings → Keyboard → "Press 🌐 key to" → Do Nothing**.

## Updating

Download the new Lisper.zip and replace the app in Applications. Because each build is signed separately, macOS may forget Lisper's permissions: if the hotkey stops working, open **System Settings → Privacy & Security → Accessibility**, select Lisper, remove it with **−**, then add it back (or just reopen Lisper and grant again). If macOS asks to let Lisper use its Keychain item, click **Always Allow**.

## Why the warning?

Apple only removes the "can't verify" warning for apps whose developer pays $99/year for an Apple Developer account and submits each build to Apple for a malware scan ("notarization"). Lisper skips that, so macOS asks you to confirm once. The full source code is right here if you'd like to check what it does, or build it yourself (below).

## Troubleshooting

- **Pressing Fn does nothing** — check Lisper is turned on in System Settings → Privacy & Security → Accessibility. If it's already on, remove it with **−** and add it again.
- **"Couldn't transcribe"** — check your API key in Settings and your internet connection. Offline, Lisper switches to Apple's engine automatically.
- **Paste didn't land** (some password fields block it) — the text is still on your clipboard; press ⌘V.

## Build from source

Needs the Swift toolchain (`xcode-select --install` is enough; full Xcode isn't required).

```bash
git clone <this repo's URL> lisper && cd lisper
./scripts/make-cert.sh   # optional, one time: keeps permissions across rebuilds (asks for your password)
./scripts/run.sh         # build and open dist/Lisper.app
```

Development:

```bash
swift build                    # build (Swift Package Manager only — no Xcode project)
swift run LisperKitTests       # run the unit tests (plain `swift test` runs nothing here)
./scripts/build.sh --release   # optimised build for this Mac
./scripts/build.sh --dist      # shareable build: universal, ad-hoc signed, zipped to dist/Lisper.zip
```

All logic lives in `Sources/LisperKit/` (unit-tested); `Sources/Lisper/` is the thin macOS app shell. Product spec and implementation notes are in `docs/`.
