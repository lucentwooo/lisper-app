import Foundation

/// Turns an LLM-cleanup failure into a short notice the user can act on, or nil when the
/// degrade to rule cleanup is the designed behaviour (offline, a transient server error).
/// Exists because a retired model failed every take for two months with no visible sign —
/// the pipeline swallowed the error. Short enough for the recording pill.
public enum CleanupFailureNotice {
    public static func message(for error: Error) -> String? {
        guard let error = error as? EngineError, case let .badResponse(status, _) = error else { return nil }
        if error.isRateLimited { return "Groq rate limit — basic cleanup used" }
        switch status {
        case 401, 403: return "Groq key rejected — check Settings"
        case 400..<500: return "Cleanup model failed — check Settings"
        default: return nil   // 5xx: Groq's hiccup, not the user's to fix
        }
    }
}
