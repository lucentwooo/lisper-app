// Module shim: re-exports Foundation because test files cannot import Foundation
// directly alongside Testing on this CLT-only toolchain (missing _Testing_Foundation
// cross-import overlay).
@_exported import Foundation

public enum LisperKitInfo {
    public static let version = "0.1.0"
}
