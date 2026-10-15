import Foundation

public struct CleanupContext: Sendable {
    public let appName: String
    public let bundleID: String
    public let dictionaryTerms: [String]
    public init(appName: String, bundleID: String, dictionaryTerms: [String]) {
        self.appName = appName; self.bundleID = bundleID; self.dictionaryTerms = dictionaryTerms
    }
}
