# Transcript export (last N days) — design

**Date:** 2026-06-21
**Status:** Approved (brainstorm), pending spec review

## Goal

Let the user extract their recent dictation transcripts to a single readable
Markdown file. The user chooses a **rolling window of 1–7 days** (max one week)
from a dropdown in the Home view; the app writes a `.md` file containing every
session's **cleaned** transcript in that window, grouped by day.

## Decisions (from brainstorm)

- **Output:** one Markdown (`.md`) file, written via `NSSavePanel`.
- **Content:** `cleanedText` only (the final polished output), not the raw STT.
- **Window:** rolling `N × 24h` from now, where the user picks `N` ∈ `1…7`.
- **Entry point:** a dropdown menu in the Home view header ("Last 1 day" …
  "Last 7 days").
- **Dates:** formatted with an explicit **Gregorian** calendar + **`en_US`**
  locale, deliberately sidestepping the known Buddhist-system-calendar landmine
  that corrupts default date formatting on this machine.

## Architecture

Respects the hard LisperKit/Lisper boundary: all formatting logic is a pure,
unit-tested function in LisperKit; the app shell only does the file dialog and
the DB query.

### 1. LisperKit — `Sources/LisperKit/Export/TranscriptExporter.swift` (new)

A pure namespace, no I/O. Public surface:

```swift
public enum TranscriptExporter {
    /// Render the given sessions as a Markdown document for a rolling
    /// `days`-day window ending at `now`. Uses `cleanedText`. Pure.
    public static func markdown(
        sessions: [SessionRecord],
        days: Int,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian),
        locale: Locale = Locale(identifier: "en_US")
    ) -> String

    /// Suggested save-panel filename, e.g. "lisper-transcripts-last-3-days-2026-06-21.md".
    public static func suggestedFileName(
        days: Int,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String
}
```

Behavior:

- Groups sessions by **local calendar day** (using the injected Gregorian
  calendar with the current time zone).
- **Days newest-first; sessions within a day newest-first** — consistent with
  the History list ordering.
- Header reflects the chosen window and the actual data range, e.g.
  `# Lisper transcripts — last 3 days (Jun 19–21, 2026)`.
- A summary line: `_5 sessions · 312 words_` (session count = `sessions.count`;
  word count = sum of each session's `wordCount`, which is already computed on
  the cleaned text; plain integers, no locale-formatted numerals).
- Per day: an `## Saturday, June 21, 2026` header, then one entry per session as
  `**2:14 PM** — <cleanedText>`.
- **Empty input** → a valid doc whose body is `_No transcripts in this window._`
  (the app avoids calling this for an empty window, but the function is total).
- All date/time rendering goes through a `DateFormatter` pinned to the injected
  Gregorian `calendar` + `en_US` `locale`, so years render as `2026`, never a
  Buddhist-era `2569`.

### 2. Lisper app — `MainViewModel.exportTranscripts(days:)`

Mirrors the existing `extractAudio` save-panel flow:

```swift
func exportTranscripts(days: Int) {
    let n = min(max(days, 1), 7)                              // clamp to 1…7
    let since = Date().addingTimeInterval(-Double(n) * 86_400) // rolling N×24h
    let sessions = (try? env.database.sessions(since: since)) ?? []
    guard !sessions.isEmpty else {
        presentAlert("No transcripts in the past \(n) day\(n == 1 ? "" : "s")."); return
    }
    let now = Date()
    let md = TranscriptExporter.markdown(sessions: sessions, days: n, now: now)
    let panel = NSSavePanel()
    panel.nameFieldStringValue = TranscriptExporter.suggestedFileName(days: n, now: now)
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    if panel.runModal() == .OK, let dest = panel.url {
        do { try md.write(to: dest, atomically: true, encoding: .utf8) }
        catch { presentAlert("Couldn't write the file: \(error.localizedDescription)") }
    }
}
```

Plus a small private `presentAlert(_:)` helper (NSAlert) — the only new app-side
UI primitive. `env.database.sessions(since:)` already exists and returns
`[SessionRecord]`.

### 3. UI — Home view header dropdown (`HistoryView.swift`)

The search field row becomes an `HStack` of the existing `searchField` and a new
trailing `Menu`:

```swift
Menu {
    ForEach(1...7, id: \.self) { n in
        Button("Last \(n) day\(n == 1 ? "" : "s")") { model.exportTranscripts(days: n) }
    }
} label: {
    Label("Export", systemImage: "square.and.arrow.up")
}
```

Styled with `Theme` tokens to match the surrounding header (exact styling is an
implementation detail; no new Theme tokens).

## Data flow

`Menu item (days: n)` → `MainViewModel.exportTranscripts(days:)` →
`database.sessions(since:)` → `TranscriptExporter.markdown(...)` →
`NSSavePanel` → write `.md` to chosen URL.

## Error handling

- No sessions in the window → alert, no file written.
- File write failure → alert with the error message.
- Save panel cancelled → no-op.
- `days` outside `1…7` → clamped (defensive; the UI only offers `1…7`).

## Testing (`Tests/LisperKitTests/TranscriptExporterTests.swift`, written first)

Swift Testing `@Test` functions (auto-discovered), all against the pure
`TranscriptExporter`:

1. **Grouping & order** — sessions across two days render under correct
   `##` day headers, days newest-first, sessions newest-first within a day.
2. **Cleaned, not raw** — a session whose `rawTranscript` ≠ `cleanedText`
   renders the cleaned text and not the raw.
3. **Summary counts** — output contains `_3 sessions · <N> words_` with the
   correct session count and summed word count.
4. **Empty input** — produces the `_No transcripts in this window._` notice.
5. **Calendar landmine guard** — passing `calendar: Calendar(identifier:
   .buddhist)` / a Thai locale still yields a Gregorian header containing
   `2026` (the function pins Gregorian/`en_US` internally for rendering).
6. **Window label** — header contains `last 3 days` for `days: 3`.
7. **Filename** — `suggestedFileName(days: 3, now:)` ==
   `lisper-transcripts-last-3-days-2026-06-21.md`; `days: 1` uses the singular
   `last-1-day`.

App-side `exportTranscripts`/`NSSavePanel`/`Menu` wiring is not unit-tested
(thin shell), consistent with the rest of `Sources/Lisper`.

## Out of scope (YAGNI)

- CSV / JSON / clipboard outputs (Markdown only).
- Raw-transcript or stats columns in the export.
- Windows longer than 7 days, calendar-week alignment, or custom date ranges.
- A status-bar menu entry (Home view only).
