// Sources/Lisper/Input/FnKeyGuard.swift
import AppKit

/// Mutes the system's 🌐/Fn-key action (input-source switching, emoji picker,
/// dictation) while Lisper runs, so holding Fn to dictate never flips keyboard
/// language. Writes `AppleFnUsageType = 0` ("Do Nothing") into com.apple.HIToolbox,
/// remembers the user's prior choice in Lisper's own defaults, and restores it on
/// quit. Crash-safe: the saved value survives and is restored on the next cycle.
///
/// The Globe-key action is performed by long-lived system agents that read the
/// preference once at launch — a plain preferences write never reaches them, so
/// every write here also terminates those agents (launchd respawns them on
/// demand with the fresh value). Even when the pref already reads 0, an agent
/// that was alive *before* it was set still holds the stale value and keeps
/// switching input on Fn, so `mute()` also force-refreshes the agents once per
/// launch regardless of the stored value.
enum FnKeyGuard {
    private static let domain = "com.apple.HIToolbox" as CFString
    private static let key = "AppleFnUsageType" as CFString
    private static let savedKey = "lisper.fnUsageType.saved"
    private static let wasUnset = -1   // sentinel: the key didn't exist before us
    private static var refreshedAgentsThisLaunch = false

    static func mute() {
        let current = CFPreferencesCopyAppValue(key, domain) as? Int
        if current != 0 {
            if UserDefaults.standard.object(forKey: savedKey) == nil {
                UserDefaults.standard.set(current ?? wasUnset, forKey: savedKey)
            }
            write(0)   // write() also relaunches the globe-key agents
        } else if !refreshedAgentsThisLaunch {
            // Pref already reads 0, but a globe-key agent that launched before it
            // was set can still hold a stale non-zero value. Restart the agents
            // once per launch so they re-read the correct 0; the flag keeps
            // repeated settings saves (which call mute() again) from churning them.
            relaunchGlobeKeyAgents()
        }
        refreshedAgentsThisLaunch = true
    }

    static func restore() {
        guard let saved = UserDefaults.standard.object(forKey: savedKey) as? Int else { return }
        write(saved == wasUnset ? nil : saved)
        UserDefaults.standard.removeObject(forKey: savedKey)
    }

    private static func write(_ value: Int?) {
        CFPreferencesSetAppValue(key, value.map { $0 as CFNumber }, domain)
        CFPreferencesAppSynchronize(domain)
        relaunchGlobeKeyAgents()
    }

    private static func relaunchGlobeKeyAgents() {
        let agents = ["com.apple.TextInputSwitcher", "com.apple.TextInputMenuAgent"]
        NSWorkspace.shared.runningApplications
            .filter { agents.contains($0.bundleIdentifier ?? "") }
            .forEach { $0.forceTerminate() }
    }
}
