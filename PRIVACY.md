# Privacy

Lisper has no servers, no accounts, no analytics and no crash reporting. Nothing is ever sent to the person who made it. Your dictations go to one place outside your Mac — the speech service you choose — and everything else stays on your Mac.

## What leaves your Mac

Only when you've added a Groq API key and the Groq engine is selected (the default once a key is set), each dictation sends to **Groq** (`api.groq.com`), using your own key:

| Sent | Why |
|---|---|
| The audio of that one dictation | To turn speech into text. It goes to two Whisper models when the "ending check" is on (Settings → Engines; blank turns it off). |
| The raw transcript, the name of the app you're typing into (e.g. "Slack"), and your Dictionary words | So the AI cleanup can fix punctuation, match the app's tone, and spell your names right. Turn off "AI cleanup" in Settings → Engines to skip this step. |

Groq's handling of that data is covered by [Groq's privacy policy](https://groq.com/privacy-policy) and terms. Your API key is sent only to Groq, as the password on those requests.

**Without a key** (or offline), Lisper uses Apple's speech recognition, on-device whenever your Mac supports it for your language (otherwise Apple's servers handle it, under Apple's privacy policy). Cleanup is then done by simple built-in rules, on your Mac.

## What stays on your Mac

None of this is ever uploaded.

| What | Where | How long |
|---|---|---|
| History: each dictation's raw and cleaned text, app name, time, length and word stats | `~/Library/Application Support/Lisper/lisper.sqlite` | Forever by default — change in Settings → Data (90 or 30 days) |
| A technical log of recent dictations (text, timings, errors) for troubleshooting | `~/Library/Application Support/Lisper/debug/dictations.jsonl` | Rolls over at about 10 MB |
| Audio recordings — **off unless you turn on** "Save audio for debugging" | `~/Library/Application Support/Lisper/audio/` | Deleted after 7 days |
| "Report bad dictation" bundles, only when you click that button | `~/Library/Application Support/Lisper/debug/reports/` | Until you delete them. They are never sent anywhere — they're for you to look at or share yourself. Your API key is never included. |
| Your Groq API key | macOS Keychain (item `com.lucent.lisper`) | Until you remove it |
| Settings and Dictionary words | macOS preferences for `com.lucent.lisper` | Until you remove them |
| A hotkey timing trace (which modifier keys went up/down and when — never any text) | `/tmp/lisper-hotkey.log` | Cleared every time Lisper starts |

## Permissions

- **Microphone:** only recording while you hold the hotkey (or after you lock it hands-free). The mic is off otherwise.
- **Accessibility:** to notice the hotkey, to paste the text with ⌘V, and to learn spellings. After a paste, Lisper reads the text box you dictated into twice (about 1 and 20 seconds later). If you corrected a word that Lisper typed — say "Jerry" to "Jeriq" — it adds your spelling to your Dictionary and shows an Undo. Those two readings stay in memory and are thrown away; Lisper never records your typing.
- **Clipboard:** Lisper pastes through the clipboard, then puts your previous clipboard contents back about a second later. Clipboard-history apps may still keep a copy of the dictated text.

## Deleting everything

Quit Lisper (menu-bar icon → Quit Lisper), delete the app, then run in Terminal:

```bash
rm -rf ~/Library/Application\ Support/Lisper
defaults delete com.lucent.lisper
security delete-generic-password -s com.lucent.lisper
```

Then remove Lisper from **System Settings → Privacy & Security → Microphone** and **Accessibility**. To revoke the API key itself, delete it at [console.groq.com/keys](https://console.groq.com/keys).
