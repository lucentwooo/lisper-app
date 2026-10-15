import AppKit
import SwiftUI
import LisperKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    let menuBar = MenuBarController()
    let pill = PillController()
    let hotkey = HotkeyMonitor()
    let recorder = AudioRecorder()
    let recordKeys = RecordingKeyTap()
    let corrections = CorrectionWatcher()
    let suggestions = SuggestionController()
    let copyToast = CopyToastController()
    private var mainWindow: NSWindow?
    private var processing = false
    private var axPromptShown = false
    private var recordingLocked = false
    /// Resolves the Fn→Space lock race (release vs lock event ordering during mic cold-start).
    private let gesture = RecordingGesture()
    /// A deferred finish, pending the grace window for a possibly-racing Space-lock.
    private var deferredFinish: DispatchWorkItem?
    /// The pill AND the start cue are deferred a beat after capture starts, so a take aborted
    /// by a shortcut (⌃C on a Left-⌃ hotkey) neither flashes UI nor makes a sound. Capture
    /// itself is immediate — no speech is lost.
    private var pendingPillShow: DispatchWorkItem?
    private static let pillDelaySeconds = 0.2
    /// How long the mic stays open after a finishing press (see `AudioRecorder.stop(keepingTail:)`).
    private static let stopTailSeconds = 0.3
    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        menuBar.install()
        menuBar.onOpenMain = { [weak self] in self?.openMainWindow() }
        menuBar.onTogglePause = { [weak self] paused in self?.hotkey.isPaused = paused }
        menuBar.lastDictation = { [weak self] in
            try? self?.env.database.recentSessions(limit: 1).first?.cleanedText
        }

        recorder.onLevel = { [weak self] level in self?.pill.meter.feed(level) }
        recorder.onAutoStop = { [weak self] in _ = self?.finishRecording() }

        // A press while ANY recording is in flight FINISHES it — never starts a new one.
        // The authoritative signal is `recorder.isRecording`, NOT the derived `recordingLocked`
        // flag. Those two (plus the gesture's own `locked`) can desync under the Fn/Space
        // cold-start event races, and when `isRecording == true` but `recordingLocked == false`
        // the old `if recordingLocked, isRecording` test fell through to `beginRecording()`,
        // which then hit `guard !recorder.isRecording` and silently no-op'd — the confirming Fn
        // press did nothing, the take was never transcribed/saved/logged, and the user's whole
        // dictation vanished with no trace. In hold mode `onPress` can only fire while recording
        // when the key was released and pressed again (HotkeyMonitor dedups a held key), so a
        // press during an active take is always a "stop", regardless of how we got here. See
        // DEBUGGING-LOG 2026-06-30.
        hotkey.onPress = { [weak self] in
            guard let self else { return false }
            HotkeyTrace.log("onPress: recordingLocked=\(self.recordingLocked) isRecording=\(self.recorder.isRecording) processing=\(self.processing)")
            if self.recorder.isRecording {
                HotkeyTrace.log("  -> finish (active recording)")
                self.hotkey.noteSessionEnded()
                return self.finishRecording()
            }
            HotkeyTrace.log("  -> beginRecording branch")
            return self.beginRecording()
        }
        hotkey.onRelease = { [weak self] in
            guard let self else { return false }
            HotkeyTrace.log("onRelease: recordingLocked=\(self.recordingLocked) isRecording=\(self.recorder.isRecording)")
            if self.recordingLocked { return false }
            // Don't finish on the release instant: a Space-lock may be racing it (both events
            // queued during the mic cold-start and processed out of order). A quick release
            // defers; a genuine hold finishes now. See RecordingGesture.
            switch self.gesture.release(at: self.now()) {
            case .finish:
                return self.finishRecording()
            case .scheduleFinishAfter(let seconds):
                self.scheduleDeferredFinish(after: seconds)
                return true
            case nil:
                return false
            }
        }

        let s = env.settingsStore.settings
        hotkey.configure(hotkeyCodes: s.hotkeyCodes, mode: s.hotkeyMode)
        if s.hotkeyCodes.contains(KeyCatalog.fn) { FnKeyGuard.mute() }

        // Separate flag from the menu-bar's `isPaused` (finding #3, 2026-08-03 final review):
        // sharing one Bool let a Settings key-capture and the menu-bar pause item clobber each
        // other — pausing from the menu, then arming/cancelling capture, un-paused the monitor
        // out from under the menu item (which still read "Resume Hotkey"), or vice versa.
        NotificationCenter.default.addObserver(forName: .lisperHotkeyCaptureBegan,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hotkey.isCapturing = true
        }
        NotificationCenter.default.addObserver(forName: .lisperHotkeyCaptureEnded,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.hotkey.isCapturing = false
        }
        // End any armed Settings key-capture when it can no longer receive its own teardown
        // (app deactivated, or the main window closed without SwiftUI's onDisappear firing —
        // see finding #4). Routed through the same `capture.cancel()` choke point SettingsView
        // already uses; cancel() on an unarmed capture is a documented no-op.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: .lisperEndHotkeyCapture, object: nil)
        }

        // Auto-learn dictionary (Wispr-style): a word the user fixes after a paste goes
        // straight into the dictionary; the toast offers Undo.
        corrections.onSuggestions = { [weak self] found in
            DispatchQueue.main.async { self?.learn(found) }
        }
        suggestions.onUndo = { [weak self] learned in
            guard let self else { return }
            var settings = self.env.settingsStore.settings
            settings.dictionaryTerms = DictionaryLearning.removing(learned, from: settings.dictionaryTerms)
            self.env.settingsStore.save(settings)
            NotificationCenter.default.post(name: .lisperSettingsChangedExternally, object: nil)
        }

        if !s.onboardingComplete || !PermissionsService.accessibilityGranted || !PermissionsService.microphoneGranted {
            openMainWindow()   // main window hosts onboarding until complete (Task 13)
            menuBar.set(state: .warning)
            // Onboarding only runs once; if grants were lost later (TCC reset, re-signed
            // build) the app vanishes from the System Settings lists until it asks again —
            // so re-ask directly here.
            if s.onboardingComplete {
                if PermissionsService.microphoneUndetermined { PermissionsService.requestMicrophone { _ in } }
                if !PermissionsService.accessibilityGranted { PermissionsService.requestAccessibility() }
            }
        }
    }

    private func learn(_ found: [WordCorrection]) {
        var settings = env.settingsStore.settings
        let learned = DictionaryLearning.newTerms(from: found, existing: settings.dictionaryTerms,
                                                  isOrdinaryWord: Self.isOrdinaryWord)
        guard !learned.isEmpty else { return }
        settings.dictionaryTerms += learned
        env.settingsStore.save(settings)
        NotificationCenter.default.post(name: .lisperSettingsChangedExternally, object: nil)
        // One row per learned term, showing the first spelling it replaced.
        let shown = learned.compactMap { term in found.first { $0.corrected == term } }
        suggestions.show(learned: shown)
    }

    /// A correctly spelled ordinary word (system spell checker, any of the user's languages).
    /// Names and jargon — what the dictionary is for — come back misspelled.
    private static func isOrdinaryWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0).location == NSNotFound
    }

    func applicationWillTerminate(_ notification: Notification) {
        FnKeyGuard.restore()
    }

    func applySettings() {
        let s = env.settingsStore.settings
        // Reconfigure (teardown + re-register of NSEvent monitors) only when the
        // hotkeys actually changed — settings save on every keystroke in some fields.
        if s.hotkeyCodes != hotkey.hotkeyCodes || s.hotkeyMode != hotkey.mode {
            hotkey.configure(hotkeyCodes: s.hotkeyCodes, mode: s.hotkeyMode)
        }
        if s.hotkeyCodes.contains(KeyCatalog.fn) { FnKeyGuard.mute() } else { FnKeyGuard.restore() }
    }

    @discardableResult private func beginRecording() -> Bool {
        guard !processing, !recorder.isRecording else {
            HotkeyTrace.log("beginRecording BLOCKED processing=\(processing) isRecording=\(recorder.isRecording)")
            return false
        }
        guard PermissionsService.microphoneGranted else {
            if PermissionsService.microphoneUndetermined {
                PermissionsService.requestMicrophone { _ in }   // OS prompt; retry the hotkey after granting
                pill.show(phase: .error("Allow the microphone, then try again"))
            } else {
                pill.show(phase: .error("Grant microphone access in Settings"))
            }
            menuBar.set(state: .warning)
            return false
        }
        recordingLocked = false
        deferredFinish?.cancel(); deferredFinish = nil
        pendingPillShow?.cancel(); pendingPillShow = nil
        // Arm the Esc/Space tap BEFORE the audio engine spins up. AVAudioEngine cold-start
        // blocks the main thread ~100-300ms; a Space pressed in that window must already be
        // intercepted — the kernel tap queues it and it locks the instant start() returns.
        // (Armed after start(), a quick Fn→Space missed the lock and the take just ended on
        // release: "press Fn and space too quickly, it just cancels instead of toggling".)
        recordKeys.onEscape = { [weak self] in self?.cancelRecording() ?? false }
        if hotkey.mode == .hold {
            recordKeys.onSpace = { [weak self] in self?.lockRecording() ?? false }
            // The abort rule's whole justification is "another key joined THE HOLD" — it
            // only makes sense while the user is still physically holding the hotkey down.
            // Toggle mode never holds anything, so never arm it there; hold mode disarms it
            // again the moment the take goes hands-free (see lockRecording()).
            recordKeys.onOtherKey = { [weak self] code in
                guard let self else { return }
                let codes = Set(self.env.settingsStore.settings.hotkeyCodes)
                guard RecordingAbortDecision.shouldAbort(keyCode: UInt16(clamping: code),
                                                         hotkeyCodes: codes,
                                                         isRecording: self.recorder.isRecording)
                else { return }
                self.abortRecording()
            }
        }
        recordKeys.start()
        do {
            try recorder.start()
            gesture.begin(at: now())   // arm the lock-race resolver for this take
            menuBar.set(state: .recording)
            // The start cue (like the pill) is deferred behind the same grace window: a
            // combo-abort (⌃C/⌃V on a Left-⌃ hotkey) must never have played a "listening"
            // chime for a take that's about to be silently destroyed. Capture itself
            // (recorder.start/gesture.begin above, and menuBar.set) stays immediate.
            let show = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingPillShow = nil
                guard self.recorder.isRecording else { return }
                UISounds.playStart()
                self.pill.show(phase: .listening)
            }
            pendingPillShow = show
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.pillDelaySeconds, execute: show)
            return true
        } catch {
            recordKeys.stop()
            pill.show(phase: .error("Couldn't start the microphone"))
            return false
        }
    }

    /// Space while holding the hotkey: keep recording hands-free until the next press.
    /// Wins the lock race — cancels any finish the Fn release deferred a moment ago.
    /// Returns whether Space was consumed.
    private func lockRecording() -> Bool {
        HotkeyTrace.log("lockRecording entered: isRecording=\(recorder.isRecording)")
        // No take behind the tap: it was left armed by a start that never completed. Disarm it
        // and let Space through, rather than swallowing every Space until relaunch.
        guard recorder.isRecording else {
            HotkeyTrace.log("  -> stale tap, no take: disarming, Space passes through")
            recordKeys.stop()
            return false
        }
        guard gesture.lock() else {
            HotkeyTrace.log("  -> lock NOT taken")
            return true
        }
        HotkeyTrace.log("  -> locked")
        deferredFinish?.cancel(); deferredFinish = nil
        recordingLocked = true
        recordKeys.onSpace = nil   // Space types normally again during the locked take
        // A locked take is deliberately hands-free — there is no "hold" left for another key to
        // join, so the combo-abort no longer applies. Left armed, a stray ⌘Tab/⌃C mid-take (the
        // whole point of going hands-free) would silently destroy the recording. See finding #1,
        // 2026-08-03 final review.
        recordKeys.onOtherKey = nil
        pill.model.locked = true
        UISounds.playLock()
        return true
    }

    /// A quick Fn release during cold-start might be a Space-lock that hasn't been processed
    /// yet (the lock race). Hold the recording open for the grace window; a racing lock cancels
    /// this (see lockRecording), otherwise the take finishes when the window elapses.
    private func scheduleDeferredFinish(after seconds: Double) {
        deferredFinish?.cancel()
        HotkeyTrace.log("scheduleDeferredFinish after=\(seconds)")
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.deferredFinish = nil
            let elapsed = self.gesture.graceElapsed()
            HotkeyTrace.log("deferredFinish fired: graceElapsed=\(elapsed)")
            if elapsed { _ = self.finishRecording() }
        }
        deferredFinish = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Esc while recording: discard the audio, nothing transcribed or saved.
    /// Returns whether Esc was consumed (see `lockRecording` for the no-take case).
    private func cancelRecording() -> Bool {
        guard recorder.isRecording else {
            recordKeys.stop()
            return false
        }
        deferredFinish?.cancel(); deferredFinish = nil
        pendingPillShow?.cancel(); pendingPillShow = nil
        _ = recorder.stop()
        UISounds.playCancel()
        recordKeys.stop()
        recordingLocked = false
        pill.model.locked = false
        hotkey.noteSessionEnded()
        pill.hide()
        menuBar.set(state: .idle)
        return true
    }

    /// Another key joined the hold — the user meant a shortcut, not dictation. Identical to
    /// `cancelRecording()` except it is SILENT: no cancel sound, and (inside the pill delay)
    /// no pill was ever shown. Nothing is transcribed, saved, or logged.
    private func abortRecording() {
        guard recorder.isRecording else { return }
        HotkeyTrace.log("abortRecording: another key joined the hold")
        deferredFinish?.cancel(); deferredFinish = nil
        pendingPillShow?.cancel(); pendingPillShow = nil
        _ = recorder.stop()
        recordKeys.stop()
        recordingLocked = false
        pill.model.locked = false
        hotkey.noteSessionEnded()
        pill.hide()
        menuBar.set(state: .idle)
    }

    @discardableResult private func finishRecording() -> Bool {
        HotkeyTrace.log("finishRecording entered: isRecording=\(recorder.isRecording)")
        guard recorder.isRecording else {
            HotkeyTrace.log("  -> finish NO-OP (not recording)")
            return false
        }
        deferredFinish?.cancel(); deferredFinish = nil
        pendingPillShow?.cancel(); pendingPillShow = nil
        recordKeys.stop()
        recordingLocked = false
        pill.model.locked = false
        let context = env.cleanupContext()   // capture frontmost app BEFORE any UI shifts
        menuBar.set(state: .processing)
        pill.model.processingText = "Polishing…"
        pill.show(phase: .processing)
        processing = true   // blocks a new take until this one is pasted, tail included
        recorder.stop(keepingTail: Self.stopTailSeconds) { [weak self] audio, heldSeconds in
            self?.transcribe(audio, heldSeconds: heldSeconds, context: context)
        }
        return true
    }

    private func transcribe(_ audio: CapturedAudio, heldSeconds: Double, context: CleanupContext) {
        HotkeyTrace.log("  -> recorder.stop returned duration=\(audio.durationSeconds)s held=\(heldSeconds)s samples=\(audio.samples.count) -> pipeline")
        // Deactivate cue — mirrors the start cue. Played only now the mic is closed, so the
        // stop tail doesn't record it.
        UISounds.playStop()
        if heldSeconds > 60 { pill.model.processingText = "Transcribing long audio…" }

        Task { @MainActor in
            let pipeline = self.env.makePipeline()
            let fillers = self.env.settingsStore.settings.customFillers
            defer {
                self.processing = false
                self.menuBar.set(state: .idle)
            }
            do {
                let outcome = try await pipeline.process(audio: audio, context: context, customFillers: fillers,
                                                         heldSeconds: heldSeconds)
                NotificationCenter.default.post(name: .lisperSessionSaved, object: nil)
                if self.env.settingsStore.settings.saveAudioForDebugging, let sid = outcome.session.id {
                    AudioStore.save(audio, sessionId: sid)
                }
                // No text box focused: offer a one-click copy instead of pasting into nothing.
                let focus = FocusedTextProbe.facts()
                let target = PasteTargetDecision.decide(focus)
                HotkeyTrace.log("paste target: role=\(focus.role ?? "none") cursor=\(focus.hasTextCursor) chromium=\(focus.isChromiumBased) -> paste=\(target.paste) offerCopy=\(target.offerCopy)")
                if !target.paste {
                    self.pill.show(phase: outcome.cleanupNotice.map { .error($0) } ?? .success)
                    self.copyToast.show(text: outcome.cleanedText, pasted: false)
                } else if TextInserter.insert(outcome.cleanedText) {
                    // Pasted, but with basic cleanup for a reason the user can fix — say so
                    // instead of degrading silently (DEBUGGING-LOG 2026-10-10b).
                    self.pill.show(phase: outcome.cleanupNotice.map { .error($0) } ?? .success)
                    self.corrections.beginWatch(insertedText: outcome.cleanedText,
                                                knownTerms: self.env.settingsStore.settings.dictionaryTerms)
                    if target.offerCopy { self.copyToast.show(text: outcome.cleanedText, pasted: true) }
                } else if !PermissionsService.accessibilityGranted {
                    if !self.axPromptShown {
                        self.axPromptShown = true
                        PermissionsService.requestAccessibility()   // system dialog re-adds Lisper to the list
                    }
                    self.pill.show(phase: .error("Grant Accessibility, then press ⌘V"))
                } else {
                    self.pill.show(phase: .error("Blocked here — press ⌘V to paste"))
                }
            } catch PipelineError.tooShort {
                // Never vanish silently — a too-short/lost take must leave a visible trace.
                self.pill.show(phase: .error("Too short — try again"))
            } catch PipelineError.noSpeech {
                self.pill.show(phase: .error("No speech heard — try again"))
            } catch {
                self.pill.show(phase: .error("Couldn't transcribe — check connection/key"))
            }
        }
    }

    /// Regular-app affordances: Dock icon + ⌘Tab need a window to land on,
    /// and our windows need an Edit menu for ⌘C/⌘V/⌘A to work in text fields.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { openMainWindow() }
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if mainWindow?.isVisible != true { openMainWindow() }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem(); mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About Lisper",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Lisper", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Lisper", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu

        let editItem = NSMenuItem(); mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu

        let windowItem = NSMenuItem(); mainMenu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @MainActor func openMainWindow() {
        if mainWindow == nil {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isMovableByWindowBackground = true
            win.minSize = NSSize(width: 860, height: 560)
            win.isReleasedWhenClosed = false
            win.center()
            win.contentView = NSHostingView(rootView: MainRootView(
                model: MainViewModel(env: self.env, onSettingsChanged: { [weak self] in self?.applySettings() })))
            mainWindow = win
            // `isReleasedWhenClosed = false` means ⌘W just orders the window out — the
            // NSHostingView/contentView is never torn down, so SettingsView's `.onDisappear`
            // is not a reliable teardown path for an armed key-capture. See finding #4.
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: win, queue: .main) { _ in
                NotificationCenter.default.post(name: .lisperEndHotkeyCapture, object: nil)
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
    }
}
