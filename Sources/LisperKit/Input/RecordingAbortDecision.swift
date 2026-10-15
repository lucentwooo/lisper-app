// Sources/LisperKit/Input/RecordingAbortDecision.swift

/// Should a keystroke arriving mid-take abandon it?
///
/// Once the trigger key can be ANY key, it can be a real shortcut modifier — Left ⌃ is the
/// obvious pick on a Windows keyboard, and it is also the prefix of ⌃C, ⌃A, ⌃←. Without
/// this rule every one of those shortcuts would start dictating.
///
/// The take is abandoned silently: no pill, no transcript, no history row, nothing in
/// `dictations.jsonl` — it never reaches the pipeline. The foreign keystroke itself is
/// passed through untouched, so ⌃C still copies.
public enum RecordingAbortDecision {

    /// - Parameters:
    ///   - keyCode: the key that just went down.
    ///   - hotkeyCodes: every configured trigger key. A non-modifier hotkey (F13) emits a
    ///     real keyDown, so it would otherwise abort its own take.
    ///   - isRecording: the AUTHORITATIVE capture state (`recorder.isRecording`), never a
    ///     derived flag — see DEBUGGING-LOG 2026-06-30.
    public static func shouldAbort(keyCode: UInt16,
                                   hotkeyCodes: Set<UInt16>,
                                   isRecording: Bool) -> Bool {
        guard isRecording else { return false }
        // Both exemptions already own a meaning inside a recording.
        if keyCode == KeyCatalog.space { return false }    // hands-free lock
        if keyCode == KeyCatalog.escape { return false }   // explicit cancel
        return !hotkeyCodes.contains(keyCode)
    }
}
