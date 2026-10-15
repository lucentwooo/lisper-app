import Foundation

/// LLM cleanup that, when the main model is rate-limited (HTTP 429), retries once on a
/// backup model. Groq rate limits are per model, and the free tier allows only ~7 takes/min
/// on the main one — a burst used to drop straight to rule cleanup, losing the dictionary.
/// Any other failure (bad key, offline) would fail on the backup too, so it is rethrown as is.
public struct RateLimitFallbackCleanup: CleanupEngine {
    public let name = "llm"
    let primary: CleanupEngine
    let backup: CleanupEngine

    public init(primary: CleanupEngine, backup: CleanupEngine) {
        self.primary = primary; self.backup = backup
    }

    public func clean(raw: String, context: CleanupContext) async throws -> String {
        do {
            return try await primary.clean(raw: raw, context: context)
        } catch let error as EngineError {
            guard error.isRateLimited else { throw error }
            // Both limited: report the main model's error so the notice says "rate limit".
            guard let out = try? await backup.clean(raw: raw, context: context) else { throw error }
            return out
        }
    }
}
