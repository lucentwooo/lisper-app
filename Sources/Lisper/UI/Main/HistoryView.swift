import SwiftUI
import LisperKit

/// Home — the cinematic landing tab (design refresh 2026-06-13; this file kept
/// its original History path). Greeting masthead, a searchable hairline-divided
/// dictation list grouped by day, and a quiet stats rail on the right.
/// Lists over cards: no card-per-transcription.
struct HomeView: View {
    @ObservedObject var model: MainViewModel
    @State private var expanded: Set<Int64> = []
    @State private var reporting: SessionRecord?
    @State private var noteText = ""

    var body: some View {
        HStack(spacing: 0) {
            ScrollView { mainColumn.padding(.horizontal, 36).padding(.top, 36).padding(.bottom, 44) }
            Divider().overlay(Theme.hairline)
            statsRail
        }
        .onAppear { model.reloadSessions() }
        .sheet(item: $reporting) { session in
            VStack(alignment: .leading, spacing: 14) {
                Text("Report bad dictation").font(.headline).foregroundColor(Theme.textPrimary)
                Text("What did you say, and what did it type?").sectionLabel()
                TextEditor(text: $noteText)
                    .frame(height: 90).font(.system(size: 13))
                HStack {
                    Spacer()
                    Button("Cancel") { reporting = nil }
                    Button("Save report") {
                        _ = model.reportBadDictation(session, note: noteText)
                        reporting = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(20).frame(width: 420).background(Theme.canvas)
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            Masthead(eyebrow: "Your voice", title: "Welcome back",
                     subtitle: greeting)

            searchField.padding(.top, 28)

            if model.sessions.isEmpty {
                VStack(spacing: 8) {
                    OrbMark(size: 40)
                    Text("Hold \(model.settings.hotkeyCodes.map(KeyCatalog.label(for:)).joined(separator: " or ")) anywhere and start talking")
                        .sectionLabel()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
            } else {
                ForEach(dayGroups, id: \.label) { group in
                    Text(group.label).sectionLabel()
                        .padding(.top, 24).padding(.bottom, 6).padding(.leading, 4)
                    ForEach(group.sessions) { session in
                        row(session)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var greeting: String {
        if let words = model.lifetime?.totalWords, words > 0 {
            return "You've cleaned up \(Self.kFmt(words)) words of your own speech so far."
        }
        return "Speak anywhere. Polished text appears."
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass").foregroundColor(Theme.textTertiary)
            TextField("Search your dictations", text: $model.search)
                .textFieldStyle(.plain).foregroundColor(Theme.textPrimary)
                .onSubmit { model.reloadSessions() }
                .onChange(of: model.search) { _, _ in model.reloadSessions() }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.045))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline)))
    }

    // MARK: rows

    private func row(_ session: SessionRecord) -> some View {
        let isExpanded = expanded.contains(session.id ?? -1)
        return VStack(alignment: .leading, spacing: 0) {
            Divider().overlay(Theme.hairline)
            HStack(alignment: .top, spacing: 18) {
                Text(session.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .frame(width: 64, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 0) {
                    Text(session.cleanedText)
                        .font(.system(size: 13)).foregroundColor(Theme.textPrimary)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isExpanded { expandedDetails(session) }
                }

                VStack(alignment: .trailing, spacing: 8) {
                    Text(session.appName)
                        .font(Theme.label).foregroundColor(Theme.textTertiary)
                        .textCase(.uppercase).kerning(1)
                    CopyButton(text: session.cleanedText)
                }
                .padding(.top, 3)
            }
            .padding(.vertical, 16).padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture { toggle(session) }
        }
    }

    @ViewBuilder
    private func expandedDetails(_ session: SessionRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(session.rawTranscript)
                .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                .lineSpacing(3)
                .textSelection(.enabled)
            HStack(spacing: 16) {
                Text(String(format: "%.0f wpm", session.wpm))
                Text("\(session.wordCount) words")
                Text("\(session.fillerCount) fillers")
                Text("\(session.engineUsed) · \(session.cleanupUsed)")
                Spacer()
                if model.hasAudio(session) {
                    Button { model.extractAudio(session) } label: { Image(systemName: "waveform") }
                        .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
                        .help("Extract audio (.wav)")
                }
                Button { reporting = session; noteText = "" } label: { Image(systemName: "exclamationmark.bubble") }
                    .buttonStyle(.plain).foregroundColor(Theme.textSecondary)
                    .help("Report bad dictation")
                Button { model.deleteSession(session) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundColor(Theme.textTertiary)
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundColor(Theme.textFaint)
        }
        .padding(.top, 12).padding(.leading, 12)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.hairlineStrong).frame(width: 2).padding(.top, 12)
        }
    }

    // MARK: stats rail

    private var statsRail: some View {
        VStack(alignment: .leading, spacing: 26) {
            if let l = model.lifetime {
                railStat(Self.kFmt(l.totalWords), "total words")
                railStat("\(Int(l.avgWPM.rounded()))", "avg wpm")
                railStat("\(l.dayStreak)", "day streak")
            }
            Divider().overlay(Theme.hairline)
            VStack(alignment: .leading, spacing: 12) {
                Text("On this Mac").sectionLabel()
                Text(model.settings.saveAudioForDebugging
                     ? "Transcripts never leave this Mac except to your chosen API. Audio is saved locally for debugging (7 days max, never leaves this Mac) — toggle in Settings."
                     : "Transcripts never leave this Mac except to your chosen API. Audio isn't saved.")
                    .font(.system(size: 12)).foregroundColor(Theme.textSecondary)
                    .lineSpacing(3)
            }
            Spacer()
        }
        .padding(28).padding(.top, 40)
        .frame(width: 244, alignment: .leading)
    }

    private func railStat(_ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value).font(Theme.statNumeral(34)).kerning(-1)
                .foregroundColor(Theme.textPrimary).monospacedDigit()
            Text(label).font(.system(size: 12)).foregroundColor(Theme.textTertiary)
        }
    }

    // MARK: helpers

    private struct DayGroup { let label: String; let sessions: [SessionRecord] }

    private var dayGroups: [DayGroup] {
        let cal = Calendar.current
        let grouped = Dictionary(grouping: model.sessions) { cal.startOfDay(for: $0.startedAt) }
        return grouped.keys.sorted(by: >).map { day in
            let label: String
            if cal.isDateInToday(day) { label = "Today" }
            else if cal.isDateInYesterday(day) { label = "Yesterday" }
            else { label = day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
            return DayGroup(label: label, sessions: grouped[day]!.sorted { $0.startedAt > $1.startedAt })
        }
    }

    private func toggle(_ session: SessionRecord) {
        guard let id = session.id else { return }
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    static func kFmt(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K")
                  : "\(n)"
    }
}

/// Copies a dictation in one click and confirms it, right on the row — no expanding first.
private struct CopyButton: View {
    let text: String
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            Clipboard.copy(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(copied ? Theme.success : (hovering ? Theme.textPrimary : Theme.textTertiary))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Copy this dictation")
    }
}
